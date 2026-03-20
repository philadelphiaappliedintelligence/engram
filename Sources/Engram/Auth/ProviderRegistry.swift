import Foundation

/// Known LLM providers with their auth methods and endpoints.
public struct ProviderInfo: Sendable {
    public let id: String
    public let name: String
    public let authType: AuthType
    public let baseURL: String
    public let envVars: [String]       // env vars to check for API key
    public let llmProvider: LLMProvider

    public enum AuthType: String, Sendable {
        case oauth = "OAuth (browser login)"
        case apiKey = "API Key"
        case none = "None (local)"
    }
}

public enum ProviderRegistry {
    public static let providers: [ProviderInfo] = [
        ProviderInfo(
            id: "anthropic-oauth", name: "Anthropic (Claude Pro/Max/Team)",
            authType: .oauth, baseURL: "https://api.anthropic.com",
            envVars: [], llmProvider: .anthropic
        ),
        ProviderInfo(
            id: "anthropic", name: "Anthropic (API Key)",
            authType: .apiKey, baseURL: "https://api.anthropic.com",
            envVars: ["ANTHROPIC_API_KEY"], llmProvider: .anthropic
        ),
        ProviderInfo(
            id: "openai-codex", name: "OpenAI (ChatGPT Plus/Pro — Codex OAuth)",
            authType: .oauth, baseURL: "https://chatgpt.com/backend-api/codex",
            envVars: [], llmProvider: .codex
        ),
        ProviderInfo(
            id: "openai", name: "OpenAI (API Key)",
            authType: .apiKey, baseURL: "https://api.openai.com",
            envVars: ["OPENAI_API_KEY"], llmProvider: .openai
        ),
        ProviderInfo(
            id: "openrouter", name: "OpenRouter (100+ models)",
            authType: .apiKey, baseURL: "https://openrouter.ai/api",
            envVars: ["OPENROUTER_API_KEY"], llmProvider: .openai
        ),
        ProviderInfo(
            id: "ollama", name: "Ollama (local, free)",
            authType: .none, baseURL: "http://127.0.0.1:11434/v1",
            envVars: [], llmProvider: .openai
        ),
        ProviderInfo(
            id: "groq", name: "Groq (fast inference)",
            authType: .apiKey, baseURL: "https://api.groq.com/openai",
            envVars: ["GROQ_API_KEY"], llmProvider: .openai
        ),
        ProviderInfo(
            id: "together", name: "Together AI",
            authType: .apiKey, baseURL: "https://api.together.xyz",
            envVars: ["TOGETHER_API_KEY"], llmProvider: .openai
        ),
        ProviderInfo(
            id: "mistral", name: "Mistral AI",
            authType: .apiKey, baseURL: "https://api.mistral.ai",
            envVars: ["MISTRAL_API_KEY"], llmProvider: .openai
        ),
        ProviderInfo(
            id: "xai", name: "xAI (Grok)",
            authType: .apiKey, baseURL: "https://api.x.ai",
            envVars: ["XAI_API_KEY"], llmProvider: .openai
        ),
        ProviderInfo(
            id: "deepseek", name: "DeepSeek",
            authType: .apiKey, baseURL: "https://api.deepseek.com",
            envVars: ["DEEPSEEK_API_KEY"], llmProvider: .openai
        ),
        ProviderInfo(
            id: "cerebras", name: "Cerebras",
            authType: .apiKey, baseURL: "https://api.cerebras.ai",
            envVars: ["CEREBRAS_API_KEY"], llmProvider: .openai
        ),
        ProviderInfo(
            id: "custom", name: "Custom OpenAI-compatible endpoint",
            authType: .apiKey, baseURL: "",
            envVars: [], llmProvider: .openai
        ),
    ]

    /// Check which providers have credentials available
    public static func availableProviders() -> [(provider: ProviderInfo, hasAuth: Bool)] {
        providers.map { p in
            let hasAuth: Bool
            switch p.authType {
            case .oauth:
                hasAuth = OAuthClient().loadCredentials() != nil
                    || readClaudeCodeToken() != nil
            case .apiKey:
                hasAuth = p.envVars.contains { ProcessInfo.processInfo.environment[$0] != nil }
            case .none:
                hasAuth = true  // local, always available
            }
            return (provider: p, hasAuth: hasAuth)
        }
    }

    public static func find(_ id: String) -> ProviderInfo? {
        providers.first { $0.id == id }
    }

    private static func readClaudeCodeToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            return nil
        }
        return token
    }
}
