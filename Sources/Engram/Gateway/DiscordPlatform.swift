import Foundation

/// Discord gateway using WebSocket + REST API. Pure URLSession, no dependencies.
public actor DiscordPlatform: Platform {
    public nonisolated var name: String { "discord" }
    private let token: String
    private let allowedChannelIds: Set<String>
    private var _connected = false
    public nonisolated var isConnected: Bool { true }
    private var pendingMessages: [(chatId: String, sender: String, text: String)] = []
    private var webSocketTask: URLSessionWebSocketTask?
    private var heartbeatTask: Task<Void, Never>?
    private var sessionId: String?
    private var sequence: Int?

    private let restBase = "https://discord.com/api/v10"

    public init(token: String, allowedChannelIds: [String] = []) {
        self.token = token
        self.allowedChannelIds = Set(allowedChannelIds)
    }

    public func start() async throws {
        // Get gateway URL
        let gatewayURL = try await getGatewayURL()
        guard let url = URL(string: "\(gatewayURL)?v=10&encoding=json") else {
            throw GatewayError.connectionFailed("Invalid gateway URL")
        }

        let ws = URLSession.shared.webSocketTask(with: url)
        ws.resume()
        webSocketTask = ws

        // Wait for Hello (opcode 10)
        let helloMsg = try await ws.receive()
        if case .string(let text) = helloMsg,
           let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let d = json["d"] as? [String: Any],
           let interval = d["heartbeat_interval"] as? Double {
            startHeartbeat(ws: ws, interval: interval)
        }

        // Send Identify (opcode 2)
        let identify: [String: Any] = [
            "op": 2,
            "d": [
                "token": token,
                "intents": 512 + 4096, // GUILD_MESSAGES + MESSAGE_CONTENT
                "properties": [
                    "os": "macos", "browser": "engram", "device": "engram"
                ] as [String: Any]
            ] as [String: Any]
        ]
        let identifyData = try JSONSerialization.data(withJSONObject: identify)
        try await ws.send(.string(String(data: identifyData, encoding: .utf8)!))

        _connected = true

        // Start receiving messages in background
        Task { await receiveLoop(ws: ws) }
    }

    public func stop() async {
        _connected = false
        heartbeatTask?.cancel()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    public func sendMessage(_ text: String, to chatId: String) async throws {
        let url = URL(string: "\(restBase)/channels/\(chatId)/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Split long messages (Discord limit: 2000 chars)
        let chunks = stride(from: 0, to: text.count, by: 1900).map { start -> String in
            let s = text.index(text.startIndex, offsetBy: start)
            let e = text.index(s, offsetBy: min(1900, text.count - start))
            return String(text[s..<e])
        }

        for chunk in chunks {
            let body = ["content": chunk]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, resp) = try await URLSession.shared.data(for: request)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                throw GatewayError.sendFailed("Discord send failed")
            }
        }
    }

    public func poll() async throws -> [(chatId: String, sender: String, text: String)] {
        let msgs = pendingMessages
        pendingMessages = []
        return msgs
    }

    // MARK: - Private

    private func getGatewayURL() async throws -> String {
        let url = URL(string: "\(restBase)/gateway/bot")!
        var request = URLRequest(url: url)
        request.setValue("Bot \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gatewayURL = json["url"] as? String else {
            throw GatewayError.connectionFailed("Failed to get Discord gateway URL")
        }
        return gatewayURL
    }

    private func startHeartbeat(ws: URLSessionWebSocketTask, interval: Double) {
        heartbeatTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000))
                let hb: [String: Any] = ["op": 1, "d": sequence as Any]
                if let data = try? JSONSerialization.data(withJSONObject: hb),
                   let str = String(data: data, encoding: .utf8) {
                    try? await ws.send(.string(str))
                }
            }
        }
    }

    private func receiveLoop(ws: URLSessionWebSocketTask) async {
        while _connected {
            guard let msg = try? await ws.receive() else { break }
            if case .string(let text) = msg,
               let data = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

                if let s = json["s"] as? Int { sequence = s }

                let op = json["op"] as? Int ?? -1
                if op == 0, let t = json["t"] as? String, t == "MESSAGE_CREATE",
                   let d = json["d"] as? [String: Any],
                   let content = d["content"] as? String, !content.isEmpty,
                   let author = d["author"] as? [String: Any],
                   let channelId = d["channel_id"] as? String,
                   author["bot"] as? Bool != true {

                    if !allowedChannelIds.isEmpty && !allowedChannelIds.contains(channelId) {
                        continue
                    }

                    let username = author["username"] as? String ?? "unknown"
                    pendingMessages.append((chatId: channelId, sender: username, text: content))
                }
            }
        }
    }
}
