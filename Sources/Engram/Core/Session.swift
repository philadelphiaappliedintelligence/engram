import Foundation

/// Session entry — lightweight struct for in-memory use.
/// Persistence is handled by EngramStore (SwiftData).
public struct SessionEntry: Codable, Sendable {
    public let id: String
    public let parentId: String?
    public let timestamp: Date
    public let role: String
    public let content: String
    public let toolCalls: String?
    public let tokenUsage: TokenUsage?

    public struct TokenUsage: Codable, Sendable {
        public let input: Int
        public let output: Int
    }
}

/// Manages conversation persistence via EngramStore.
/// Falls back to JSONL files if no store is provided.
public final class SessionManager: @unchecked Sendable {
    public let sessionDir: URL
    private var currentSessionId: String?
    private var entries: [SessionEntry] = []
    private let lock = NSLock()
    private let store: EngramStore?
    private let searchIndex: SessionSearchIndex?

    // Legacy file-based fields
    private var currentFile: URL?
    private var fileHandle: FileHandle?

    public init(sessionDir: URL, store: EngramStore? = nil, searchIndex: SessionSearchIndex? = nil) {
        self.sessionDir = sessionDir
        self.store = store
        self.searchIndex = searchIndex
        if store == nil {
            try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        }
    }

    deinit {
        fileHandle?.closeFile()
    }

    // MARK: - Session Lifecycle

    @discardableResult
    public func newSession() -> String {
        lock.lock()
        defer { lock.unlock() }

        fileHandle?.closeFile()
        entries = []

        let sessionId = "\(iso8601Now())_\(shortId())"
        currentSessionId = sessionId

        if let store {
            Task { await store.createSession(id: sessionId) }
        } else {
            let filename = "session_\(sessionId).jsonl"
            let file = sessionDir.appendingPathComponent(filename)
            FileManager.default.createFile(atPath: file.path, contents: nil)
            fileHandle = FileHandle(forWritingAtPath: file.path)
            currentFile = file
        }

        return sessionId
    }

    /// Resume the most recent session.
    public func resumeLatest() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if let store {
            // Get latest session from store
            var latestId: String?
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                latestId = await store.latestSessionId()
                semaphore.signal()
            }
            semaphore.wait()

            guard let id = latestId else { return false }
            return _loadSessionFromStore(id: id)
        } else {
            guard let latest = listSessionFiles().last else { return false }
            return _loadSessionFromFile(at: latest)
        }
    }

    // MARK: - Append

    public func append(role: String, content: String, toolCalls: String? = nil,
                       parentId: String? = nil, tokenUsage: SessionEntry.TokenUsage? = nil) -> String {
        lock.lock()
        defer { lock.unlock() }

        if currentSessionId == nil { _ = _newSessionUnlocked() }

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

        if let store, let sessionId = currentSessionId {
            let tokIn = tokenUsage?.input
            let tokOut = tokenUsage?.output
            Task {
                await store.appendMessage(sessionId: sessionId, role: role, content: content,
                                          tokensIn: tokIn, tokensOut: tokOut)
            }
        } else {
            writeEntry(entry)
        }

        // Index for search
        if let searchIndex, let sessionId = currentSessionId {
            let msgId = "\(sessionId):\(entries.count)"
            searchIndex.addMessage(id: msgId, content: content)
        }

        return id
    }

    // MARK: - Read

    public var currentEntries: [SessionEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    public func messages() -> [Message] {
        lock.lock()
        defer { lock.unlock() }

        return entries.compactMap { entry in
            guard let role = Role(rawValue: entry.role) else { return nil }
            return Message(role: role, text: entry.content)
        }
    }

    public var currentSessionFile: URL? {
        lock.lock()
        defer { lock.unlock() }
        return currentFile
    }

    public var activeSessionId: String? {
        lock.lock()
        defer { lock.unlock() }
        return currentSessionId
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

    public func listSessions() -> [SessionSummary] {
        if let store {
            var results: [(id: String, preview: String?, count: Int, date: Date)] = []
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                results = await store.listSessions()
                semaphore.signal()
            }
            semaphore.wait()

            return results.map { r in
                SessionSummary(
                    file: sessionDir.appendingPathComponent(r.id),
                    messageCount: r.count,
                    preview: r.preview ?? "",
                    filename: r.id
                )
            }
        }

        return listSessionFiles().compactMap { file in
            guard let data = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let lines = data.components(separatedBy: "\n").filter { !$0.isEmpty }
            guard !lines.isEmpty else { return nil }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

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

    public func compact(keepFirst: Int = 2, keepLast: Int = 4,
                        summarizer: (String) async throws -> String) async throws {
        let (count, middleEntries, middleStart, middleEnd) = lock.withLock { () -> (Int, [SessionEntry], Int, Int) in
            let c = entries.count
            guard c > keepFirst + keepLast + 2 else { return (c, [], 0, 0) }
            let ms = keepFirst
            let me = c - keepLast
            return (c, Array(entries[ms..<me]), ms, me)
        }

        guard count > keepFirst + keepLast + 2 else { return }

        let text = middleEntries.map { "[\($0.role)] \($0.content)" }.joined(separator: "\n")
        let summary = try await summarizer(text)

        lock.withLock {
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

            if store == nil {
                fileHandle?.closeFile()
                if let file = currentFile {
                    try? rewriteFile(file, entries: entries)
                    fileHandle = FileHandle(forWritingAtPath: file.path)
                    fileHandle?.seekToEndOfFile()
                }
            }
        }
    }

    // MARK: - Private

    private func _newSessionUnlocked() -> String {
        let sessionId = "\(iso8601Now())_\(shortId())"
        currentSessionId = sessionId

        if let store {
            Task { await store.createSession(id: sessionId) }
        } else {
            let filename = "session_\(sessionId).jsonl"
            let file = sessionDir.appendingPathComponent(filename)
            FileManager.default.createFile(atPath: file.path, contents: nil)
            fileHandle = FileHandle(forWritingAtPath: file.path)
            currentFile = file
        }

        return sessionId
    }

    private func _loadSessionFromStore(id: String) -> Bool {
        currentSessionId = id
        entries = []

        var msgs: [(role: String, content: String, tokensIn: Int?, tokensOut: Int?, timestamp: Date)] = []
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            msgs = await store!.loadMessages(sessionId: id)
            semaphore.signal()
        }
        semaphore.wait()

        for (i, msg) in msgs.enumerated() {
            let entry = SessionEntry(
                id: shortId(),
                parentId: i > 0 ? entries[i - 1].id : nil,
                timestamp: msg.timestamp,
                role: msg.role,
                content: msg.content,
                toolCalls: nil,
                tokenUsage: msg.tokensIn != nil ? SessionEntry.TokenUsage(input: msg.tokensIn!, output: msg.tokensOut ?? 0) : nil
            )
            entries.append(entry)
        }
        return !entries.isEmpty
    }

    @discardableResult
    private func _loadSessionFromFile(at file: URL) -> Bool {
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
        // Extract session ID from filename
        let name = file.deletingPathExtension().lastPathComponent
        currentSessionId = name.hasPrefix("session_") ? String(name.dropFirst(8)) : name
        fileHandle = FileHandle(forWritingAtPath: file.path)
        fileHandle?.seekToEndOfFile()
        return true
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
