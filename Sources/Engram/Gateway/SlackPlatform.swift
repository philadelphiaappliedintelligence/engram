import Foundation

/// Slack gateway using Socket Mode (WebSocket) + Web API. Pure URLSession.
/// Requires a Slack app with Socket Mode enabled and an app-level token (xapp-).
public actor SlackPlatform: Platform {
    public nonisolated var name: String { "slack" }
    private let appToken: String       // xapp-... (Socket Mode)
    private let botToken: String       // xoxb-... (Bot)
    private let allowedChannelIds: Set<String>
    private var _connected = false
    public nonisolated var isConnected: Bool { true }
    private var pendingMessages: [(chatId: String, sender: String, text: String)] = []
    private var webSocketTask: URLSessionWebSocketTask?

    public init(appToken: String, botToken: String, allowedChannelIds: [String] = []) {
        self.appToken = appToken
        self.botToken = botToken
        self.allowedChannelIds = Set(allowedChannelIds)
    }

    public func start() async throws {
        // Get WebSocket URL via apps.connections.open
        let url = URL(string: "https://slack.com/api/apps.connections.open")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(appToken)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ok = json["ok"] as? Bool, ok,
              let wsURL = json["url"] as? String,
              let socketURL = URL(string: wsURL) else {
            throw GatewayError.connectionFailed("Slack Socket Mode connection failed")
        }

        let ws = URLSession.shared.webSocketTask(with: socketURL)
        ws.resume()
        webSocketTask = ws
        _connected = true

        Task { await receiveLoop(ws: ws) }
    }

    public func stop() async {
        _connected = false
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    public func sendMessage(_ text: String, to chatId: String) async throws {
        let url = URL(string: "https://slack.com/api/chat.postMessage")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(botToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["channel": chatId, "text": text]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["ok"] as? Bool != true {
            throw GatewayError.sendFailed("Slack: \(json["error"] as? String ?? "unknown")")
        }
    }

    public func poll() async throws -> [(chatId: String, sender: String, text: String)] {
        let msgs = pendingMessages
        pendingMessages = []
        return msgs
    }

    private func receiveLoop(ws: URLSessionWebSocketTask) async {
        while _connected {
            guard let msg = try? await ws.receive() else { break }
            if case .string(let text) = msg,
               let data = text.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

                // Acknowledge envelope
                if let envelopeId = json["envelope_id"] as? String {
                    let ack = ["envelope_id": envelopeId]
                    if let ackData = try? JSONSerialization.data(withJSONObject: ack),
                       let ackStr = String(data: ackData, encoding: .utf8) {
                        try? await ws.send(.string(ackStr))
                    }
                }

                // Extract message event
                if let payload = json["payload"] as? [String: Any],
                   let event = payload["event"] as? [String: Any],
                   let type = event["type"] as? String, type == "message",
                   event["subtype"] == nil,  // ignore edits, joins, etc.
                   let text = event["text"] as? String, !text.isEmpty,
                   let channel = event["channel"] as? String,
                   let user = event["user"] as? String {

                    if !allowedChannelIds.isEmpty && !allowedChannelIds.contains(channel) {
                        continue
                    }

                    pendingMessages.append((chatId: channel, sender: user, text: text))
                }
            }
        }
    }
}
