import Foundation

/// Terminal UI — Pi-style fixed layout with scrolling chat and pinned footer.
///
/// Layout:
/// ┌─────────────────────────────────────────┐
/// │ Chat messages (scrollable)              │
/// │ ...                                     │
/// │ User message (dark background)          │
/// │ Assistant response                      │
/// ├─────────────────────────────────────────┤ ← yellow/green separator
/// │ [cursor input area]                     │
/// ├─────────────────────────────────────────┤ ← thin separator
/// │ ~/path (branch)                         │
/// │ ↑1.7k ↓82 $0.011 0.9%/200k    model    │
/// └─────────────────────────────────────────┘
public enum TUI {

    // MARK: - ANSI Codes

    public static let reset = "\u{001B}[0m"
    public static let bold = "\u{001B}[1m"
    public static let dim = "\u{001B}[2m"
    public static let italic = "\u{001B}[3m"
    public static let inverse = "\u{001B}[7m"

    public static let red = "\u{001B}[31m"
    public static let green = "\u{001B}[32m"
    public static let yellow = "\u{001B}[33m"
    public static let blue = "\u{001B}[34m"
    public static let magenta = "\u{001B}[35m"
    public static let cyan = "\u{001B}[36m"
    public static let white = "\u{001B}[37m"
    public static let gray = "\u{001B}[90m"

    public static let bgDark = "\u{001B}[48;5;236m"
    public static let bgGray = "\u{001B}[48;5;238m"
    public static let bgGreen = "\u{001B}[48;5;22m"

    // MARK: - Terminal

    public static var width: Int {
        var w = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0 && w.ws_col > 0 {
            return Int(w.ws_col)
        }
        return 80
    }

    public static var height: Int {
        var w = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0 && w.ws_row > 0 {
            return Int(w.ws_row)
        }
        return 24
    }

    private static func write(_ s: String) {
        print(s, terminator: "")
        fflush(stdout)
    }

    private static func moveTo(row: Int, col: Int) {
        write("\u{001B}[\(row);\(col)H")
    }

    private static func clearLine() {
        write("\u{001B}[2K")
    }

    // MARK: - Layout Setup

    /// Set up the terminal with a scrolling region for chat and fixed footer.
    /// Call once at startup.
    public static func setupLayout() {
        let h = height
        let footerLines = 4  // separator + input + separator + 2 status lines
        let scrollEnd = h - footerLines

        // Set scroll region to top portion
        write("\u{001B}[\(1);\(scrollEnd)r")

        // Move to scroll region
        moveTo(row: scrollEnd, col: 1)

        // Draw initial footer
        drawFooterFrame(model: "", stats: "")
    }

    /// Restore terminal to normal mode. Call on exit.
    public static func teardown() {
        let h = height
        // Reset scroll region to full screen
        write("\u{001B}[1;\(h)r")
        moveTo(row: h, col: 1)
        write("\n")
    }

    // MARK: - User Message (dark background bar)

    public static func userMessage(_ text: String) {
        let w = width
        let padded = " " + text + String(repeating: " ", count: max(0, w - text.count - 1))
        print("\(bgDark)\(padded)\(reset)")
    }

    // MARK: - Separator Lines

    public static func accentSeparator() {
        print("\(yellow)\(String(repeating: "━", count: width))\(reset)")
    }

    public static func thinSeparator() {
        print("\(dim)\(String(repeating: "─", count: width))\(reset)")
    }

    // MARK: - Header / Banner

    public static func header(_ text: String) {
        let w = width
        let pad = max(0, w - text.count - 4)
        print("\(cyan)\(bold)  \(text)\(reset) \(dim)\(cyan)\(String(repeating: "━", count: pad))\(reset)")
    }

