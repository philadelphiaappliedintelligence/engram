import Foundation
import AppKit

/// Read and write the macOS clipboard (NSPasteboard).
/// "Summarize what I just copied" or "Copy this to my clipboard".
public struct ClipboardTool: Tool {
    public init() {}

    public var name: String { "clipboard" }
    public var description: String {
        "Read or write the macOS clipboard. Use 'read' to see what the user copied, 'write' to put text on the clipboard."
    }
    public var inputSchema: [String: JSONValue] {
        Schema.object(properties: [
            "action": Schema.stringEnum(description: "read or write", values: ["read", "write"]),
            "text": Schema.string(description: "Text to write to clipboard (for 'write' action)"),
        ], required: ["action"])
    }

    public func execute(input: [String: JSONValue]) async throws -> String {
        guard let action = input["action"]?.stringValue else {
            return "{\"error\": \"Missing action\"}"
        }

        switch action {
        case "read":
            guard let content = NSPasteboard.general.string(forType: .string) else {
                return "(clipboard is empty or contains non-text data)"
            }
            if content.count > 8000 {
                return String(content.prefix(8000)) + "\n... (truncated, \(content.count) chars)"
            }
            return content

        case "write":
            guard let text = input["text"]?.stringValue else {
                return "{\"error\": \"Missing text for write\"}"
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return "{\"copied\": true, \"chars\": \(text.count)}"

        default:
            return "{\"error\": \"Unknown action: \(action). Use read or write.\"}"
        }
    }
}
