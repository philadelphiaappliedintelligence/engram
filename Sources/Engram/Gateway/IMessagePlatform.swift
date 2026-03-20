import Foundation

/// iMessage gateway with optional IMCore advanced features.
///
/// Basic mode: AppleScript send + chat.db poll (requires Full Disk Access)
/// Advanced mode (SIP disabled): typing indicators, read receipts, tapback reactions
///   via injected dylib communicating with IMCore private APIs.
public actor IMessagePlatform: Platform {
    public nonisolated var name: String { "imessage" }
    private var _connected = false
    public nonisolated var isConnected: Bool { true }
    private var lastMessageDate: Date
    private var allowedHandles: Set<String>?
    private let imcore: IMCoreBridge?
    private var imcoreAvailable = false
    private var seenGUIDs: Set<String> = []
    private var isProcessing = false

    public init(config: IMessageConfig = IMessageConfig()) {
        self.lastMessageDate = Date()
        if let handles = config.allowedHandles, !handles.isEmpty {
            self.allowedHandles = Set(handles.map { normalizeHandle($0) })
        }

        // Initialize IMCore bridge if enabled and SIP is disabled
        if config.enableIMCore != false {
            let sip = checkSIPStatus()
            if sip == .disabled {
                self.imcore = IMCoreBridge()
            } else {
                self.imcore = nil
            }
        } else {
            self.imcore = nil
        }
    }

    public func start() async throws {
        // Check Full Disk Access
        let chatDB = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Messages/chat.db")
        guard FileManager.default.isReadableFile(atPath: chatDB.path) else {
            throw GatewayError.connectionFailed(
                "Full Disk Access required for iMessage gateway. " +
                "Grant in System Settings > Privacy & Security > Full Disk Access."
            )
        }

        _connected = true
        lastMessageDate = Date()

        // Try to start IMCore bridge
        if let imcore, imcore.isAvailable {
            do {
                try imcore.ensureRunning()
                imcoreAvailable = true
            } catch {
                // Non-fatal — basic mode still works
                imcoreAvailable = false
            }
        }
    }

    public func stop() async {
        _connected = false
    }

    // MARK: - Send via AppleScript

    public func sendMessage(_ text: String, to chatId: String) async throws {
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

        // Mark as read after sending
        if imcoreAvailable, let imcore {
            try? await imcore.markAsRead(handle: chatId)
        }
    }

    // MARK: - Typing Indicator

    public func sendTyping(to chatId: String) async throws {
        if imcoreAvailable, let imcore {
            try await imcore.setTyping(for: chatId, typing: true)
        }
    }

    /// Clear typing indicator for a chat.
    public func clearTyping(for chatId: String) async throws {
        if imcoreAvailable, let imcore {
            try await imcore.setTyping(for: chatId, typing: false)
        }
    }

    // MARK: - Read Receipts

    public func markAsRead(handle: String) async throws {
        if imcoreAvailable, let imcore {
            try await imcore.markAsRead(handle: handle)
        }
    }

    // MARK: - Tapback Reactions

    public func sendReaction(to handle: String, messageGUID: String, type: TapbackType) async throws {
        guard imcoreAvailable, let imcore else {
            throw IMCoreError.sipRequired
        }
        try await imcore.sendTapback(to: handle, messageGUID: messageGUID, type: type)
    }

    // MARK: - Poll via chat.db

    public func poll() async throws -> [(chatId: String, sender: String, text: String)] {
        // Skip if still processing previous batch
        guard !isProcessing else { return [] }

        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Messages/chat.db").path

        guard FileManager.default.isReadableFile(atPath: dbPath) else {
            return []
        }

        let timestamp = Int(lastMessageDate.timeIntervalSinceReferenceDate) * 1_000_000_000

        let query = """
        SELECT m.text, m.is_from_me, h.id, m.date, m.guid
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
            guard parts.count >= 5 else { continue }
            let text = parts[0]
            let handle = parts[2]
            let guid = parts[4]

            // Dedup: skip already-seen messages
            guard !seenGUIDs.contains(guid) else { continue }
            seenGUIDs.insert(guid)

            // Allowlist check
            if let allowed = allowedHandles {
                let normalized = normalizeHandle(handle)
                guard allowed.contains(normalized) else { continue }
            }

            messages.append((chatId: handle, sender: handle, text: text))
        }

        if !messages.isEmpty {
            // Update timestamp immediately to prevent re-fetch
            lastMessageDate = Date()
            isProcessing = true

            // Auto-mark as read
            if imcoreAvailable, let imcore {
                let handles = Set(messages.map(\.chatId))
                for handle in handles {
                    try? await imcore.markAsRead(handle: handle)
                }
            }
        }

        // Cap seen GUIDs to prevent unbounded growth
        if seenGUIDs.count > 1000 {
            seenGUIDs = Set(seenGUIDs.suffix(500))
        }

        return messages
    }

    /// Call after processing a batch to allow the next poll.
    public func doneProcessing() {
        isProcessing = false
    }

    // MARK: - Reconnect

    public func reconnect() async throws {
        try await start()
    }

    // MARK: - Status

    public var advancedFeaturesAvailable: Bool { imcoreAvailable }
}

// MARK: - Handle Normalization

/// Normalize phone numbers/emails for allowlist matching.
/// Strips +, spaces, dashes, parens — keeps only digits for phone numbers.
private func normalizeHandle(_ handle: String) -> String {
    let trimmed = handle.trimmingCharacters(in: .whitespaces)
    if trimmed.contains("@") { return trimmed.lowercased() }
    // Phone number — keep only digits
    let digits = trimmed.filter { $0.isNumber }
    // Strip leading 1 for US numbers
    if digits.count == 11 && digits.hasPrefix("1") {
        return String(digits.dropFirst())
    }
    return digits
}

// MARK: - Errors

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
