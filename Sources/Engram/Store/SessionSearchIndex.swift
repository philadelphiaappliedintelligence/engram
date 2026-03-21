import Foundation
import CoreServices

/// SearchKit-backed full-text search for chat sessions.
/// Uses SKIndex (same engine as Spotlight) for inverted-index FTS.
public final class SessionSearchIndex: @unchecked Sendable {
    // SKIndex is stored as Unmanaged to prevent Swift ARC from calling objc_release
    // on dealloc — SKIndex crashes when released from async deinit context.
    private var indexRef: Unmanaged<SKIndex>?
    private let indexURL: URL
    private let lock = NSLock()

    private var index: SKIndex? { indexRef?.takeUnretainedValue() }

    public init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".engram")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.indexURL = dir.appendingPathComponent("search.skindex")

        // Open existing or create new
        if FileManager.default.fileExists(atPath: indexURL.path),
           let ref = SKIndexOpenWithURL(indexURL as CFURL, nil, true) {
            self.indexRef = ref
        } else {
            try? FileManager.default.removeItem(at: indexURL)
            if let ref = SKIndexCreateWithURL(indexURL as CFURL, nil, kSKIndexInverted, nil) {
                self.indexRef = ref
            }
        }
    }

    deinit {
        // Intentionally not closing — SKIndexClose from Swift async deinit crashes.
        // The index flushes on write, and the OS reclaims on process exit.
        // For the daemon (long-running), flush() is called periodically.
    }

    // MARK: - Index

    public func addMessage(id: String, content: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let index else { return }

        // Use file:// URLs for document references (SearchKit expects this)
        let docPath = indexURL.deletingLastPathComponent()
            .appendingPathComponent("msg-\(id)").path
        let docURL = URL(fileURLWithPath: docPath) as CFURL
        guard let doc = SKDocumentCreateWithURL(docURL) else { return }
        SKIndexAddDocumentWithText(index, doc.takeRetainedValue(), content as CFString, true)
    }

    public func flush() {
        lock.lock()
        defer { lock.unlock() }
        guard let index else { return }
        SKIndexFlush(index)
    }

    // MARK: - Search

    public func search(query: String, limit: Int = 20) -> [(id: String, score: Float)] {
        lock.lock()
        defer { lock.unlock() }
        guard let index else { return [] }

        SKIndexFlush(index)

        guard let searchRef = SKSearchCreate(index, query as CFString, SKSearchOptions(kSKSearchOptionDefault)) else { return [] }
        let search = searchRef.takeRetainedValue()

        var documentIDs = [SKDocumentID](repeating: 0, count: limit)
        var scores = [Float](repeating: 0, count: limit)
        var foundCount: CFIndex = 0

        SKSearchFindMatches(search, CFIndex(limit), &documentIDs, &scores, 1.0, &foundCount)

        var results: [(id: String, score: Float)] = []
        for i in 0..<Int(foundCount) {
            guard let docRef = SKIndexCopyDocumentForDocumentID(index, documentIDs[i]) else { continue }
            let doc = docRef.takeRetainedValue()
            guard let urlRef = SKDocumentCopyURL(doc) else { continue }
            let url = urlRef.takeRetainedValue() as URL

            // Extract message ID from the filename
            let filename = url.lastPathComponent
            if filename.hasPrefix("msg-") {
                let id = String(filename.dropFirst(4))
                results.append((id: id, score: scores[i]))
            }
        }

        return results.sorted { $0.score > $1.score }
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }

        if let indexRef {
            let idx = indexRef.takeRetainedValue()
            SKIndexClose(idx)
        }
        self.indexRef = nil

        try? FileManager.default.removeItem(at: indexURL)

        if let ref = SKIndexCreateWithURL(indexURL as CFURL, nil, kSKIndexInverted, nil) {
            self.indexRef = ref
        }
    }
}
