import Foundation

/// Search across all past conversation sessions using FTS5 (legacy fallback).
public struct SessionSearchTool: Tool {
    private let search: SessionSearch
    private let sessionDir: URL

    public init(sessionDir: URL) {
        self.sessionDir = sessionDir
        self.search = SessionSearch(sessionDir: sessionDir)
        search.indexSessions(in: sessionDir)
    }

    public var name: String { "session_search" }
    public var description: String {
        "Search across all past conversations. Use to recall what was discussed in previous sessions."
    }
    public var inputSchema: [String: JSONValue] {
        Schema.object(properties: [
            "query": Schema.string(description: "What to search for in past conversations"),
            "limit": Schema.number(description: "Max results (default: 10)"),
        ], required: ["query"])
    }

    public func execute(input: [String: JSONValue]) async throws -> String {
        guard let query = input["query"]?.stringValue else {
            return "{\"error\": \"Missing query\"}"
        }

        // Re-index before searching
        search.indexSessions(in: sessionDir)

        let limit = Int(input["limit"]?.numberValue ?? 10)
        let results = search.search(query: query, limit: limit)

        if results.isEmpty { return "No past conversations matching '\(query)'." }

        return results.map { r in
            "[\(r.timestamp)] [\(r.role)] \(r.highlighted)"
        }.joined(separator: "\n\n")
    }
}

// MARK: - SearchKit-based Session Search Tool

/// Search across all past conversation sessions using SearchKit.
public struct SearchKitSessionSearchTool: Tool {
    private let searchIndex: SessionSearchIndex

    public init(searchIndex: SessionSearchIndex) {
        self.searchIndex = searchIndex
    }

    public var name: String { "session_search" }
    public var description: String {
        "Search across all past conversations. Use to recall what was discussed in previous sessions."
    }
    public var inputSchema: [String: JSONValue] {
        Schema.object(properties: [
            "query": Schema.string(description: "What to search for in past conversations"),
            "limit": Schema.number(description: "Max results (default: 10)"),
        ], required: ["query"])
    }

    public func execute(input: [String: JSONValue]) async throws -> String {
        guard let query = input["query"]?.stringValue else {
            return "{\"error\": \"Missing query\"}"
        }

        let limit = Int(input["limit"]?.numberValue ?? 10)
        let results = searchIndex.search(query: query, limit: limit)

        if results.isEmpty { return "No past conversations matching '\(query)'." }

        return results.map { r in
            "[\(r.id)] score: \(String(format: "%.3f", r.score))"
        }.joined(separator: "\n")
    }
}
