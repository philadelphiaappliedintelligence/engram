import Foundation

public struct ModelInfo: Sendable {
    public let id: String
    public let name: String
    public let provider: LLMProvider
    public let contextWindow: Int
    public let maxOutput: Int
    public let inputPrice: Double
    public let outputPrice: Double
    public let category: ModelCategory
    public let note: String

    public enum ModelCategory: String, Sendable {
        case flagship = "Flagship"
        case balanced = "Balanced"
        case fast = "Fast"
        case local = "Local"
        case legacy = "Legacy"
    }
}

public enum ModelCatalog {
    public static let anthropic: [ModelInfo] = [
        ModelInfo(id: "claude-opus-4-6", name: "Claude Opus 4.6",
                  provider: .anthropic, contextWindow: 1_000_000, maxOutput: 128_000,
                  inputPrice: 5, outputPrice: 25, category: .flagship,
                  note: "Most intelligent -- complex reasoning, coding, agents"),
        ModelInfo(id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6",
                  provider: .anthropic, contextWindow: 1_000_000, maxOutput: 64_000,
                  inputPrice: 3, outputPrice: 15, category: .balanced,
                  note: "Best speed/intelligence balance"),
        ModelInfo(id: "claude-haiku-4-5-20251001", name: "Claude Haiku 4.5",
                  provider: .anthropic, contextWindow: 200_000, maxOutput: 64_000,
                  inputPrice: 1, outputPrice: 5, category: .fast,
                  note: "Fastest -- high volume, real-time"),
        // Legacy
        ModelInfo(id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5",
                  provider: .anthropic, contextWindow: 200_000, maxOutput: 64_000,
                  inputPrice: 3, outputPrice: 15, category: .legacy, note: "Previous balanced"),
        ModelInfo(id: "claude-opus-4-5", name: "Claude Opus 4.5",
                  provider: .anthropic, contextWindow: 200_000, maxOutput: 64_000,
                  inputPrice: 5, outputPrice: 25, category: .legacy, note: "Previous flagship"),
        ModelInfo(id: "claude-opus-4-1", name: "Claude Opus 4.1",
                  provider: .anthropic, contextWindow: 200_000, maxOutput: 32_000,
                  inputPrice: 15, outputPrice: 75, category: .legacy, note: "Older flagship"),
        ModelInfo(id: "claude-sonnet-4-20250514", name: "Claude Sonnet 4.0",
                  provider: .anthropic, contextWindow: 200_000, maxOutput: 64_000,
                  inputPrice: 3, outputPrice: 15, category: .legacy, note: "Original Sonnet 4"),
    ]

    public static let openai: [ModelInfo] = [
        // OpenAI direct
        ModelInfo(id: "gpt-4o", name: "GPT-4o",
                  provider: .openai, contextWindow: 128_000, maxOutput: 16_384,
                  inputPrice: 2.5, outputPrice: 10, category: .flagship,
                  note: "OpenAI flagship multimodal"),
        ModelInfo(id: "gpt-4o-mini", name: "GPT-4o Mini",
                  provider: .openai, contextWindow: 128_000, maxOutput: 16_384,
                  inputPrice: 0.15, outputPrice: 0.60, category: .fast,
                  note: "OpenAI fast/cheap"),
        ModelInfo(id: "o3", name: "o3",
                  provider: .openai, contextWindow: 200_000, maxOutput: 100_000,
                  inputPrice: 2, outputPrice: 8, category: .flagship,
                  note: "OpenAI reasoning model"),
        // Ollama (local, free)
        ModelInfo(id: "llama3.3", name: "Llama 3.3 70B (Ollama)",
                  provider: .openai, contextWindow: 128_000, maxOutput: 4_096,
                  inputPrice: 0, outputPrice: 0, category: .local,
                  note: "Local via Ollama -- set baseURL to http://localhost:11434/v1"),
        ModelInfo(id: "qwen3", name: "Qwen 3 (Ollama)",
                  provider: .openai, contextWindow: 128_000, maxOutput: 4_096,
                  inputPrice: 0, outputPrice: 0, category: .local,
                  note: "Local via Ollama -- set baseURL to http://localhost:11434/v1"),
        ModelInfo(id: "deepseek-r1", name: "DeepSeek R1 (Ollama)",
                  provider: .openai, contextWindow: 128_000, maxOutput: 4_096,
                  inputPrice: 0, outputPrice: 0, category: .local,
                  note: "Local reasoning model via Ollama"),
        // OpenRouter (use with baseURL: https://openrouter.ai/api)
        ModelInfo(id: "anthropic/claude-opus-4-6", name: "Claude Opus 4.6 (OpenRouter)",
                  provider: .openai, contextWindow: 1_000_000, maxOutput: 128_000,
                  inputPrice: 5, outputPrice: 25, category: .flagship,
                  note: "Via OpenRouter -- set baseURL to https://openrouter.ai/api"),
        ModelInfo(id: "google/gemini-2.5-pro", name: "Gemini 2.5 Pro (OpenRouter)",
                  provider: .openai, contextWindow: 1_000_000, maxOutput: 65_536,
                  inputPrice: 1.25, outputPrice: 10, category: .flagship,
                  note: "Google via OpenRouter"),
        ModelInfo(id: "google/gemini-2.5-flash", name: "Gemini 2.5 Flash (OpenRouter)",
                  provider: .openai, contextWindow: 1_000_000, maxOutput: 65_536,
                  inputPrice: 0.15, outputPrice: 0.60, category: .fast,
                  note: "Google fast model via OpenRouter"),
    ]

    public static func models(for provider: LLMProvider) -> [ModelInfo] {
        switch provider {
        case .anthropic: return anthropic
        case .openai, .codex: return openai
        }
    }

    public static func currentModels(for provider: LLMProvider) -> [ModelInfo] {
        models(for: provider).filter { $0.category != .legacy }
    }

    public static func find(_ id: String) -> ModelInfo? {
        (anthropic + openai).first { $0.id == id }
    }
}
