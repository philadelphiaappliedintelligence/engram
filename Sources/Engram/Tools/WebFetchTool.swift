import Foundation

/// Fetch content from a URL and return it as text.
/// Strips HTML tags for basic readability extraction.
public struct WebFetchTool: Tool {
    public init() {}

    public var name: String { "web_fetch" }
    public var description: String {
        """
        Fetch content from a URL. Returns the page content as plain text. \
        HTML is stripped to extract readable text. Use for documentation, \
        APIs, or any web content the agent needs to read.
        """
    }
    public var inputSchema: [String: JSONValue] {
        Schema.object(properties: [
            "url": Schema.string(description: "The URL to fetch"),
            "max_length": Schema.number(description: "Maximum characters to return (default: 12000)"),
            "raw": Schema.boolean(description: "Return raw content without HTML stripping (default: false)"),
        ], required: ["url"])
    }

    public func execute(input: [String: JSONValue]) async throws -> String {
        guard let urlStr = input["url"]?.stringValue else {
            return "{\"error\": \"Missing required parameter: url\"}"
        }

        guard let url = URL(string: urlStr) else {
            return "{\"error\": \"Invalid URL: \(urlStr)\"}"
        }

        let maxLength = Int(input["max_length"]?.numberValue ?? 12000)
        let raw = input["raw"]?.boolValue ?? false

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Engram/1.0",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/json,text/plain",
                         forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            return "{\"error\": \"Fetch failed: \(error.localizedDescription)\"}"
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            return "{\"error\": \"Invalid response\"}"
        }

        guard httpResponse.statusCode == 200 else {
            return "{\"error\": \"HTTP \(httpResponse.statusCode)\"}"
        }

        guard var content = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .ascii) else {
            return "{\"error\": \"Could not decode response\"}"
        }

        // Strip HTML if not raw mode
        if !raw {
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
            if contentType.contains("html") || content.contains("<html") || content.contains("<!DOCTYPE") {
                content = stripHTML(content)
            }
        }

        // Truncate
        if content.count > maxLength {
            content = String(content.prefix(maxLength)) + "\n... (truncated, \(content.count) chars total)"
        }

        return content.isEmpty ? "(empty response)" : content
    }

    /// Basic HTML → plain text extraction.
    /// Removes tags, decodes common entities, collapses whitespace.
    private func stripHTML(_ html: String) -> String {
        var text = html

        // Remove script and style blocks entirely
        let blockPatterns = [
            "<script[^>]*>[\\s\\S]*?</script>",
            "<style[^>]*>[\\s\\S]*?</style>",
            "<nav[^>]*>[\\s\\S]*?</nav>",
            "<footer[^>]*>[\\s\\S]*?</footer>",
            "<!--[\\s\\S]*?-->",
        ]
        for pattern in blockPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                text = regex.stringByReplacingMatches(
                    in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
            }
        }

        // Add newlines for block elements
        let blockTags = ["</p>", "</div>", "</h1>", "</h2>", "</h3>", "</h4>",
                         "</h5>", "</h6>", "</li>", "</tr>", "<br>", "<br/>", "<br />"]
        for tag in blockTags {
            text = text.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }

        // Remove all remaining tags
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>") {
            text = regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }

        // Decode common HTML entities
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&nbsp;", " "), ("&mdash;", "—"), ("&ndash;", "–"),
            ("&hellip;", "..."), ("&rsquo;", "'"), ("&lsquo;", "'"),
            ("&rdquo;", "\""), ("&ldquo;", "\""),
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }

        // Decode numeric entities
        if let regex = try? NSRegularExpression(pattern: "&#(\\d+);") {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches.reversed() {
                if let range = Range(match.range(at: 1), in: text),
                   let code = Int(text[range]),
                   let scalar = Unicode.Scalar(code) {
                    let charRange = Range(match.range, in: text)!
                    text.replaceSubrange(charRange, with: String(Character(scalar)))
                }
            }
        }

        // Collapse whitespace
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return lines.joined(separator: "\n")
    }
}
