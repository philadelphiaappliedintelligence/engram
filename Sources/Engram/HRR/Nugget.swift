import Foundation

// MARK: - Fact

public struct Fact: Codable, Sendable {
    public var key: String
    public var value: String
    public var hits: Int
    public var lastHitSession: String?

    public init(key: String, value: String, hits: Int = 0, lastHitSession: String? = nil) {
        self.key = key
        self.value = value
        self.hits = hits
        self.lastHitSession = lastHitSession
    }
}

// MARK: - Recall Result

public struct RecallResult: Sendable {
    public let answer: String?
    public let confidence: Double
    public let found: Bool
    public let key: String?
    public let margin: Double

    public init(answer: String? = nil, confidence: Double = 0, found: Bool = false,
                key: String? = nil, margin: Double = 0) {
        self.answer = answer
        self.confidence = confidence
        self.found = found
        self.key = key
        self.margin = margin
    }
}

// MARK: - Nugget

/// A single topic-scoped holographic memory.
/// Facts are bound as key-value pairs into a superposed complex vector.
/// Recall is algebraic (sub-millisecond, no API calls, no database).
public final class Nugget: Sendable {
    public let name: String
    public let dimension: Int

    private let _facts: LockedValue<[Fact]>
    private let _memory: LockedValue<ComplexVector>
    private let _vectorCache: LockedValue<[String: ComplexVector]>

    public init(name: String, dimension: Int = 512) {
        self.name = name
        self.dimension = dimension
        self._facts = LockedValue([])
        self._memory = LockedValue(ComplexVector(dimension: dimension))
        self._vectorCache = LockedValue([:])
    }

    // MARK: - Vector Generation

    /// Get or create a deterministic vector for a string.
    /// Each unique string always maps to the same vector.
    private func vector(for string: String) -> ComplexVector {
        if let cached = _vectorCache.withLock({ $0[string] }) {
            return cached
        }
        let vec = ComplexVector.random(for: string, dimension: dimension)
        _vectorCache.withLock { $0[string] = vec }
        return vec
    }

    // MARK: - Remember

    /// Store a key-value fact. Overwrites existing fact with same key.
    public func remember(key: String, value: String) {
        forget(key: key)
        let keyVec = vector(for: "key:\(key)")
        let valVec = vector(for: "val:\(value)")
        let binding = keyVec.bind(with: valVec)
        _memory.withLock { $0 = $0.add(binding) }
        _facts.withLock { $0.append(Fact(key: key, value: value)) }
    }

    // MARK: - Recall

    /// Recall a fact by querying with a key (supports fuzzy matching).
    /// Returns the best matching value with confidence score.
    public func recall(query: String, sessionId: String? = nil) -> RecallResult {
        let facts = _facts.withLock { Array($0) }
        guard !facts.isEmpty else {
            return RecallResult()
        }

        // Fuzzy match the query against known keys
        let keys = Array(Set(facts.map(\.key)))
        let (bestKey, matchScore) = fuzzyMatch(query: query, candidates: keys)

        // Unbind with the matched key
        let keyVec = vector(for: "key:\(bestKey)")
        let memory = _memory.withLock { $0 }
        let decoded = memory.unbind(with: keyVec)

        // Compare against all known values
        let values = Array(Set(facts.map(\.value)))
        var similarities: [(String, Double)] = []
        for value in values {
            let valVec = vector(for: "val:\(value)")
            let sim = decoded.cosineSimilarity(with: valVec)
            similarities.append((value, sim))
        }
        similarities.sort { $0.1 > $1.1 }

        let bestValue = similarities[0].0
        let bestSim = similarities[0].1 * matchScore // weight by fuzzy match quality
        let secondSim = similarities.count > 1 ? similarities[1].1 * matchScore : 0
        let margin = bestSim - secondSim

        // Update hit count (deduplicate by session)
        if let sessionId {
            _facts.withLock { facts in
                if let idx = facts.firstIndex(where: { $0.key == bestKey }) {
                    if facts[idx].lastHitSession != sessionId {
                        facts[idx].hits += 1
                        facts[idx].lastHitSession = sessionId
                    }
                }
            }
        }

        return RecallResult(
            answer: bestValue,
            confidence: bestSim,
            found: bestSim > 0.05,
            key: bestKey,
            margin: margin
        )
    }

    // MARK: - Forget

