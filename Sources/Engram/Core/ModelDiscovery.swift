import Foundation

/// Fetches available models dynamically from provider APIs.
/// Falls back to static catalog on failure.
public enum ModelDiscovery {

    /// Fetch models from Anthropic /v1/models
    public static func fetchAnthropic(token: String, isOAuth: Bool) async -> [DiscoveredModel] {
        let url = URL(string: "https://api.anthropic.com/v1/models")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 8

        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if isOAuth {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("claude-code-20250219,oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("true", forHTTPHeaderField: "anthropic-dangerous-direct-browser-access")
            request.setValue("claude-cli/2.1.2 (external, cli)", forHTTPHeaderField: "user-agent")
            request.setValue("cli", forHTTPHeaderField: "x-app")
        } else {
            request.setValue(token, forHTTPHeaderField: "x-api-key")
        }

        guard let (data, resp) = try? await URLSession.shared.data(for: request),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]] else {
            return []
        }

        return models.compactMap { m -> DiscoveredModel? in
            guard let id = m["id"] as? String else { return nil }
            let displayName = m["display_name"] as? String ?? id
            return DiscoveredModel(id: id, name: displayName, provider: "anthropic")
        }.sorted { rank($0.id) < rank($1.id) }
    }

    /// Fetch models from any OpenAI-compatible /v1/models endpoint
    /// Works with: OpenAI, OpenRouter, Ollama, etc.
    public static func fetchOpenAI(baseURL: String, apiKey: String?) async -> [DiscoveredModel] {
        let urlStr = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/models"
        guard let url = URL(string: urlStr) else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        guard let (data, resp) = try? await URLSession.shared.data(for: request),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]] else {
            return []
        }

        return models.compactMap { m -> DiscoveredModel? in
            guard let id = m["id"] as? String, !id.isEmpty else { return nil }
            let name = m["name"] as? String ?? id
            return DiscoveredModel(id: id, name: name, provider: "openai")
        }.sorted { $0.id < $1.id }
    }

    /// Fetch models from Ollama /api/tags (local)
    public static func fetchOllama(baseURL: String = "http://127.0.0.1:11434") async -> [DiscoveredModel] {
        let urlStr = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/tags"
        guard let url = URL(string: urlStr) else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        guard let (data, resp) = try? await URLSession.shared.data(for: request),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            return []
        }

        return models.compactMap { m -> DiscoveredModel? in
            guard let name = m["name"] as? String else { return nil }
            let size = m["size"] as? Int ?? 0
            let sizeStr = size > 0 ? " (\(size / 1_000_000_000)GB)" : ""
            return DiscoveredModel(id: name, name: "\(name)\(sizeStr)", provider: "ollama")
        }
    }

    /// Fetch models from OpenRouter (public, no auth)
    public static func fetchOpenRouter() async -> [DiscoveredModel] {
        guard let url = URL(string: "https://openrouter.ai/api/v1/models") else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, resp) = try? await URLSession.shared.data(for: request),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]] else {
            return []
        }

        return models.compactMap { m -> DiscoveredModel? in
            guard let id = m["id"] as? String else { return nil }
            let name = m["name"] as? String ?? id
            return DiscoveredModel(id: id, name: name, provider: "openrouter")
        }
    }

    /// Fetch models from the Codex-specific endpoint (for ChatGPT Plus/Pro OAuth)
    public static func fetchCodex(token: String) async -> [DiscoveredModel] {
        guard let url = URL(string: "https://chatgpt.com/backend-api/codex/models?client_version=1.0.0") else {
            return []
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        guard let (data, resp) = try? await URLSession.shared.data(for: request),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        // Codex format: {"models": [{"slug": "...", "supported_in_api": true, ...}]}
        let entries = json["models"] as? [[String: Any]] ?? []

        return entries.compactMap { m -> DiscoveredModel? in
            guard let slug = m["slug"] as? String, !slug.isEmpty else { return nil }
            if m["supported_in_api"] as? Bool == false { return nil }
            let visibility = m["visibility"] as? String ?? ""
            if visibility == "hide" || visibility == "hidden" { return nil }
            return DiscoveredModel(id: slug, name: slug, provider: "openai-codex")
        }
    }

    // MARK: - Static Fallback

    /// Static model list when API discovery fails
    public static func staticFallback(for provider: LLMProvider) -> [DiscoveredModel] {
        switch provider {
        case .anthropic:
            return [
                DiscoveredModel(id: "claude-opus-4-6", name: "Claude Opus 4.6", provider: "anthropic"),
                DiscoveredModel(id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6", provider: "anthropic"),
                DiscoveredModel(id: "claude-haiku-4-5-20251001", name: "Claude Haiku 4.5", provider: "anthropic"),
            ]
        case .openai, .codex:
            return [
                DiscoveredModel(id: "gpt-4o", name: "GPT-4o", provider: "openai"),
                DiscoveredModel(id: "gpt-4o-mini", name: "GPT-4o Mini", provider: "openai"),
                DiscoveredModel(id: "o3", name: "o3", provider: "openai"),
            ]
        }
    }

    // MARK: - Sorting

    private static func rank(_ id: String) -> Int {
        if id.contains("opus") && id.contains("4-6") { return 0 }
        if id.contains("opus") { return 1 }
        if id.contains("sonnet") && id.contains("4-6") { return 2 }
        if id.contains("sonnet") { return 3 }
        if id.contains("haiku") { return 4 }
        return 5
    }
}

// MARK: - Types

public struct DiscoveredModel: Sendable {
    public let id: String
    public let name: String
    public let provider: String

    public init(id: String, name: String, provider: String) {
        self.id = id
        self.name = name
        self.provider = provider
    }
}
