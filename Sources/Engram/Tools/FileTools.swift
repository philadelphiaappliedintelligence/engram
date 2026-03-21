import Foundation

// MARK: - File Read Tool

public struct FileReadTool: Tool {
    public init() {}

    public var name: String { "file_read" }
    public var description: String {
        "Read the contents of a file. Returns numbered lines (like cat -n) for easy reference with the edit tool."
    }
    public var inputSchema: [String: JSONValue] {
        Schema.object(properties: [
            "path": Schema.string(description: "Absolute path to the file"),
            "offset": Schema.number(description: "Start reading from this line number (1-based, default: 1)"),
            "limit": Schema.number(description: "Maximum lines to read (default: 2000)"),
        ], required: ["path"])
    }

    public func execute(input: [String: JSONValue]) async throws -> String {
        guard let path = input["path"]?.stringValue else {
            return "{\"error\": \"Missing required parameter: path\"}"
        }

        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)

        guard FileManager.default.fileExists(atPath: url.path) else {
            return "{\"error\": \"File not found: \(path)\"}"
        }

        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let allLines = content.components(separatedBy: "\n")
            let totalLines = allLines.count

            let offset = max(1, Int(input["offset"]?.numberValue ?? 1))
            let limit = Int(input["limit"]?.numberValue ?? 2000)

            let startIdx = min(offset - 1, totalLines)
            let endIdx = min(startIdx + limit, totalLines)
            let slice = allLines[startIdx..<endIdx]

            // Format with line numbers (cat -n style)
            let width = String(endIdx).count
            var numbered: [String] = []
            for (i, line) in slice.enumerated() {
                let lineNum = startIdx + i + 1
                let padded = String(repeating: " ", count: width - String(lineNum).count) + "\(lineNum)"
                numbered.append("\(padded)\t\(line)")
            }

            var result = numbered.joined(separator: "\n")

            if endIdx < totalLines {
                result += "\n... (\(totalLines - endIdx) more lines, \(totalLines) total)"
            }

            // Truncate if very large
            if result.count > 16000 {
                result = String(result.prefix(OutputLimit.file)) + "\n... (truncated)"
            }

            return result
        } catch {
            return "{\"error\": \"Failed to read: \(error.localizedDescription)\"}"
        }
    }
}

// MARK: - File Write Tool

public struct FileWriteTool: Tool {
    public init() {}

    public var name: String { "file_write" }
    public var description: String {
        "Write content to a file. Creates parent directories if needed."
    }
    public var inputSchema: [String: JSONValue] {
        Schema.object(properties: [
            "path": Schema.string(description: "Absolute path to write to"),
            "content": Schema.string(description: "Content to write"),
            "append": Schema.boolean(description: "Append instead of overwrite (default: false)"),
        ], required: ["path", "content"])
    }

    public func execute(input: [String: JSONValue]) async throws -> String {
        guard let path = input["path"]?.stringValue,
              let content = input["content"]?.stringValue else {
            return "{\"error\": \"Missing required parameters: path, content\"}"
        }

        let append = input["append"]?.boolValue ?? false
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)

        // Create parent directory
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        do {
            if append, FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                handle.seekToEndOfFile()
                if let data = content.data(using: .utf8) {
                    handle.write(data)
                }
                handle.closeFile()
            } else {
                try content.write(to: url, atomically: true, encoding: .utf8)
            }
            return "{\"written\": true, \"path\": \"\(url.path)\", \"bytes\": \(content.utf8.count)}"
        } catch {
            return "{\"error\": \"Failed to write: \(error.localizedDescription)\"}"
        }
    }
}

// MARK: - File Search Tool

public struct FileSearchTool: Tool {
    public init() {}

    public var name: String { "file_search" }
    public var description: String {
        "Search for files by name pattern or search file contents with grep."
    }
    public var inputSchema: [String: JSONValue] {
        Schema.object(properties: [
            "path": Schema.string(description: "Directory to search in"),
            "pattern": Schema.string(description: "Filename glob pattern (e.g. '*.swift') or grep text pattern"),
            "mode": Schema.stringEnum(description: "Search mode", values: ["glob", "grep"]),
        ], required: ["path", "pattern"])
    }

    public func execute(input: [String: JSONValue]) async throws -> String {
        guard let path = input["path"]?.stringValue,
              let pattern = input["pattern"]?.stringValue else {
            return "{\"error\": \"Missing required parameters: path, pattern\"}"
        }

        let mode = input["mode"]?.stringValue ?? "glob"
        let expandedPath = (path as NSString).expandingTildeInPath

        let command: String
        if mode == "grep" {
            command = "grep -rn --include='*' -l \(shellEscape(pattern)) \(shellEscape(expandedPath)) 2>/dev/null | head -50"
        } else {
            command = "find \(shellEscape(expandedPath)) -name \(shellEscape(pattern)) -type f 2>/dev/null | head -50"
        }

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

        return output.isEmpty ? "(no matches)" : output
    }

}
