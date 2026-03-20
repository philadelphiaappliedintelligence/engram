import Foundation

/// Generate images using OpenAI's DALL-E API or compatible endpoints.
public struct ImageGenTool: Tool {
    public init() {}

    public var name: String { "image_generate" }
    public var description: String {
        "Generate an image from a text description using DALL-E or compatible API. Requires OPENAI_API_KEY."
    }
    public var inputSchema: [String: JSONValue] {
        Schema.object(properties: [
            "prompt": Schema.string(description: "Description of the image to generate"),
            "size": Schema.stringEnum(description: "Image size", values: ["1024x1024", "1792x1024", "1024x1792"]),
            "save_to": Schema.string(description: "Path to save the image (default: ~/Downloads/engram_image.png)"),
        ], required: ["prompt"])
    }

    public func execute(input: [String: JSONValue]) async throws -> String {
        guard let prompt = input["prompt"]?.stringValue else {
            return "{\"error\": \"Missing prompt\"}"
        }

        guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
            return "{\"error\": \"OPENAI_API_KEY not set. Required for image generation.\"}"
        }

        let size = input["size"]?.stringValue ?? "1024x1024"
        let savePath = input["save_to"]?.stringValue ?? "~/Downloads/engram_image_\(UUID().uuidString.prefix(6)).png"
        let saveURL = URL(fileURLWithPath: (savePath as NSString).expandingTildeInPath)

        let url = URL(string: "https://api.openai.com/v1/images/generations")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "model": "dall-e-3",
            "prompt": prompt,
            "n": 1,
            "size": size,
            "response_format": "b64_json",
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let errBody = String(data: data, encoding: .utf8) ?? ""
            return "{\"error\": \"Image generation failed: \(errBody)\"}"
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["data"] as? [[String: Any]],
              let first = results.first,
              let b64 = first["b64_json"] as? String,
              let imageData = Data(base64Encoded: b64) else {
            return "{\"error\": \"Failed to parse image response\"}"
        }

        // Save
        try? FileManager.default.createDirectory(
            at: saveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try imageData.write(to: saveURL)

        let revised = first["revised_prompt"] as? String ?? prompt
        return "Image saved to \(saveURL.path)\nPrompt: \(revised)"
    }
}
