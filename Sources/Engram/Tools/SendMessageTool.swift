import Foundation

/// Send a message or file through the current messaging platform.
public struct SendMessageTool: Tool {
    private let platform: any Platform
    private let chatId: String

    public init(platform: any Platform, chatId: String) {
        self.platform = platform
        self.chatId = chatId
    }

    public var name: String { "send_message" }
    public var description: String {
        """
        Send a message or file to the user through \(platform.name). \
        For files, provide the file_path and the file will be uploaded directly. \
        Audio files (mp3, m4a, ogg, wav, flac) are sent as playable audio.
        """
    }
    public var inputSchema: [String: JSONValue] {
        Schema.object(properties: [
            "text": Schema.string(description: "Text message to send (optional if sending a file)"),
            "file_path": Schema.string(description: "Absolute path to a file to send/upload"),
        ])
    }

    public func execute(input: [String: JSONValue]) async throws -> String {
        let text = input["text"]?.stringValue
        let filePath = input["file_path"]?.stringValue

        if let filePath {
            let expanded = (filePath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else {
                return "{\"error\": \"File not found: \(filePath)\"}"
            }
            do {
                try await platform.sendFile(path: expanded, caption: text, to: chatId)
                let name = URL(fileURLWithPath: expanded).lastPathComponent
                return "{\"sent_file\": \"\(name)\", \"platform\": \"\(platform.name)\"}"
            } catch {
                return "{\"error\": \"File send failed: \(error.localizedDescription)\"}"
            }
        }

        guard let text, !text.isEmpty else {
            return "{\"error\": \"Provide text or file_path\"}"
        }

        do {
            try await platform.sendMessage(text, to: chatId)
            return "{\"sent\": true, \"platform\": \"\(platform.name)\"}"
        } catch {
            return "{\"error\": \"Send failed: \(error.localizedDescription)\"}"
        }
    }
}
