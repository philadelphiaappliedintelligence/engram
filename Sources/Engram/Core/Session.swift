import Foundation

/// Session entry stored as one line of JSONL.
/// Supports tree-based branching: each entry has an id and parent id.
public struct SessionEntry: Codable, Sendable {
    public let id: String
    public let parentId: String?
    public let timestamp: Date
    public let role: String
    public let content: String        // serialized content blocks as JSON
    public let toolCalls: String?     // serialized tool calls if any
    public let tokenUsage: TokenUsage?

    public struct TokenUsage: Codable, Sendable {
        public let input: Int
        public let output: Int
    }
}

/// Manages conversation persistence as JSONL files.
/// Each session is a single file. Entries form a tree via parent IDs.
public final class SessionManager: @unchecked Sendable {
    public let sessionDir: URL
    private var currentFile: URL?
    private var entries: [SessionEntry] = []
    private var fileHandle: FileHandle?
    private let lock = NSLock()

    public init(sessionDir: URL) {
        self.sessionDir = sessionDir
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
    }

    deinit {
        fileHandle?.closeFile()
    }

    // MARK: - Session Lifecycle

    /// Start a new session. Returns the session file path.
    @discardableResult
    public func newSession() -> URL {
        lock.lock()
        defer { lock.unlock() }

        fileHandle?.closeFile()
        entries = []

        let filename = "session_\(iso8601Now())_\(shortId()).jsonl"
        let file = sessionDir.appendingPathComponent(filename)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        fileHandle = FileHandle(forWritingAtPath: file.path)
        currentFile = file
        return file
    }

