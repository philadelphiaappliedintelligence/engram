import Foundation

/// Search across all past conversation sessions using SearchKit.
public struct SessionSearchTool: Tool {
    private let searchIndex: SessionSearchIndex?

    public init(searchIndex: SessionSearchIndex? = nil) {
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

        guard let searchIndex else {
            return "Session search not available."
        }

        let limit = Int(input["limit"]?.numberValue ?? 10)
        let results = searchIndex.search(query: query, limit: limit)

        if results.isEmpty { return "No past conversations matching '\(query)'." }

        return results.map { r in
            "[\(r.id)] score: \(String(format: "%.3f", r.score))"
        }.joined(separator: "\n")
    }
}
