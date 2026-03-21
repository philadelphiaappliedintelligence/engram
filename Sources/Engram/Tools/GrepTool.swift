import Foundation

/// Proper grep tool using ripgrep (rg) or falling back to grep.
/// Supports regex, context lines, file type filtering, and line numbers.
public struct GrepTool: Tool {
    public init() {}

    public var name: String { "grep" }
    public var description: String {
        """
        Search file contents with regex patterns. Returns matching lines with \
        file paths and line numbers. Supports context lines and file type filtering.
        """
    }
    public var inputSchema: [String: JSONValue] {
        Schema.object(properties: [
            "pattern": Schema.string(description: "Regex pattern to search for"),
            "path": Schema.string(description: "Directory or file to search in (default: current directory)"),
            "file_type": Schema.string(description: "File extension filter, e.g. 'swift', 'py', 'js'"),
            "context": Schema.number(description: "Lines of context before and after each match (default: 0)"),
            "max_results": Schema.number(description: "Maximum number of matching lines (default: 50)"),
            "case_insensitive": Schema.boolean(description: "Case insensitive search (default: false)"),
        ], required: ["pattern"])
    }

    public func execute(input: [String: JSONValue]) async throws -> String {
        guard let pattern = input["pattern"]?.stringValue else {
            return "{\"error\": \"Missing required parameter: pattern\"}"
        }

        let path = input["path"]?.stringValue ?? "."
        let expandedPath = (path as NSString).expandingTildeInPath
        let context = Int(input["context"]?.numberValue ?? 0)
        let maxResults = Int(input["max_results"]?.numberValue ?? 50)
        let caseInsensitive = input["case_insensitive"]?.boolValue ?? false

        // Build rg command, fall back to grep
        let useRg = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/rg")
            || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/rg")

        var args: [String] = []

        if useRg {
            args.append("rg")
            args.append("--line-number")
            args.append("--no-heading")
            args.append("--color=never")
            if caseInsensitive { args.append("-i") }
            if context > 0 { args.append("-C"); args.append("\(context)") }
            if let fileType = input["file_type"]?.stringValue {
                args.append("--type"); args.append(fileType)
            }
            args.append("--max-count=\(maxResults)")
            args.append(pattern)
            args.append(expandedPath)
        } else {
            args.append("grep")
            args.append("-rn")
            args.append("--color=never")
            if caseInsensitive { args.append("-i") }
            if context > 0 { args.append("-C"); args.append("\(context)") }
            if let fileType = input["file_type"]?.stringValue {
                args.append("--include=*.\(fileType)")
            }
            args.append(pattern)
            args.append(expandedPath)
        }

        let command = args.map { shellEscape($0) }.joined(separator: " ")
            + " 2>/dev/null | head -\(maxResults * (1 + context * 2))"

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""

        if output.isEmpty {
            return "(no matches for pattern: \(pattern))"
        }

        // Truncate if very long
        if output.count > 12000 {
            return String(output.prefix(OutputLimit.standard)) + "\n... (truncated)"
        }

        return output
    }

}
