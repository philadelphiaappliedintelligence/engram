import Foundation

/// Raw terminal mode — takes full control of the terminal.
/// Provides pinned footer, scroll region for chat, and raw key input.
public final class RawTerminal {
    private var originalTermios = termios()
    private var isRaw = false
    public private(set) var width: Int = 80
    public private(set) var height: Int = 24
    private let footerHeight = 4  // separator + cwd + stats + input

    public var chatBottom: Int { height - footerHeight }

    public init() {
        updateSize()
    }

    // MARK: - Terminal Mode

    public func enableRawMode() {
        guard !isRaw else { return }
        tcgetattr(STDIN_FILENO, &originalTermios)
        var raw = originalTermios
        // Disable canonical mode, echo, signals
        raw.c_lflag &= ~UInt(ICANON | ECHO | ISIG)
        // Minimum 1 byte, no timeout
        raw.c_cc.16 = 1  // VMIN
        raw.c_cc.17 = 0  // VTIME
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
        isRaw = true

        // Hide cursor during setup
        write("\u{001B}[?25l")

        // Set up scroll region (top to chatBottom)
        updateSize()
        setScrollRegion()

        // Enable alternate screen buffer
        // (Don't use — we want scrollback preserved)

        // Show cursor
        write("\u{001B}[?25h")
    }

