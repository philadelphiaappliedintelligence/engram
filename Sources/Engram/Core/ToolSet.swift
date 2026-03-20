import Foundation

/// Shared tool registration — one source of truth for both CLI and daemon.
public enum ToolSet {

    /// All standard tools. Used by CLI and gateway daemon.
    public static func standard(
        shelf: Shelf,
        sessionId: String,
        client: LLMClient,
        config: AgentConfig = AgentConfig.load(),
        skillLoader: SkillLoader = SkillLoader(),
        cronStore: CronStore? = nil,
        store: EngramStore? = nil,
        searchIndex: SessionSearchIndex? = nil,
        platform: (any Platform)? = nil,
        chatId: String? = nil
    ) -> [any Tool] {
        var tools: [any Tool] = [
            // Memory (holographic)
            MemoryRememberTool(shelf: shelf),
            MemoryRecallTool(shelf: shelf, sessionId: sessionId),
            MemoryForgetTool(shelf: shelf),
            MemoryStatusTool(shelf: shelf),

            // Files
            FileReadTool(),
            FileWriteTool(),
            EditTool(),
            FileSearchTool(),
            GrepTool(),

            // Shell
            TerminalTool(),

            // Web
            WebFetchTool(),

            // Vision + Browser
            VisionTool(client: client),
            BrowserTool(client: client),

            // TTS
            TTSTool(),

            // macOS Native
            CalendarTool(),
            ContactsTool(),
            SpotlightTool(),
            ClipboardTool(),

            // Web search + image gen
            WebSearchTool(),
            ImageGenTool(),

            // Code execution
            ExecuteCodeTool(),

            // Subagent delegation
            DelegateTool(client: client, shelf: shelf, config: config),

            // Skills
            SkillListTool(loader: skillLoader),
            SkillViewTool(loader: skillLoader),
            SkillCreateTool(
                skillsDir: AgentConfig.configDir.appendingPathComponent("skills"),
                loader: skillLoader
            ),
        ]

        // Session search (SearchKit if available, else FTS5 fallback)
        if let searchIndex {
            tools.append(SearchKitSessionSearchTool(searchIndex: searchIndex))
        } else {
            tools.append(SessionSearchTool(sessionDir: AgentConfig.configDir.appendingPathComponent("sessions")))
        }

        // Identity tools (store-backed)
        if let store {
            tools.append(contentsOf: [
                IdentityReadTool(store: store),
                IdentityEditTool(store: store),
            ] as [any Tool])
        }

        // Cron (if store provided)
        if let cronStore {
            tools.append(contentsOf: [
                CronListTool(store: cronStore),
                CronCreateTool(store: cronStore),
                CronDeleteTool(store: cronStore),
            ] as [any Tool])
        }

        // Platform messaging (gateway only)
        if let platform, let chatId {
            tools.append(SendMessageTool(platform: platform, chatId: chatId))
        }

        return tools
    }
}
