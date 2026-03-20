import Foundation

/// Surgical file edit: match exact old text, replace with new text.
/// This is the most important tool for a coding agent — it enables
/// targeted changes without rewriting entire files.
public struct EditTool: Tool {
    public init() {}

    public var name: String { "edit" }
    public var description: String {
        """
        Make a surgical edit to a file by replacing exact text. \
        The old_text must match exactly (including whitespace and indentation). \
        Only the first occurrence is replaced unless replace_all is true. \
        Always read the file first to get the exact text to match.
        """
    }
    public var inputSchema: [String: JSONValue] {
        Schema.object(properties: [
            "path": Schema.string(description: "Absolute path to the file"),
            "old_text": Schema.string(description: "Exact text to find (must match precisely, including whitespace)"),
            "new_text": Schema.string(description: "Text to replace it with"),
            "replace_all": Schema.boolean(description: "Replace all occurrences (default: false)"),
        ], required: ["path", "old_text", "new_text"])
    }

    public func execute(input: [String: JSONValue]) async throws -> String {
        guard let path = input["path"]?.stringValue,
              let oldText = input["old_text"]?.stringValue,
              let newText = input["new_text"]?.stringValue else {
            return "{\"error\": \"Missing required parameters: path, old_text, new_text\"}"
        }

        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)

        guard FileManager.default.fileExists(atPath: url.path) else {
            return "{\"error\": \"File not found: \(path)\"}"
        }

        do {
            let content = try String(contentsOf: url, encoding: .utf8)

            guard content.contains(oldText) else {
                // Help the LLM understand what went wrong
                let lines = content.components(separatedBy: "\n")
                let lineCount = lines.count

                // Try to find a close match for debugging
                let oldLines = oldText.components(separatedBy: "\n")
                if let firstLine = oldLines.first {
                    let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        let matches = lines.enumerated().filter {
                            $0.element.contains(trimmed)
                        }.prefix(3)
                        if !matches.isEmpty {
                            let hints = matches.map { "  line \($0.offset + 1): \($0.element)" }
                                .joined(separator: "\n")
                            return """
                            {"error": "old_text not found. File has \(lineCount) lines. Similar lines:\n\(hints)\nCheck whitespace and indentation."}
                            """
                        }
                    }
                }

                return "{\"error\": \"old_text not found in file. Read the file first to get exact text. File has \(lineCount) lines.\"}"
            }

            let replaceAll = input["replace_all"]?.boolValue ?? false
            let updated: String
            if replaceAll {
                updated = content.replacingOccurrences(of: oldText, with: newText)
            } else {
                // Replace first occurrence only
                if let range = content.range(of: oldText) {
                    updated = content.replacingCharacters(in: range, with: newText)
                } else {
                    updated = content
                }
            }

            try updated.write(to: url, atomically: true, encoding: .utf8)

            let oldLines = oldText.components(separatedBy: "\n").count
            let newLines = newText.components(separatedBy: "\n").count
            return "{\"edited\": true, \"path\": \"\(url.path)\", \"lines_removed\": \(oldLines), \"lines_added\": \(newLines)}"
        } catch {
            return "{\"error\": \"Failed: \(error.localizedDescription)\"}"
        }
    }
}
