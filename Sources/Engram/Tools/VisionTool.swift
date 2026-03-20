import Foundation

/// Analyze an image using the LLM's vision capabilities.
public struct VisionTool: Tool {
    private let client: LLMClient

    public init(client: LLMClient) {
        self.client = client
    }

    public var name: String { "vision" }
    public var description: String {
        "Analyze an image file. Describe contents, read text/code, extract data, or answer questions about it."
    }
    public var inputSchema: [String: JSONValue] {
        Schema.object(properties: [
            "path": Schema.string(description: "Path to the image file (png, jpg, gif, webp)"),
            "question": Schema.string(description: "What to analyze or look for (default: describe the image)"),
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

        let ext = url.pathExtension.lowercased()
        let mediaType: String
        switch ext {
        case "png": mediaType = "image/png"
        case "jpg", "jpeg": mediaType = "image/jpeg"
        case "gif": mediaType = "image/gif"
        case "webp": mediaType = "image/webp"
        default: return "{\"error\": \"Unsupported format: \(ext). Use png, jpg, gif, or webp.\"}"
        }

        guard let data = try? Data(contentsOf: url), data.count < 20_000_000 else {
            return "{\"error\": \"Failed to read or image too large (max 20MB)\"}"
        }

        let base64 = data.base64EncodedString()
        let question = input["question"]?.stringValue ?? "Describe this image in detail."

        let result = try await client.analyzeImage(
            base64: base64, mediaType: mediaType, prompt: question
        )
        return result
    }
}
