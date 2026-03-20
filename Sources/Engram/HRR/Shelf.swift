import Foundation

/// Multi-topic holographic memory manager.
/// Each nugget is a topic-scoped memory (e.g. "preferences", "project", "people").
public final class Shelf: Sendable {
    public let saveDir: URL
    private let _nuggets: LockedValue<[String: Nugget]>
    private let dimension: Int

    public init(saveDir: URL, dimension: Int = 512) {
        self.saveDir = saveDir
        self.dimension = dimension
        self._nuggets = LockedValue([:])
    }

    // MARK: - Nugget Management

    public func nugget(named name: String) -> Nugget {
        _nuggets.withLock { nuggets in
            if let existing = nuggets[name] { return existing }
            let n = Nugget(name: name, dimension: dimension)
            nuggets[name] = n
            return n
        }
    }

    public func hasNugget(named name: String) -> Bool {
        _nuggets.withLock { $0[name] != nil }
    }

    public func removeNugget(named name: String) {
        _nuggets.withLock { $0.removeValue(forKey: name) }
        let file = saveDir.appendingPathComponent("\(name).nugget.json")
        try? FileManager.default.removeItem(at: file)
    }

    public var nuggetNames: [String] {
        _nuggets.withLock { Array($0.keys).sorted() }
    }

    // MARK: - Convenience

    public func remember(nugget name: String, key: String, value: String) {
        nugget(named: name).remember(key: key, value: value)
    }

    /// Recall from a specific nugget, or search all nuggets for the best match
    public func recall(query: String, nugget name: String? = nil,
                       sessionId: String? = nil) -> ShelfRecallResult {
        if let name {
            let result = nugget(named: name).recall(query: query, sessionId: sessionId)
            return ShelfRecallResult(nuggetName: name, result: result)
        }

        // Search all nuggets, return the highest-confidence match
        let allNuggets = _nuggets.withLock { Array($0) }
        var best: ShelfRecallResult?

        for (name, nug) in allNuggets {
            let result = nug.recall(query: query, sessionId: sessionId)
            if result.found {
                if best == nil || result.confidence > (best?.result.confidence ?? 0) {
                    best = ShelfRecallResult(nuggetName: name, result: result)
                }
            }
        }

        return best ?? ShelfRecallResult(
            nuggetName: "",
            result: RecallResult()
        )
    }

    @discardableResult
    public func forget(nugget name: String, key: String) -> Bool {
        nugget(named: name).forget(key: key)
    }

    // MARK: - Status

    public func status() -> [NuggetStatus] {
        let all = _nuggets.withLock { Array($0) }
        return all.map { name, nug in
            let facts = nug.facts
            return NuggetStatus(
                name: name,
                factCount: facts.count,
                promotableCount: facts.filter { $0.hits >= 3 }.count,
                topFacts: Array(facts.sorted { $0.hits > $1.hits }.prefix(5))
            )
        }.sorted { $0.name < $1.name }
    }

    // MARK: - Promotion

    /// Collect all facts recalled 3+ times across all nuggets.
    /// These should be injected directly into the system prompt as permanent context.
    public func promotedFacts() -> [(nugget: String, fact: Fact)] {
        let all = _nuggets.withLock { Array($0) }
        var promoted: [(nugget: String, fact: Fact)] = []
        for (name, nug) in all {
            for fact in nug.promotableFacts {
                promoted.append((nugget: name, fact: fact))
            }
        }
        return promoted.sorted { $0.fact.hits > $1.fact.hits }
    }

    // MARK: - Persistence

    public func loadAll() {
        let fm = FileManager.default
        try? fm.createDirectory(at: saveDir, withIntermediateDirectories: true)

        guard let contents = try? fm.contentsOfDirectory(
            at: saveDir, includingPropertiesForKeys: nil
        ) else { return }

        for file in contents where file.pathExtension == "json" &&
            file.lastPathComponent.hasSuffix(".nugget.json") {
            do {
                let nugget = try Nugget.load(from: file)
                _nuggets.withLock { $0[nugget.name] = nugget }
            } catch {
                // Skip corrupt files
            }
        }
    }

    public func saveAll() {
        let fm = FileManager.default
        try? fm.createDirectory(at: saveDir, withIntermediateDirectories: true)

        let all = _nuggets.withLock { Array($0) }
        for (name, nug) in all {
            let file = saveDir.appendingPathComponent("\(name).nugget.json")
            try? nug.save(to: file)
        }
    }
}

// MARK: - Types

public struct ShelfRecallResult: Sendable {
    public let nuggetName: String
    public let result: RecallResult
}

public struct NuggetStatus: Sendable {
    public let name: String
    public let factCount: Int
    public let promotableCount: Int
    public let topFacts: [Fact]
}