    /// Remove all facts matching the given key. Returns true if any were removed.
    @discardableResult
    public func forget(key: String) -> Bool {
        let lowered = key.lowercased()
        var removed = false
        _facts.withLock { facts in
            let matching = facts.filter { $0.key.lowercased() == lowered }
            guard !matching.isEmpty else { return }
            removed = true
            facts.removeAll { $0.key.lowercased() == lowered }
        }
        if removed { rebuild() }
        return removed
    }

    /// Rebuild the memory vector from all current facts
    private func rebuild() {
        let facts = _facts.withLock { Array($0) }
        var mem = ComplexVector(dimension: dimension)
        for fact in facts {
            let keyVec = vector(for: "key:\(fact.key)")
            let valVec = vector(for: "val:\(fact.value)")
            mem = mem.add(keyVec.bind(with: valVec))
        }
        _memory.withLock { $0 = mem }
    }

    // MARK: - Bulk Load (for store-backed persistence)

    /// Load a fact without triggering HRR rebuild for each one.
    /// Call rebuild() after loading all facts.
    public func _loadFact(key: String, value: String, hits: Int, lastHitSession: String?) {
        _facts.withLock { $0.append(Fact(key: key, value: value, hits: hits, lastHitSession: lastHitSession)) }
        let keyVec = vector(for: "key:\(key)")
        let valVec = vector(for: "val:\(value)")
        let binding = keyVec.bind(with: valVec)
        _memory.withLock { $0 = $0.add(binding) }
    }

    // MARK: - Accessors

    public var facts: [Fact] {
        _facts.withLock { Array($0) }
    }

    public var factCount: Int {
        _facts.withLock { $0.count }
    }

    /// Facts that have been recalled 3+ times (promotion candidates)
    public var promotableFacts: [Fact] {
        _facts.withLock { $0.filter { $0.hits >= 3 } }
    }

    // MARK: - Persistence

    private struct NuggetFile: Codable {
        let name: String
        let dimension: Int
        let facts: [Fact]
    }

    public func save(to url: URL) throws {
        let file = NuggetFile(name: name, dimension: dimension, facts: facts)
        let data = try JSONEncoder().encode(file)
        try data.write(to: url, options: .atomic)
    }

    public static func load(from url: URL) throws -> Nugget {
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(NuggetFile.self, from: data)
        let nugget = Nugget(name: file.name, dimension: file.dimension)
        for fact in file.facts {
            nugget._facts.withLock { $0.append(fact) }
        }
        nugget.rebuild()
        return nugget
    }
}

// MARK: - Fuzzy Match

/// Find the best matching candidate for a query string.
/// Returns (bestCandidate, matchScore) where matchScore is 0.0–1.0.
private func fuzzyMatch(query: String, candidates: [String]) -> (String, Double) {
    guard !candidates.isEmpty else { return (query, 0.0) }

    let q = query.lowercased()
    var bestScore = 0.0
    var bestCandidate = candidates[0]

    for candidate in candidates {
        let c = candidate.lowercased()

        // Exact match
        if c == q { return (candidate, 1.0) }

        var score = 0.0

        // Substring containment
        if c.contains(q) { score += 0.8 }
        else if q.contains(c) { score += 0.6 }

        // Longest common subsequence ratio
        let lcs = longestCommonSubsequence(q, c)
        let maxLen = max(q.count, c.count)
        if maxLen > 0 {
            score += 0.4 * Double(lcs) / Double(maxLen)
        }

        // Normalize to 0–1
        score = min(score / 1.2, 1.0)

        if score > bestScore {
            bestScore = score
            bestCandidate = candidate
        }
    }

    return (bestCandidate, bestScore)
}

private func longestCommonSubsequence(_ a: String, _ b: String) -> Int {
    let a = Array(a)
    let b = Array(b)
    let m = a.count, n = b.count
    guard m > 0, n > 0 else { return 0 }

    var prev = [Int](repeating: 0, count: n + 1)
    var curr = [Int](repeating: 0, count: n + 1)

    for i in 1...m {
        for j in 1...n {
            if a[i - 1] == b[j - 1] {
                curr[j] = prev[j - 1] + 1
            } else {
                curr[j] = max(prev[j], curr[j - 1])
            }
        }
        swap(&prev, &curr)
        curr = [Int](repeating: 0, count: n + 1)
    }
    return prev[n]
}

// MARK: - Thread-Safe Value Wrapper

/// Minimal lock wrapper for Sendable conformance
public final class LockedValue<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()

    public init(_ value: T) {
        self.value = value
    }

    @discardableResult
    public func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
