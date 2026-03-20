import Foundation

/// Find files using macOS Spotlight (mdfind).
/// Searches the entire Spotlight index — faster and more comprehensive than find/grep.
public struct SpotlightTool: Tool {
    public init() {}

    public var name: String { "spotlight" }
    public var description: String {
        "Search for files using macOS Spotlight. Finds files by name, content, or metadata across the entire system."
    }
    public var inputSchema: [String: JSONValue] {
        Schema.object(properties: [
            "query": Schema.string(description: "Search query (filename, content, or Spotlight query syntax)"),
            "scope": Schema.string(description: "Directory to search within (default: entire system)"),
            "kind": Schema.string(description: "File kind filter: document, image, audio, video, pdf, code"),
            "limit": Schema.number(description: "Max results (default: 20)"),
        ], required: ["query"])
    }

    public func execute(input: [String: JSONValue]) async throws -> String {
        guard let query = input["query"]?.stringValue else {
            return "{\"error\": \"Missing query\"}"
        }

        let limit = Int(input["limit"]?.numberValue ?? 20)
        let scope = input["scope"]?.stringValue
        let kind = input["kind"]?.stringValue

        var mdQuery = query
        if let kind {
            let kindMap = [
                "document": "kMDItemContentType == 'com.apple.iwork.*' || kMDItemContentType == 'public.text'",
                "image": "kMDItemContentType == 'public.image'",
                "audio": "kMDItemContentType == 'public.audio'",
                "video": "kMDItemContentType == 'public.movie'",
                "pdf": "kMDItemContentType == 'com.adobe.pdf'",
                "code": "kMDItemContentType == 'public.source-code'",
            ]
            if let filter = kindMap[kind] {
                mdQuery = "(\(filter)) && (kMDItemDisplayName == '*\(query)*'wcd || kMDItemTextContent == '*\(query)*'wcd)"
            }
        }

        var args = ["-interpret", mdQuery]
        if let scope {
            args = ["-onlyin", (scope as NSString).expandingTildeInPath] + args
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8), !output.isEmpty else {
            return "No files found for '\(query)'."
        }

        let lines = output.components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .prefix(limit)

        return lines.joined(separator: "\n")
    }
}
