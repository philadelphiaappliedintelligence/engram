import Foundation

// MARK: - Memory Remember Tool

public struct MemoryRememberTool: Tool {
    private let shelf: Shelf

    public init(shelf: Shelf) { self.shelf = shelf }

    public var name: String { "memory_remember" }
    public var description: String {
        "Store a fact in holographic memory. Organize facts into topic-scoped artifacts (e.g. 'preferences', 'project', 'people')."
    }
    public var inputSchema: [String: JSONValue] {
        Schema.object(properties: [
            "artifact": Schema.string(description: "Topic name for this memory (e.g. 'preferences', 'project', 'people')"),
            "key": Schema.string(description: "Short label for this fact (e.g. 'favorite_color', 'deadline')"),
            "value": Schema.string(description: "The fact to remember"),
        ], required: ["artifact", "key", "value"])
    }

    public func execute(input: [String: JSONValue]) async throws -> String {
        guard let artifactName = input["artifact"]?.stringValue,
              let key = input["key"]?.stringValue,
              let value = input["value"]?.stringValue else {
            return "{\"error\": \"Missing required parameters: artifact, key, value\"}"
        }

        shelf.remember(artifact: artifactName, key: key, value: value)
        shelf.saveAll()

        let count = shelf.artifact(named: artifactName).factCount
        return "{\"stored\": true, \"artifact\": \"\(artifactName)\", \"key\": \"\(key)\", \"total_facts\": \(count)}"
    }
}

// MARK: - Memory Recall Tool

public struct MemoryRecallTool: Tool {
    private let shelf: Shelf
    private let sessionId: String

    public init(shelf: Shelf, sessionId: String) {
        self.shelf = shelf
        self.sessionId = sessionId
    }

    public var name: String { "memory_recall" }
    public var description: String {
        "Recall a fact from holographic memory. Can search a specific artifact or all artifacts."
    }
    public var inputSchema: [String: JSONValue] {
        Schema.object(properties: [
            "query": Schema.string(description: "What to recall (key or topic to search for)"),
            "artifact": Schema.string(description: "Optional: specific artifact to search. If omitted, searches all."),
        ], required: ["query"])
    }

    public func execute(input: [String: JSONValue]) async throws -> String {
        guard let query = input["query"]?.stringValue else {
            return "{\"error\": \"Missing required parameter: query\"}"
        }

        let artifactName = input["artifact"]?.stringValue
        let result = shelf.recall(query: query, artifact: artifactName, sessionId: sessionId)

        if result.result.found, let answer = result.result.answer {
            shelf.saveAll()
            return """
            {"found": true, "artifact": "\(result.artifactName)", "key": "\(result.result.key ?? "")", "value": "\(answer)", "confidence": \(String(format: "%.3f", result.result.confidence)), "hits": \(shelf.artifact(named: result.artifactName).facts.first { $0.key == result.result.key }?.hits ?? 0)}
            """
        } else {
            return "{\"found\": false, \"query\": \"\(query)\"}"
        }
    }
}

// MARK: - Memory Forget Tool

public struct MemoryForgetTool: Tool {
    private let shelf: Shelf

    public init(shelf: Shelf) { self.shelf = shelf }

    public var name: String { "memory_forget" }
    public var description: String {
        "Remove a fact from holographic memory."
    }
    public var inputSchema: [String: JSONValue] {
        Schema.object(properties: [
            "artifact": Schema.string(description: "Which artifact to remove the fact from"),
            "key": Schema.string(description: "Key of the fact to forget"),
        ], required: ["artifact", "key"])
    }

    public func execute(input: [String: JSONValue]) async throws -> String {
        guard let artifactName = input["artifact"]?.stringValue,
              let key = input["key"]?.stringValue else {
            return "{\"error\": \"Missing required parameters: artifact, key\"}"
        }

        let removed = shelf.forget(artifact: artifactName, key: key)
        shelf.saveAll()
        return "{\"removed\": \(removed), \"artifact\": \"\(artifactName)\", \"key\": \"\(key)\"}"
    }
}

// MARK: - Memory Status Tool

public struct MemoryStatusTool: Tool {
    private let shelf: Shelf

    public init(shelf: Shelf) { self.shelf = shelf }

    public var name: String { "memory_status" }
    public var description: String {
        "View the current state of holographic memory — all artifacts, fact counts, and promoted facts."
    }
    public var inputSchema: [String: JSONValue] {
        Schema.object(properties: [:])
    }

    public func execute(input: [String: JSONValue]) async throws -> String {
        let statuses = shelf.status()
        let promoted = shelf.promotedFacts()

        var lines: [String] = []
        for s in statuses {
            lines.append("\(s.name): \(s.factCount) facts (\(s.promotableCount) promoted)")
            for fact in s.topFacts {
                lines.append("  - \(fact.key): \(fact.value) [hits: \(fact.hits)]")
            }
        }
        if !promoted.isEmpty {
            lines.append("\nPromoted to permanent context:")
            for p in promoted {
                lines.append("  [\(p.artifact)] \(p.fact.key): \(p.fact.value) (recalled \(p.fact.hits)x)")
            }
        }
        if lines.isEmpty {
            lines.append("Memory is empty. Use memory_remember to store facts.")
        }

        return lines.joined(separator: "\n")
    }
}
