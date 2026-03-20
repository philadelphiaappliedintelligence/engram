import Foundation

/// Telegram Bot API gateway. Pure URLSession, no dependencies.
/// Create a bot via @BotFather, get the token, set in config.
public actor TelegramPlatform: Platform {
    public nonisolated var name: String { "telegram" }
    private let token: String
    private let allowedChatIds: Set<String>
    private var lastUpdateId: Int = 0
    private var _connected = false
    public nonisolated var isConnected: Bool { true }

    private var baseURL: String { "https://api.telegram.org/bot\(token)" }

    public init(token: String, allowedChatIds: [String] = []) {
        self.token = token
        self.allowedChatIds = Set(allowedChatIds)
    }

    public func start() async throws {
        // Verify bot token
        let url = URL(string: "\(baseURL)/getMe")!
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GatewayError.connectionFailed("Telegram auth failed: \(body)")
        }
        _connected = true
    }

    public func stop() async {
        _connected = false
    }

    // MARK: - Send

    public func sendMessage(_ text: String, to chatId: String) async throws {
        let url = URL(string: "\(baseURL)/sendMessage")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Split long messages (Telegram limit: 4096 chars)
        let chunks = stride(from: 0, to: text.count, by: 4000).map { start -> String in
            let startIdx = text.index(text.startIndex, offsetBy: start)
            let endIdx = text.index(startIdx, offsetBy: min(4000, text.count - start))
            return String(text[startIdx..<endIdx])
        }

        for chunk in chunks {
            let body: [String: Any] = [
                "chat_id": chatId,
                "text": chunk,
                "parse_mode": "Markdown",
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, resp) = try await URLSession.shared.data(for: request)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                throw GatewayError.sendFailed("Telegram sendMessage failed")
            }
        }
    }

    // MARK: - File Sending

    public func sendFile(path: String, caption: String?, to chatId: String) async throws {
        let fileURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw GatewayError.sendFailed("File not found: \(path)")
        }
        guard let fileData = try? Data(contentsOf: fileURL) else {
            throw GatewayError.sendFailed("Cannot read file: \(path)")
        }

        // Detect if audio
        let ext = fileURL.pathExtension.lowercased()
        let isAudio = ["mp3", "m4a", "ogg", "wav", "flac", "aac", "opus"].contains(ext)
        let endpoint = isAudio ? "sendAudio" : "sendDocument"

        let url = URL(string: "\(baseURL)/\(endpoint)")!
        let boundary = UUID().uuidString

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        let fileName = fileURL.lastPathComponent

        // chat_id field
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"chat_id\"\r\n\r\n\(chatId)\r\n".data(using: .utf8)!)

        // caption field
        if let caption, !caption.isEmpty {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"caption\"\r\n\r\n\(caption)\r\n".data(using: .utf8)!)
        }

        // file field
        let fieldName = isAudio ? "audio" : "document"
        let mimeType = isAudio ? "audio/mpeg" : "application/octet-stream"
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(fileName)\"\r\nContent-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (_, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw GatewayError.sendFailed("Telegram \(endpoint) failed")
        }
    }

    // MARK: - Typing Indicator

    public func sendTyping(to chatId: String) async throws {
        let url = URL(string: "\(baseURL)/sendChatAction")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "chat_id": chatId, "action": "typing"
        ])
        _ = try await URLSession.shared.data(for: request)
    }

    // MARK: - Poll (Long Polling)

    public func poll() async throws -> [(chatId: String, sender: String, text: String)] {
        var components = URLComponents(string: "\(baseURL)/getUpdates")!
        components.queryItems = [
            URLQueryItem(name: "offset", value: "\(lastUpdateId + 1)"),
            URLQueryItem(name: "timeout", value: "5"),
            URLQueryItem(name: "allowed_updates", value: "[\"message\"]"),
        ]

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return []
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = json["ok"] as? Bool, ok,
              let results = json["result"] as? [[String: Any]] else {
            return []
        }

        var messages: [(chatId: String, sender: String, text: String)] = []

        for update in results {
            guard let updateId = update["update_id"] as? Int else { continue }
            lastUpdateId = max(lastUpdateId, updateId)

            guard let message = update["message"] as? [String: Any],
                  let text = message["text"] as? String,
                  let chat = message["chat"] as? [String: Any],
                  let chatId = chat["id"] as? Int else { continue }

            let chatIdStr = "\(chatId)"

            // Filter by allowed chat IDs if configured
            if !allowedChatIds.isEmpty && !allowedChatIds.contains(chatIdStr) {
                continue
            }

            let from = message["from"] as? [String: Any]
            let firstName = from?["first_name"] as? String ?? "Unknown"
            let lastName = from?["last_name"] as? String ?? ""
            let sender = "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)

            messages.append((chatId: chatIdStr, sender: sender, text: text))
        }

        return messages
    }
}
