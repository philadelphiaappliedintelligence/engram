import Foundation

// MARK: - Agent Configuration

public struct AgentConfig: Codable, Sendable {
    public var model: String
    public var summaryModel: String?   // cheap model for compaction (nil = use main model)
    public var gatewayModel: String?   // fast model for simple gateway messages (nil = use main model)
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
        gatewayModel: String? = nil,
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
        self.gatewayModel = gatewayModel
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

        let dir = configDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

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

    /// Seed default identities into the store on first boot.
    /// Call once after creating the EngramStore.
    public static func ensureDefaultIdentities(store: EngramStore) async {
        let defaults: [(String, String)] = [
            ("soul", """
            Your name is Engram.

            Be genuinely helpful, not performatively helpful. Skip filler words and just help.

            Have opinions. Be direct. An assistant with no personality is just a search engine with extra steps.

            Be resourceful before asking. Read the file. Check context. Search for it. Then ask if you're stuck.

            Memory is invisible. Never announce that you're remembering or recalling. Just know things.

            Concise when needed, thorough when it matters.
            """),
            ("user", ""),
            ("bootstrap", """
            Ask the user their name and what to call you.
            """),
        ]
        for (key, content) in defaults {
            let existing = await store.getIdentity(key)
            if existing == nil {
                await store.setIdentity(key, content: content)
            }
        }
    }

    /// Check Full Disk Access by testing readability of ~/Library/Messages/chat.db.
    /// Returns true if FDA is available.
    public static func checkFullDiskAccess() -> Bool {
        let chatDB = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Messages/chat.db")
        return FileManager.default.isReadableFile(atPath: chatDB.path)
    }

    /// Prompt the user for Full Disk Access if not already granted.
    /// Stores the result in the given store so we don't re-prompt.
    public static func promptFDAIfNeeded(store: EngramStore) async {
        // Check if we already prompted
        if let status = await store.getConfig("fda_prompted"), status == "true" {
            // Re-check if FDA was granted since last prompt
            if checkFullDiskAccess() {
                await store.setConfig("fda_status", value: "granted")
            }
            return
        }

        if checkFullDiskAccess() {
            await store.setConfig("fda_status", value: "granted")
            await store.setConfig("fda_prompted", value: "true")
            return
        }

        let engramPath = ProcessInfo.processInfo.arguments.first ?? "/usr/local/bin/engram"

        print("""

        Engram needs Full Disk Access for iMessage, calendar, and contacts.

          The binary to add: \(engramPath)

        Open System Settings now? (Y/n)\(" ")
        """, terminator: "")

        let input = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""

        if input.isEmpty || input == "y" || input == "yes" {
            // Open System Settings to Full Disk Access pane
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"]
            try? process.run()
            process.waitUntilExit()

            print("""

              1. Click + and add: \(engramPath)
              2. Restart engram

            Press Enter when done...\(" ")
            """, terminator: "")
            _ = readLine()

            if checkFullDiskAccess() {
                await store.setConfig("fda_status", value: "granted")
                print("  Full Disk Access granted.\n")
            } else {
                await store.setConfig("fda_status", value: "pending")
                print("  Not yet granted — some features will be limited.\n")
            }
        } else {
            await store.setConfig("fda_status", value: "skipped")
        }
        await store.setConfig("fda_prompted", value: "true")
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
