import Foundation

// MARK: - Agent Configuration

public struct AgentConfig: Codable, Sendable {
    public var model: String
    public var summaryModel: String?   // cheap model for compaction (nil = use main model)
    public var provider: String?       // "anthropic" or "openai"
    public var baseURL: String?        // custom API endpoint
    public var maxTokens: Int
    public var maxIterations: Int
    public var contextWindow: Int
    public var memoryDir: String
    public var sessionDir: String
    public var apiKey: String?
    public var mcpServers: [String: MCPServerConfig]?
    public var gateway: GatewayConfig?

    public init(
        model: String = "claude-opus-4-6",
        summaryModel: String? = nil,
        provider: String? = nil,
        baseURL: String? = nil,
        maxTokens: Int = 8192,
        maxIterations: Int = 50,
        contextWindow: Int = 200_000,
        memoryDir: String = "~/.engram/memory",
        sessionDir: String = "~/.engram/sessions",
        apiKey: String? = nil
    ) {
        self.model = model
        self.summaryModel = summaryModel
        self.provider = provider
        self.baseURL = baseURL
        self.maxTokens = maxTokens
        self.maxIterations = maxIterations
        self.contextWindow = contextWindow
        self.memoryDir = memoryDir
        self.sessionDir = sessionDir
        self.apiKey = apiKey
    }

    public var resolvedProvider: LLMProvider {
        if let p = provider { return LLMProvider(rawValue: p) ?? .anthropic }
        return .anthropic
    }

    public var resolvedBaseURL: String {
        if let baseURL { return baseURL }
        switch resolvedProvider {
        case .openai: return "https://api.openai.com"
        case .codex: return "https://chatgpt.com/backend-api/codex"
        case .anthropic: return "https://api.anthropic.com"
        }
    }

    // MARK: - Paths

    public static var configDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".engram")
    }

    public static var configFile: URL {
        configDir.appendingPathComponent("config.json")
    }

    public var memoryURL: URL {
        URL(fileURLWithPath: (memoryDir as NSString).expandingTildeInPath)
    }

    public var sessionURL: URL {
        URL(fileURLWithPath: (sessionDir as NSString).expandingTildeInPath)
    }

    // MARK: - Load / Save

    public static func load() -> AgentConfig {
        loadEnvFile()
        ensureFirstBoot()

        let file = configFile
        guard FileManager.default.fileExists(atPath: file.path),
              let data = try? Data(contentsOf: file),
              var config = try? JSONDecoder().decode(AgentConfig.self, from: data) else {
            var config = AgentConfig()
            config.apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
            return config
        }
        if config.apiKey == nil {
            config.apiKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        }
        return config
    }

    /// Create ~/.engram/ structure and identity stubs on first boot
    private static func ensureFirstBoot() {
        let fm = FileManager.default
        let dir = configDir
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let stubs: [(String, String)] = [
            ("SOUL.md", """
            # Soul

            <!-- Your name and personality. The user may name you on first conversation. -->

            Your name is Engram.

            Be genuinely helpful, not performatively helpful. Skip filler words and just help.

            Have opinions. Be direct. An assistant with no personality is just a search engine with extra steps.

            Be resourceful before asking. Read the file. Check context. Search for it. Then ask if you're stuck.

            Memory is invisible. Never announce that you're remembering or recalling. Just know things.

            Concise when needed, thorough when it matters.

            """),
            ("USER.md", """
            # User

            <!-- About your human. Update this as you learn about them. -->

            - **Name:**
            - **What to call them:**
            - **Timezone:**
            - **Notes:**

            ## Context

            <!-- What do they care about? What are they working on? Build this over time. -->

            """),
            ("BOOTSTRAP.md", """
            # Bootstrap

            <!-- What to do on first conversation. Delete this file once you know who you are. -->

            You just came online. There's no memory yet.

            Don't interrogate. Don't list your capabilities. Just talk.

            If you don't know who the user is, ask naturally. Learn their name, what they're working on, how they like to communicate. Store what you learn.

            If you don't have a name yet (SOUL.md still says "Engram"), ask the user what they'd like to call you. Update SOUL.md with the name they give you.

            If memory already exists, use it silently. Greet them like you know them.

            """),
        ]
        for (name, content) in stubs {
            let file = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: file.path) {
                try? content.write(to: file, atomically: true, encoding: .utf8)
            }
        }
    }

    public func save() throws {
        let dir = AgentConfig.configDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var copy = self
        copy.apiKey = nil
        let data = try encoder.encode(copy)
        try data.write(to: AgentConfig.configFile, options: .atomic)
    }

    // MARK: - Validation

    public func validate() -> [String] {
        var issues: [String] = []
        if model.isEmpty { issues.append("model is empty") }
        if maxTokens <= 0 { issues.append("maxTokens must be > 0") }
        if maxIterations <= 0 { issues.append("maxIterations must be > 0") }
        if contextWindow <= 0 { issues.append("contextWindow must be > 0") }
        if let p = provider, LLMProvider(rawValue: p) == nil {
            issues.append("unknown provider '\(p)' -- use anthropic, openai, or codex")
        }
        return issues
    }

    // MARK: - Resolve API Key

    public func resolvedAPIKey() -> String? {
        apiKey ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
    }

    // MARK: - .env Loading

    private static func loadEnvFile() {
        let envFile = configDir.appendingPathComponent(".env")
        guard let content = try? String(contentsOf: envFile, encoding: .utf8) else { return }

        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            setenv(key, value, 0)  // 0 = don't overwrite existing
        }
    }
}
