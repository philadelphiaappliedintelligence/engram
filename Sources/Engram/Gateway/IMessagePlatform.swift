import Foundation

/// iMessage gateway with filesystem-event-driven message detection.
///
/// Instead of polling on a timer, watches chat.db for filesystem changes
/// via kqueue (DispatchSource), triggering a query within 250ms of new messages.
/// Sends via AppleScript with stdin+argv (imsg-plus approach).
/// Optional IMCore bridge for typing indicators, read receipts, and tapback reactions.
public actor IMessagePlatform: Platform {
    public nonisolated var name: String { "imessage" }
    private var _connected = false
    public nonisolated var isConnected: Bool { true }
    private var allowedHandles: Set<String>?
    private let imcore: IMCoreBridge?
    private var imcoreAvailable = false
    private var lastRowID: Int64 = 0
    private var pendingMessages: [(chatId: String, sender: String, text: String)] = []
    private var watcher: ChatDBWatcher?
    private var seenGUIDs: Set<String> = []

    public init(config: IMessageConfig = IMessageConfig()) {
        if let handles = config.allowedHandles, !handles.isEmpty {
            self.allowedHandles = Set(handles.map { normalizeHandle($0) })
        }

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
        let chatDB = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Messages/chat.db")
        guard FileManager.default.isReadableFile(atPath: chatDB.path) else {
            throw GatewayError.connectionFailed(
                "Full Disk Access required for iMessage gateway. " +
                "Grant in System Settings > Privacy & Security > Full Disk Access."
            )
        }

        // Get current max ROWID so we only see new messages
        lastRowID = queryMaxRowID(dbPath: chatDB.path)

        // Start filesystem watcher on chat.db
        watcher = ChatDBWatcher(dbPath: chatDB.path) { [weak self] in
            guard let self else { return }
            Task { await self.onDBChange() }
        }

        _connected = true

        // Try to start IMCore bridge
        if let imcore, imcore.isAvailable {
            do {
                try imcore.ensureRunning()
                imcoreAvailable = true
            } catch {
                imcoreAvailable = false
            }
        }
    }

    public func stop() async {
        watcher?.stop()
        watcher = nil
        _connected = false
    }

    // MARK: - DB Change Handler

    private func onDBChange() {
        let chatDB = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Messages/chat.db").path

        let query = """
        SELECT m.ROWID, m.text, m.is_from_me, h.id, m.guid
        FROM message m
        LEFT JOIN handle h ON m.handle_id = h.ROWID
        WHERE m.ROWID > \(lastRowID) AND m.is_from_me = 0 AND m.text IS NOT NULL
        ORDER BY m.ROWID ASC
        LIMIT 20;
        """

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-separator", "\t", chatDB, query]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8), !output.isEmpty else { return }

        for line in output.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 5 else { continue }
            guard let rowID = Int64(parts[0]) else { continue }
            let text = parts[1]
            let handle = parts[3]
            let guid = parts[4]

            // Update cursor
            if rowID > lastRowID { lastRowID = rowID }

            // Dedup
            guard !seenGUIDs.contains(guid) else { continue }
            seenGUIDs.insert(guid)

            // Allowlist
            if let allowed = allowedHandles {
                guard allowed.contains(normalizeHandle(handle)) else { continue }
            }

            pendingMessages.append((chatId: handle, sender: handle, text: text))
        }

        // Cap seen GUIDs
        if seenGUIDs.count > 1000 {
            seenGUIDs = Set(seenGUIDs.suffix(500))
        }
    }

    // MARK: - Poll (drains pending messages from watcher)

    public func poll() async throws -> [(chatId: String, sender: String, text: String)] {
        let messages = pendingMessages
        pendingMessages = []

        if !messages.isEmpty, imcoreAvailable, let imcore {
            let handles = Set(messages.map(\.chatId))
            for handle in handles {
                try? await imcore.markAsRead(handle: handle)
            }
        }

        return messages
    }

    // MARK: - Send via AppleScript (stdin + argv, imsg-plus approach)

    public func sendMessage(_ text: String, to chatId: String) async throws {
        let script = """
        on run argv
            set theRecipient to item 1 of argv
            set theMessage to item 2 of argv
            tell application "Messages"
                set targetService to first service whose service type is iMessage
                set targetBuddy to buddy theRecipient of targetService
                send theMessage to targetBuddy
            end tell
        end run
        """

        try runAppleScript(script, arguments: [chatId, text])

        if imcoreAvailable, let imcore {
            try? await imcore.markAsRead(handle: chatId)
        }
    }

    // MARK: - Send File

    public func sendFile(path: String, caption: String?, to chatId: String) async throws {
        // Stage into Messages Attachments directory
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let attachDir = home.appendingPathComponent("Library/Messages/Attachments/engram/\(UUID().uuidString)")
        try fm.createDirectory(at: attachDir, withIntermediateDirectories: true)
        let filename = URL(fileURLWithPath: path).lastPathComponent
        let stagedPath = attachDir.appendingPathComponent(filename).path
        try fm.copyItem(atPath: path, toPath: stagedPath)

        let script = """
        on run argv
            set theRecipient to item 1 of argv
            set theMessage to item 2 of argv
            set theFilePath to item 3 of argv
            set useAttachment to item 4 of argv

            tell application "Messages"
                set targetService to first service whose service type is iMessage
                set targetBuddy to buddy theRecipient of targetService
                if theMessage is not "" then
                    send theMessage to targetBuddy
                end if
                if useAttachment is "1" then
                    set theFile to POSIX file theFilePath as alias
                    send theFile to targetBuddy
                end if
            end tell
        end run
        """

        try runAppleScript(script, arguments: [chatId, caption ?? "", stagedPath, "1"])
    }

    // MARK: - Typing / Read / Tapback

    public func sendTyping(to chatId: String) async throws {
        if imcoreAvailable, let imcore {
            try await imcore.setTyping(for: chatId, typing: true)
        }
    }

    public func clearTyping(for chatId: String) async throws {
        if imcoreAvailable, let imcore {
            try await imcore.setTyping(for: chatId, typing: false)
        }
    }

    public func markAsRead(handle: String) async throws {
        if imcoreAvailable, let imcore {
            try await imcore.markAsRead(handle: handle)
        }
    }

    public func sendReaction(to handle: String, messageGUID: String, type: TapbackType) async throws {
        guard imcoreAvailable, let imcore else { throw IMCoreError.sipRequired }
        try await imcore.sendTapback(to: handle, messageGUID: messageGUID, type: type)
    }

    public func reconnect() async throws {
        try await start()
    }

    public var advancedFeaturesAvailable: Bool { imcoreAvailable }

    // MARK: - AppleScript Runner

    private func runAppleScript(_ source: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "AppleScript", "-"] + arguments
        let stdinPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        try process.run()
        if let data = source.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
        stdinPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? ""
            throw GatewayError.sendFailed("osascript: \(errMsg)")
        }
    }

    // MARK: - SQLite Helpers

    private func queryMaxRowID(dbPath: String) -> Int64 {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [dbPath, "SELECT MAX(ROWID) FROM message;"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
        return Int64(str) ?? 0
    }
}

