import Foundation

/// Home Assistant gateway via webhook + REST API.
/// Receives events via webhook, sends notifications via HA REST API.
public actor HomeAssistantPlatform: Platform {
    public nonisolated var name: String { "homeassistant" }
    public nonisolated var isConnected: Bool { true }

    private let baseURL: String       // e.g. http://homeassistant.local:8123
    private let token: String         // Long-lived access token
    private var pendingMessages: [(chatId: String, sender: String, text: String)] = []

    public init(baseURL: String, token: String) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.token = token
    }

    public func start() async throws {
        // Verify connection
        let url = URL(string: "\(baseURL)/api/")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw GatewayError.connectionFailed("Home Assistant auth failed")
        }
    }

    public func stop() async {}

    public func sendMessage(_ text: String, to chatId: String) async throws {
        // Send as persistent notification
        let url = URL(string: "\(baseURL)/api/services/notify/persistent_notification")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "message": text, "title": "Engram"
        ])
        _ = try await URLSession.shared.data(for: request)
    }

    public func poll() async throws -> [(chatId: String, sender: String, text: String)] {
        let msgs = pendingMessages
        pendingMessages = []
        return msgs
    }

    /// Call a Home Assistant service (lights, switches, etc.)
    public func callService(domain: String, service: String, entityId: String) async throws -> String {
        let url = URL(string: "\(baseURL)/api/services/\(domain)/\(service)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "entity_id": entityId
        ])
        let (data, _) = try await URLSession.shared.data(for: request)
        return String(data: data, encoding: .utf8) ?? "ok"
    }

    /// Get state of an entity
    public func getState(entityId: String) async throws -> String {
        let url = URL(string: "\(baseURL)/api/states/\(entityId)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        return String(data: data, encoding: .utf8) ?? ""
    }
}