    /// Resume the most recent session.
    public func resumeLatest() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let latest = listSessionFiles().last else { return false }
        return loadSession(at: latest)
    }

    /// Resume a specific session file.
    @discardableResult
    public func loadSession(at file: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        fileHandle?.closeFile()
        entries = []

        guard let data = try? String(contentsOf: file, encoding: .utf8) else { return false }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for line in data.components(separatedBy: "\n") where !line.isEmpty {
            if let lineData = line.data(using: .utf8),
               let entry = try? decoder.decode(SessionEntry.self, from: lineData) {
                entries.append(entry)
            }
        }

        currentFile = file
        fileHandle = FileHandle(forWritingAtPath: file.path)
        fileHandle?.seekToEndOfFile()
        return true
    }

    // MARK: - Append

    /// Append a message to the current session.
    public func append(role: String, content: String, toolCalls: String? = nil,
                       parentId: String? = nil, tokenUsage: SessionEntry.TokenUsage? = nil) -> String {
        lock.lock()
        defer { lock.unlock() }

        if currentFile == nil { _ = _newSessionUnlocked() }

        let id = shortId()
        let parent = parentId ?? entries.last?.id

        let entry = SessionEntry(
            id: id,
            parentId: parent,
            timestamp: Date(),
            role: role,
            content: content,
            toolCalls: toolCalls,
            tokenUsage: tokenUsage
        )

        entries.append(entry)
        writeEntry(entry)
        return id
    }

    // MARK: - Read

    /// Get all entries in the current session.
    public var currentEntries: [SessionEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    /// Reconstruct message history from session entries.
    public func messages() -> [Message] {
        lock.lock()
        defer { lock.unlock() }

        return entries.compactMap { entry in
            guard let role = Role(rawValue: entry.role) else { return nil }
            // Content is stored as plain text for simplicity
            return Message(role: role, text: entry.content)
        }
    }

    /// Current session file path.
    public var currentSessionFile: URL? {
        lock.lock()
        defer { lock.unlock() }
        return currentFile
    }

    // MARK: - List Sessions

    public func listSessionFiles() -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: sessionDir, includingPropertiesForKeys: [.creationDateKey]
        ) else { return [] }

        return contents
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Summary of all sessions for display.
    public func listSessions() -> [SessionSummary] {
        listSessionFiles().compactMap { file in
            guard let data = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let lines = data.components(separatedBy: "\n").filter { !$0.isEmpty }
            guard !lines.isEmpty else { return nil }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            // Get first user message as preview
            var preview = ""
            var messageCount = 0
            for line in lines {
                messageCount += 1
                if let lineData = line.data(using: .utf8),
                   let entry = try? decoder.decode(SessionEntry.self, from: lineData),
                   entry.role == "user", preview.isEmpty {
                    preview = String(entry.content.prefix(80))
                }
            }

            return SessionSummary(
                file: file,
                messageCount: messageCount,
                preview: preview,
                filename: file.lastPathComponent
            )
        }
    }

    // MARK: - Compaction

    /// Compact the session by summarizing old messages.
    /// Keeps the first `keepFirst` and last `keepLast` entries,
    /// replaces the middle with a summary.
    public func compact(keepFirst: Int = 2, keepLast: Int = 4,
                        summarizer: (String) async throws -> String) async throws {
        lock.lock()
        let count = entries.count
        lock.unlock()

        guard count > keepFirst + keepLast + 2 else { return }

        lock.lock()
        let middleStart = keepFirst
        let middleEnd = count - keepLast
        let middleEntries = Array(entries[middleStart..<middleEnd])
        lock.unlock()

        // Build text to summarize
        let text = middleEntries.map { "[\($0.role)] \($0.content)" }.joined(separator: "\n")
        let summary = try await summarizer(text)

        lock.lock()
        // Replace middle with a single summary entry
        let summaryEntry = SessionEntry(
            id: shortId(),
            parentId: entries[middleStart - 1].id,
            timestamp: Date(),
            role: "user",
            content: "[Conversation summary: \(summary)]",
            toolCalls: nil,
            tokenUsage: nil
        )

        var newEntries = Array(entries[0..<middleStart])
        newEntries.append(summaryEntry)
        // Fix parent chain for kept-last entries
        var lastId = summaryEntry.id
        for i in middleEnd..<count {
            let old = entries[i]
            let fixed = SessionEntry(
                id: old.id,
                parentId: lastId,
                timestamp: old.timestamp,
                role: old.role,
                content: old.content,
                toolCalls: old.toolCalls,
                tokenUsage: old.tokenUsage
            )
            newEntries.append(fixed)
            lastId = old.id
        }

        entries = newEntries

        // Rewrite file
        fileHandle?.closeFile()
        if let file = currentFile {
            try? rewriteFile(file, entries: entries)
            fileHandle = FileHandle(forWritingAtPath: file.path)
            fileHandle?.seekToEndOfFile()
        }
        lock.unlock()
    }

    // MARK: - Private

    private func _newSessionUnlocked() -> URL {
        let filename = "session_\(iso8601Now())_\(shortId()).jsonl"
        let file = sessionDir.appendingPathComponent(filename)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        fileHandle = FileHandle(forWritingAtPath: file.path)
        currentFile = file
        return file
    }

    private func writeEntry(_ entry: SessionEntry) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry),
              let line = String(data: data, encoding: .utf8) else { return }
        if let lineData = (line + "\n").data(using: .utf8) {
            fileHandle?.write(lineData)
        }
    }

    private func rewriteFile(_ file: URL, entries: [SessionEntry]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var content = ""
        for entry in entries {
            if let data = try? encoder.encode(entry),
               let line = String(data: data, encoding: .utf8) {
                content += line + "\n"
            }
        }
        try content.write(to: file, atomically: true, encoding: .utf8)
    }
}

// MARK: - Types

public struct SessionSummary: Sendable {
    public let file: URL
    public let messageCount: Int
    public let preview: String
    public let filename: String
}

// MARK: - Helpers

private func shortId() -> String {
    let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
    return String((0..<8).map { _ in chars.randomElement()! })
}

private func iso8601Now() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd_HHmmss"
    return f.string(from: Date())
}
