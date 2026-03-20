import Foundation

/// Tracks token usage and triggers compaction when approaching context limits.
/// Prevents the agent from hitting the wall and failing silently.
public actor ContextManager {
    private let maxContextTokens: Int
    private let compactionThreshold: Double  // 0.0–1.0
    private var estimatedTokens: Int = 0

    /// Callback to perform compaction. Takes conversation text, returns summary.
    public typealias Compactor = @Sendable (String) async throws -> String

    public init(maxContextTokens: Int = 200_000, compactionThreshold: Double = 0.5) {
        self.maxContextTokens = maxContextTokens
        self.compactionThreshold = compactionThreshold
    }

    /// Update token count from API response.
    public func updateUsage(inputTokens: Int, outputTokens: Int) {
        estimatedTokens = inputTokens + outputTokens
    }

    /// Check if compaction should be triggered.
    public var shouldCompact: Bool {
        Double(estimatedTokens) / Double(maxContextTokens) >= compactionThreshold
    }

    /// Current context usage as a fraction.
    public var usageFraction: Double {
        Double(estimatedTokens) / Double(maxContextTokens)
    }

    public var currentTokens: Int { estimatedTokens }
    public var maxTokens: Int { maxContextTokens }

    /// Rough token estimate from message text (4 chars ≈ 1 token).
    public static func estimateTokens(for messages: [Message]) -> Int {
        var total = 0
        for msg in messages {
            for block in msg.content {
                switch block {
                case .text(let t):
                    total += t.count / 4
                case .toolUse(let tu):
                    total += tu.name.count / 4 + 50  // overhead for tool call structure
                    // Estimate input JSON size
                    for (_, v) in tu.input {
                        total += estimateJSONValueTokens(v)
                    }
                case .toolResult(let tr):
                    total += tr.content.count / 4
                }
            }
        }
        return total
    }

    /// Compact a message history by summarizing the middle.
    /// Returns compacted messages if compaction was needed, nil otherwise.
    public func compactIfNeeded(
        messages: [Message],
        keepFirst: Int = 2,
        keepLast: Int = 4,
        compactor: Compactor
    ) async throws -> [Message]? {
        guard shouldCompact else { return nil }
        guard messages.count > keepFirst + keepLast + 2 else { return nil }

        let middleStart = keepFirst
        let middleEnd = messages.count - keepLast
        let middle = Array(messages[middleStart..<middleEnd])

        // Build summary text
        let text = middle.map { msg in
            let role = msg.role.rawValue
            let content = msg.textContent
            return "[\(role)] \(String(content.prefix(500)))"
        }.joined(separator: "\n")

        let summary = try await compactor(text)

        // Reassemble
        var compacted = Array(messages[0..<middleStart])
        compacted.append(Message(role: .user, text: "[Prior conversation summary: \(summary)]"))
        compacted.append(contentsOf: messages[middleEnd...])

        // Update estimate
        estimatedTokens = Self.estimateTokens(for: compacted)

        return compacted
    }

    private static func estimateJSONValueTokens(_ value: JSONValue) -> Int {
        switch value {
        case .string(let s): return s.count / 4
        case .number: return 2
        case .bool: return 1
        case .null: return 1
        case .array(let a): return a.reduce(0) { $0 + estimateJSONValueTokens($1) }
        case .object(let o): return o.reduce(0) { $0 + $1.key.count / 4 + estimateJSONValueTokens($1.value) }
        }
    }
}