    public static func banner(model: String, artifacts: Int, facts: Int,
                               promoted: Int, tools: Int, skills: Int,
                               daemon: String) {
        print("")
        header("Engram")
        print("")
        print("  \(dim)Model:\(reset)   \(model)")
        print("  \(dim)Memory:\(reset)  \(artifacts) artifacts, \(facts) facts (\(promoted) promoted)")
        print("  \(dim)Tools:\(reset)   \(tools) \(dim)|\(reset) Skills: \(skills) \(dim)|\(reset) Daemon: \(daemon)")
        print("")
        print("  \(dim)Type /help for commands, 'exit' to quit.\(reset)")
        print("")
    }

    // MARK: - Footer

    /// Draw the persistent footer at the bottom of the terminal.
    public static func drawFooterFrame(model: String, stats: String) {
        let h = height
        let w = width

        // Move below scroll region
        moveTo(row: h - 3, col: 1)

        // Accent separator (yellow/green)
        clearLine()
        write("\(yellow)\(String(repeating: "━", count: w))\(reset)\n")

        // Input line (blank — user types here via readLine)
        clearLine()
        write("\n")

        // Thin separator
        clearLine()
        write("\(dim)\(String(repeating: "─", count: w))\(reset)\n")

        // Status line: path + stats + model
        clearLine()
        let cwd = shortenPath(FileManager.default.currentDirectoryPath)
        write("\(dim)\(cwd)\(reset)\n")

        clearLine()
        if !stats.isEmpty {
            let rightLen = stripANSI(model).count
            let leftLen = stripANSI(stats).count
            let pad = max(1, w - leftLen - rightLen)
            write("\(stats)\(String(repeating: " ", count: pad))\(dim)\(model)\(reset)")
        }

        // Move cursor back to input line
        moveTo(row: h - 2, col: 1)
    }

    /// Update just the stats line without redrawing everything.
    public static func updateStats(
        model: String, inputTokens: Int, outputTokens: Int,
        cacheRead: Int, cacheWrite: Int,
        contextCurrent: Int, contextMax: Int
    ) {
        let h = height
        let w = width

        let pct = contextMax > 0 ? Int(Double(contextCurrent) / Double(contextMax) * 100) : 0
        let pctColor = pct < 70 ? green : (pct < 90 ? yellow : red)

        var stats = "\(dim)↑\(fmtTokens(inputTokens)) ↓\(fmtTokens(outputTokens))"
        if cacheRead > 0 { stats += " R\(fmtTokens(cacheRead))" }

        let inputCost = Double(inputTokens - cacheRead) * 3.0 / 1_000_000
        let cacheCost = Double(cacheRead) * 0.30 / 1_000_000
        let outputCost = Double(outputTokens) * 15.0 / 1_000_000
        stats += " $\(String(format: "%.3f", inputCost + cacheCost + outputCost))"
        stats += " \(pctColor)\(pct)%\(dim)/\(contextMax / 1000)k\(reset)"

        // Save cursor, update last line, restore cursor
        write("\u{001B}[s")  // save position
        moveTo(row: h, col: 1)
        clearLine()
        let modelStr = "\(dim)\(model)\(reset)"
        let statsLen = stripANSI(stats).count
        let modelLen = stripANSI(modelStr).count
        let pad = max(1, w - statsLen - modelLen)
        write("\(stats)\(String(repeating: " ", count: pad))\(modelStr)")
        write("\u{001B}[u")  // restore position
    }

    // MARK: - Prompt

    public static func prompt() {
        write("\(cyan)❯\(reset) ")
    }

    // MARK: - Helpers

    public static func fmtTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }

    public static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    private static func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var short = path
        if short.hasPrefix(home) {
            short = "~" + String(short.dropFirst(home.count))
        }
        // Add git branch if in a repo
        let gitHead = URL(fileURLWithPath: path).appendingPathComponent(".git/HEAD")
        if let head = try? String(contentsOf: gitHead, encoding: .utf8) {
            let branch = head.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "ref: refs/heads/", with: "")
            short += " (\(branch))"
        }
        return short
    }

    // MARK: - Synchronized Output

    public static func beginSync() { write("\u{001B}[?2026h") }
    public static func endSync() { write("\u{001B}[?2026l") }
}