    public func disableRawMode() {
        guard isRaw else { return }
        // Reset scroll region
        write("\u{001B}[1;\(height)r")
        // Move to bottom
        moveTo(row: height, col: 1)
        write("\n")
        // Restore terminal
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTermios)
        isRaw = false
    }

    deinit { disableRawMode() }

    // MARK: - Screen Layout

    public func updateSize() {
        var w = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0 {
            width = Int(w.ws_col)
            height = Int(w.ws_row)
        }
    }

    private func setScrollRegion() {
        write("\u{001B}[\(1);\(chatBottom)r")
    }

    // MARK: - Cursor & Drawing

    public func moveTo(row: Int, col: Int) {
        write("\u{001B}[\(row);\(col)H")
    }

    public func clearLine() {
        write("\u{001B}[2K")
    }

    public func clearToEnd() {
        write("\u{001B}[J")
    }

    /// Move cursor to end of scroll region for chat output
    public func moveToChatEnd() {
        moveTo(row: chatBottom, col: 1)
    }

    /// Move cursor to the input line in the footer
    public func moveToInput() {
        moveTo(row: height - 1, col: 1)
    }

    // MARK: - Chat Output

    /// Print text in the scrolling chat region.
    /// Automatically scrolls when reaching the bottom of the scroll region.
    public func chatPrint(_ text: String) {
        // Ensure we're in the scroll region
        saveCursor()
        moveToChatEnd()
        // Print will scroll within the region
        print(text)
        fflush(stdout)
        restoreCursor()
    }

    /// Stream a character to the chat region (for live streaming)
    public func chatWrite(_ text: String) {
        // Just write — cursor should already be in chat region
        write(text)
    }

    // MARK: - Footer

    /// Draw the complete footer (separator + cwd + stats + input prompt)
    public func drawFooter(
        cwd: String, model: String,
        inputTokens: Int = 0, outputTokens: Int = 0,
        cacheRead: Int = 0,
        contextCurrent: Int = 0, contextMax: Int = 0,
        inputText: String = "", cursorPos: Int = 0
    ) {
        beginSync()

        let w = width

        // Line height-3: Separator (dim gray)
        moveTo(row: height - 3, col: 1)
        clearLine()
        write("\u{001B}[2m\(String(repeating: "─", count: w))\u{001B}[0m")

        // Line height-2: Input with prompt (ABOVE footer)
        moveTo(row: height - 2, col: 1)
        clearLine()
        write("\u{001B}[36m❯\u{001B}[0m \(inputText)")

        // Line height-1: Thin separator
        moveTo(row: height - 1, col: 1)
        clearLine()
        write("\u{001B}[2m\(String(repeating: "─", count: w))\u{001B}[0m")

        // Line height: cwd + stats + model
        moveTo(row: height, col: 1)
        clearLine()

        let pct = contextMax > 0 ? Int(Double(contextCurrent) / Double(contextMax) * 100) : 0
        let pctColor = pct < 70 ? "\u{001B}[32m" : (pct < 90 ? "\u{001B}[33m" : "\u{001B}[31m")

        var left = "\u{001B}[2m\(cwd) "
        if inputTokens > 0 || outputTokens > 0 {
            left += "↑\(fmtTok(inputTokens)) ↓\(fmtTok(outputTokens)) "
            if cacheRead > 0 { left += "R\(fmtTok(cacheRead)) " }
            let cost = Double(inputTokens - cacheRead) * 3.0 / 1_000_000 +
                       Double(cacheRead) * 0.30 / 1_000_000 +
                       Double(outputTokens) * 15.0 / 1_000_000
            left += "$\(String(format: "%.3f", cost)) "
            left += "\(pctColor)\(pct)%\u{001B}[2m/\(contextMax / 1000)k"
        }
        left += "\u{001B}[0m"

        let modelStr = "\u{001B}[2m\(model)\u{001B}[0m"
        let leftPlain = stripANSI(left)
        let modelPlain = stripANSI(modelStr)
        let pad = max(1, w - leftPlain.count - modelPlain.count)
        write("\(left)\(String(repeating: " ", count: pad))\(modelStr)")

        // Position cursor on the input line
        moveTo(row: height - 2, col: cursorPos + 3)

        endSync()
    }

    // MARK: - Key Reading

    /// Read a single keypress. Returns the character(s) read.
    /// Handles special keys (arrows, backspace, enter, ctrl combinations).
    public func readKey() -> KeyEvent {
        var buf = [UInt8](repeating: 0, count: 8)
        let n = read(STDIN_FILENO, &buf, 8)
        guard n > 0 else { return .none }

        // Single byte
        if n == 1 {
            let c = buf[0]
            switch c {
            case 13, 10: return .enter
            case 127, 8: return .backspace
            case 3: return .ctrlC
            case 4: return .ctrlD
            case 12: return .ctrlL  // clear
            case 21: return .ctrlU  // delete line
            case 23: return .ctrlW  // delete word
            case 27: return .escape
            case 1: return .home     // ctrl-A
            case 5: return .end      // ctrl-E
            case 11: return .ctrlK   // delete to end
            case 9: return .tab
            default:
                if c >= 32 && c < 127 {
                    return .char(Character(UnicodeScalar(c)))
                }
                return .none
            }
        }

        // Multi-byte: UTF-8 character
        if buf[0] & 0x80 != 0 {
            // UTF-8 sequence
            let data = Data(buf[0..<n])
            if let str = String(data: data, encoding: .utf8), let ch = str.first {
                return .char(ch)
            }
            return .none
        }

        // Escape sequences
        if n >= 3 && buf[0] == 27 && buf[1] == 91 { // ESC [
            switch buf[2] {
            case 65: return .arrowUp
            case 66: return .arrowDown
            case 67: return .arrowRight
            case 68: return .arrowLeft
            case 72: return .home
            case 70: return .end
            case 51:
                if n >= 4 && buf[3] == 126 { return .delete }
                return .none
            default: return .none
            }
        }

        return .none
    }

    /// Read a full line of input using raw mode with live editing.
    /// Returns nil on Ctrl+D (EOF) or Ctrl+C.
    public func readLine(prompt: String = "❯ ") -> String? {
        var buffer: [Character] = []
        var cursor = 0

        while true {
            let key = readKey()

            switch key {
            case .enter:
                let result = String(buffer)
                // Move to chat end and print the entered text
                return result

            case .char(let c):
                buffer.insert(c, at: cursor)
                cursor += 1
                redrawInput(buffer: buffer, cursor: cursor)

            case .backspace:
                if cursor > 0 {
                    cursor -= 1
                    buffer.remove(at: cursor)
                    redrawInput(buffer: buffer, cursor: cursor)
                }

            case .delete:
                if cursor < buffer.count {
                    buffer.remove(at: cursor)
                    redrawInput(buffer: buffer, cursor: cursor)
                }

            case .arrowLeft:
                if cursor > 0 { cursor -= 1; redrawInput(buffer: buffer, cursor: cursor) }

            case .arrowRight:
                if cursor < buffer.count { cursor += 1; redrawInput(buffer: buffer, cursor: cursor) }

            case .home:
                cursor = 0; redrawInput(buffer: buffer, cursor: cursor)

            case .end:
                cursor = buffer.count; redrawInput(buffer: buffer, cursor: cursor)

            case .ctrlU:
                buffer.removeAll(); cursor = 0; redrawInput(buffer: buffer, cursor: cursor)

            case .ctrlW:
                // Delete word backward
                while cursor > 0 && buffer[cursor - 1] == " " { cursor -= 1; buffer.remove(at: cursor) }
                while cursor > 0 && buffer[cursor - 1] != " " { cursor -= 1; buffer.remove(at: cursor) }
                redrawInput(buffer: buffer, cursor: cursor)

            case .ctrlK:
                buffer.removeSubrange(cursor..<buffer.count)
                redrawInput(buffer: buffer, cursor: cursor)

            case .ctrlC:
                if buffer.isEmpty { return nil }
                buffer.removeAll(); cursor = 0; redrawInput(buffer: buffer, cursor: cursor)

            case .ctrlD:
                if buffer.isEmpty { return nil }

            default: break
            }
        }
    }

    private func redrawInput(buffer: [Character], cursor: Int) {
        moveTo(row: height - 2, col: 1)
        clearLine()
        write("\u{001B}[36m❯\u{001B}[0m \(String(buffer))")
        moveTo(row: height - 2, col: cursor + 3)
    }

    /// Clear the input line (call after message is sent)
    public func clearInput() {
        moveTo(row: height - 2, col: 1)
        clearLine()
        write("\u{001B}[36m❯\u{001B}[0m ")
    }

    // MARK: - Sync Output

    public func beginSync() { write("\u{001B}[?2026h") }
    public func endSync() { write("\u{001B}[?2026l") }
    public func saveCursor() { write("\u{001B}7") }
    public func restoreCursor() { write("\u{001B}8") }

    // MARK: - Helpers

    private func write(_ s: String) {
        FileHandle.standardOutput.write(s.data(using: .utf8)!)
    }

    private func fmtTok(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    private func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }
}

// MARK: - Key Event

public enum KeyEvent {
    case none
    case char(Character)
    case enter
    case backspace
    case delete
    case arrowUp, arrowDown, arrowLeft, arrowRight
    case home, end
    case tab
    case escape
    case ctrlC, ctrlD, ctrlL, ctrlU, ctrlW, ctrlK
}
