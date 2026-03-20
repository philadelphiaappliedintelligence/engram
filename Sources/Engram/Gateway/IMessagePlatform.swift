import Foundation

/// iMessage gateway using AppleScript (native macOS, no dependencies).
/// Send: AppleScript → Messages.app
/// Receive: Poll ~/Library/Messages/chat.db (requires Full Disk Access)
public actor IMessagePlatform: Platform {
    public nonisolated var name: String { "imessage" }
    private var _connected = false
    public nonisolated var isConnected: Bool { true }  // always available on macOS
    private var lastMessageDate: Date

    public init() {
        self.lastMessageDate = Date()
    }

    public func start() async throws {
        _connected = true
        lastMessageDate = Date()
    }

    public func stop() async {
        _connected = false
    }

    // MARK: - Send via AppleScript

    public func sendMessage(_ text: String, to chatId: String) async throws {
        // chatId is a phone number or email
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let phoneEscaped = chatId
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Messages"
            set targetBuddy to "\(phoneEscaped)"
            set targetService to 1st account whose service type = iMessage
            set theBuddy to participant targetBuddy of targetService
            send "\(escaped)" to theBuddy
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw GatewayError.sendFailed("osascript exit \(process.terminationStatus)")
        }
    }

    // MARK: - Poll via chat.db

    public func poll() async throws -> [(chatId: String, sender: String, text: String)] {
        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Messages/chat.db").path

        guard FileManager.default.isReadableFile(atPath: dbPath) else {
            return []  // No Full Disk Access — silently skip
        }

        // Query for messages since last poll
        let timestamp = Int(lastMessageDate.timeIntervalSinceReferenceDate) * 1_000_000_000
        // macOS stores dates as nanoseconds since 2001-01-01

        let query = """
        SELECT m.text, m.is_from_me, h.id, m.date
        FROM message m
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        WHERE m.date > \(timestamp) AND m.is_from_me = 0 AND m.text IS NOT NULL
        ORDER BY m.date ASC
        LIMIT 20;
        """

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-separator", "\t", dbPath, query]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8), !output.isEmpty else {
            return []
        }

        var messages: [(chatId: String, sender: String, text: String)] = []

        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3 else { continue }
            let text = parts[0]
            let handle = parts[2]  // phone number or email
            messages.append((chatId: handle, sender: handle, text: text))
        }

        if !messages.isEmpty {
            lastMessageDate = Date()
        }

        return messages
    }
}

public enum GatewayError: Error, LocalizedError {
    case sendFailed(String)
    case connectionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .sendFailed(let msg): return "Send failed: \(msg)"
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        }
    }
}
