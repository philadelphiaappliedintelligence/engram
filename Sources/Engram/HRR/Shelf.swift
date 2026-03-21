import Foundation

/// Multi-topic holographic memory manager.
/// Each artifact is a topic-scoped memory (e.g. "preferences", "project", "people").
/// Persistence is backed by EngramStore (SwiftData).
public final class Shelf: Sendable {
    public let saveDir: URL
    private let _artifacts: LockedValue<[String: Artifact]>
    private let dimension: Int
    private let _store: LockedValue<EngramStore?>

    public init(saveDir: URL, dimension: Int = 512, store: EngramStore? = nil) {
        self.saveDir = saveDir
        self.dimension = dimension
        self._artifacts = LockedValue([:])
        self._store = LockedValue(store)
    }

    /// Update the backing store (e.g. after async initialization).
    public func setStore(_ store: EngramStore) {
        _store.withLock { $0 = store }
    }

    // MARK: - Artifact Management

    public func artifact(named name: String) -> Artifact {
        _artifacts.withLock { artifacts in
            if let existing = artifacts[name] { return existing }
            let n = Artifact(name: name, dimension: dimension)
            artifacts[name] = n
            return n
        }
    }

    public func hasArtifact(named name: String) -> Bool {
        _artifacts.withLock { $0[name] != nil }
    }

    public func removeArtifact(named name: String) {
        _artifacts.withLock { $0.removeValue(forKey: name) }
        // Also remove from store if available
        if let store = _store.withLock({ $0 }) {
            let artifactName = name
            Task {
                let facts = await store.loadFacts(artifact: artifactName)
                for fact in facts {
                    _ = await store.deleteFact(artifact: artifactName, key: fact.key)
                }
            }
        }
    }

    public var artifactNames: [String] {
        _artifacts.withLock { Array($0.keys).sorted() }
    }

    // MARK: - Convenience

    public func remember(artifact name: String, key: String, value: String) {
        artifact(named: name).remember(key: key, value: value)
    }

    /// Recall from a specific artifact, or search all artifacts for the best match
    public func recall(query: String, artifact name: String? = nil,
                       sessionId: String? = nil) -> ShelfRecallResult {
        if let name {
            let result = artifact(named: name).recall(query: query, sessionId: sessionId)
            return ShelfRecallResult(artifactName: name, result: result)
        }

        // Search all artifacts, return the highest-confidence match
        let allArtifacts = _artifacts.withLock { Array($0) }
        var best: ShelfRecallResult?

        for (name, nug) in allArtifacts {
            let result = nug.recall(query: query, sessionId: sessionId)
            if result.found {
                if best == nil || result.confidence > (best?.result.confidence ?? 0) {
                    best = ShelfRecallResult(artifactName: name, result: result)
                }
            }
        }

        return best ?? ShelfRecallResult(
            artifactName: "",
            result: RecallResult()
        )
    }

    @discardableResult
    public func forget(artifact name: String, key: String) -> Bool {
        artifact(named: name).forget(key: key)
    }

    // MARK: - Status

    public func status() -> [ArtifactStatus] {
        let all = _artifacts.withLock { Array($0) }
        return all.map { name, nug in
            let facts = nug.facts
            return ArtifactStatus(
                name: name,
                factCount: facts.count,
                promotableCount: facts.filter { $0.hits >= 3 }.count,
                topFacts: Array(facts.sorted { $0.hits > $1.hits }.prefix(5))
            )
        }.sorted { $0.name < $1.name }
    }

    // MARK: - Promotion

    /// Collect all facts recalled 3+ times across all artifacts.
    /// These should be injected directly into the system prompt as permanent context.
    public func promotedFacts() -> [(artifact: String, fact: Fact)] {
        let all = _artifacts.withLock { Array($0) }
        var promoted: [(artifact: String, fact: Fact)] = []
        for (name, nug) in all {
            for fact in nug.promotableFacts {
                promoted.append((artifact: name, fact: fact))
            }
        }
        return promoted.sorted { $0.fact.hits > $1.fact.hits }
    }

    // MARK: - Persistence (SwiftData-backed)

    /// Load all facts from EngramStore into in-memory artifacts.
    public func loadAll() {
        if let store = _store.withLock({ $0 }) {
            // Load from SwiftData store
            Task {
                let allFacts = await store.loadAllFacts()
                for (artifactName, facts) in allFacts {
                    let nug = self.artifact(named: artifactName)
                    for fact in facts {
                        nug._loadFact(key: fact.key, value: fact.value, hits: fact.hits, lastHitSession: fact.session)
                    }
                }
            }
        } else {
            // Fallback: load from JSON files (legacy)
            loadFromFiles()
        }
    }

    /// Save all facts to EngramStore.
    public func saveAll() {
        if let store = _store.withLock({ $0 }) {
            let all = _artifacts.withLock { Array($0) }
            Task {
                for (name, nug) in all {
                    for fact in nug.facts {
                        await store.saveFact(artifact: name, key: fact.key, value: fact.value,
                                             hits: fact.hits, session: fact.lastHitSession)
                    }
                }
            }
        } else {
            saveToFiles()
        }
    }

    // MARK: - Legacy File Persistence

    private func loadFromFiles() {
        let fm = FileManager.default
        try? fm.createDirectory(at: saveDir, withIntermediateDirectories: true)

        guard let contents = try? fm.contentsOfDirectory(
            at: saveDir, includingPropertiesForKeys: nil
        ) else { return }

        for file in contents where file.pathExtension == "json" &&
            file.lastPathComponent.hasSuffix(".artifact.json") {
            do {
                let artifact = try Artifact.load(from: file)
                _artifacts.withLock { $0[artifact.name] = artifact }
            } catch {
                // Skip corrupt files
            }
        }
    }

    private func saveToFiles() {
        let fm = FileManager.default
        try? fm.createDirectory(at: saveDir, withIntermediateDirectories: true)

        let all = _artifacts.withLock { Array($0) }
        for (name, nug) in all {
            let file = saveDir.appendingPathComponent("\(name).artifact.json")
            try? nug.save(to: file)
        }
    }
}

// MARK: - Types

public struct ShelfRecallResult: Sendable {
    public let artifactName: String
    public let result: RecallResult
}

public struct ArtifactStatus: Sendable {
    public let name: String
    public let factCount: Int
    public let promotableCount: Int
    public let topFacts: [Fact]
}
