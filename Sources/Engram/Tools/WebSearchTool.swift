import Foundation

/// Web search using DuckDuckGo HTML (no API key needed).
/// Falls back to Brave Search API if configured.
public struct WebSearchTool: Tool {
    public init() {}

    public var name: String { "web_search" }
    public var description: String {
        "Search the web. Returns titles, URLs, and snippets from search results."
    }
    public var inputSchema: [String: JSONValue] {
        Schema.object(properties: [
            "query": Schema.string(description: "Search query"),
            "max_results": Schema.number(description: "Max results (default: 5)"),
        ], required: ["query"])
    }

    public func execute(input: [String: JSONValue]) async throws -> String {
        guard let query = input["query"]?.stringValue else {
            return "{\"error\": \"Missing query\"}"
        }
        let maxResults = Int(input["max_results"]?.numberValue ?? 5)

        // Use DuckDuckGo HTML search (no API key)
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)") else {
            return "{\"error\": \"Invalid query\"}"
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Mozilla/5.0 (Macintosh) Engram/1.0", forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await URLSession.shared.data(for: request),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            return "{\"error\": \"Search request failed\"}"
        }

        // Parse results from DuckDuckGo HTML
        var results: [String] = []
        let resultPattern = try? NSRegularExpression(
            pattern: "<a rel=\"nofollow\" class=\"result__a\" href=\"([^\"]+)\"[^>]*>(.+?)</a>.*?<a class=\"result__snippet\"[^>]*>(.+?)</a>",
            options: .dotMatchesLineSeparators
        )

        if let pattern = resultPattern {
            let matches = pattern.matches(in: html, range: NSRange(html.startIndex..., in: html))
            for match in matches.prefix(maxResults) {
                let urlRange = Range(match.range(at: 1), in: html)!
                let titleRange = Range(match.range(at: 2), in: html)!
                let snippetRange = Range(match.range(at: 3), in: html)!

                let resultURL = String(html[urlRange])
                    .replacingOccurrences(of: "&amp;", with: "&")
                let title = String(html[titleRange])
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                let snippet = String(html[snippetRange])
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&quot;", with: "\"")

                // DuckDuckGo wraps URLs in a redirect, extract the real URL
                var cleanURL = resultURL
                if let uddg = URLComponents(string: resultURL)?.queryItems?
                    .first(where: { $0.name == "uddg" })?.value {
                    cleanURL = uddg
                }

                results.append("\(title)\n\(cleanURL)\n\(snippet)")
            }
        }

        if results.isEmpty { return "No results found for '\(query)'." }
        return results.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n\n")
    }
}
