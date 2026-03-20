import Foundation
import CoreServices

/// SearchKit-backed full-text search for chat sessions.
/// Uses SKIndex (same engine as Spotlight) for inverted-index FTS.
public final class SessionSearchIndex: @unchecked Sendable {
    private var index: SKIndex?
    private let indexURL: URL
    private let lock = NSLock()
    private var indexValid = false

    public init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".engram")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.indexURL = dir.appendingPathComponent("search.skindex")

        // Try to open existing index, or create a new one
        if FileManager.default.fileExists(atPath: indexURL.path) {
            if let ref = SKIndexOpenWithURL(indexURL as CFURL, nil, true) {
                self.index = ref.takeRetainedValue()
                self.indexValid = true
            }
        }

        if !indexValid {
            let properties: [String: Any] = [
                kSKMinTermLength as String: 2,
                kSKProximityIndexing as String: true,
            ]
            if let ref = SKIndexCreateWithURL(indexURL as CFURL, nil, kSKIndexInverted, properties as CFDictionary) {
                self.index = ref.takeRetainedValue()
                self.indexValid = true
            }
        }
    }

    deinit {
        guard indexValid, let index else { return }
        SKIndexFlush(index)
        SKIndexClose(index)
    }

    // MARK: - Index

    /// Add a message to the search index.
    /// The documentID should be unique (e.g. "sessionId:messageIndex").
    public func addMessage(id: String, content: String) {
        lock.lock()
        defer { lock.unlock() }
        guard indexValid, let index else { return }

        let docURL = URL(string: "engram://message/\(id)")! as CFURL
        guard let doc = SKDocumentCreateWithURL(docURL) else { return }
        SKIndexAddDocumentWithText(index, doc.takeUnretainedValue(), content as CFString, true)
    }

    /// Flush pending changes to disk.
    public func flush() {
        lock.lock()
        defer { lock.unlock() }
        guard indexValid, let index else { return }
        SKIndexFlush(index)
    }

    // MARK: - Search

    /// Search the index. Returns (documentId, score) pairs sorted by relevance.
    public func search(query: String, limit: Int = 20) -> [(id: String, score: Float)] {
        lock.lock()
        defer { lock.unlock() }
        guard indexValid, let index else { return [] }

        // Flush before searching to ensure all documents are indexed
        SKIndexFlush(index)

        let options = SKSearchOptions(kSKSearchOptionDefault)
        guard let searchRef = SKSearchCreate(index, query as CFString, options) else { return [] }
        let search = searchRef.takeRetainedValue()

        var documentIDs = [SKDocumentID](repeating: 0, count: limit)
        var scores = [Float](repeating: 0, count: limit)
        var foundCount: CFIndex = 0

        SKSearchFindMatches(search, CFIndex(limit), &documentIDs, &scores, 1.0, &foundCount)

        var results: [(id: String, score: Float)] = []
        for i in 0..<Int(foundCount) {
            let docID = documentIDs[i]
            guard let docRef = SKIndexCopyDocumentForDocumentID(index, docID) else { continue }
            let doc = docRef.takeRetainedValue()
            guard let urlRef = SKDocumentCopyURL(doc) else { continue }
            let url = urlRef.takeRetainedValue() as URL

            let path = url.absoluteString
            if let range = path.range(of: "engram://message/") {
                let id = String(path[range.upperBound...])
                results.append((id: id, score: scores[i]))
            }
        }

        return results.sorted { $0.score > $1.score }
    }

    /// Remove all indexed documents and recreate the index.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }

        if indexValid, let index {
            SKIndexClose(index)
        }
        self.index = nil
        self.indexValid = false

        try? FileManager.default.removeItem(at: indexURL)

        let properties: [String: Any] = [
            kSKMinTermLength as String: 2,
            kSKProximityIndexing as String: true,
        ]
        if let ref = SKIndexCreateWithURL(indexURL as CFURL, nil, kSKIndexInverted, properties as CFDictionary) {
            self.index = ref.takeRetainedValue()
            self.indexValid = true
        }
    }
}