// MARK: - Chat DB Filesystem Watcher

/// Watches chat.db, chat.db-wal, and chat.db-shm for filesystem changes
/// using kqueue (DispatchSource). Fires a callback with 250ms debounce.
private final class ChatDBWatcher: @unchecked Sendable {
    private var sources: [DispatchSourceFileSystemObject] = []
    private let queue = DispatchQueue(label: "engram.chatdb.watch", qos: .userInitiated)
    private let callback: () -> Void
    private var pending = false

    init(dbPath: String, callback: @escaping () -> Void) {
        self.callback = callback

        let paths = [dbPath, "\(dbPath)-wal", "\(dbPath)-shm"]
        for path in paths {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .rename, .delete],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                self?.schedulePoll()
            }
            source.setCancelHandler {
                close(fd)
            }
            source.resume()
            sources.append(source)
        }
    }

    func stop() {
        for source in sources {
            source.cancel()
        }
        sources.removeAll()
    }

    private func schedulePoll() {
        if pending { return }
        pending = true
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.pending = false
            self.callback()
        }
    }
}

// MARK: - Handle Normalization

private func normalizeHandle(_ handle: String) -> String {
    let trimmed = handle.trimmingCharacters(in: .whitespaces)
    if trimmed.contains("@") { return trimmed.lowercased() }
    let digits = trimmed.filter { $0.isNumber }
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
