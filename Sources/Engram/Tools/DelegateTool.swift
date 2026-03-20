import Foundation

/// Spawn an isolated subagent for a specific task.
/// Runs in parallel without affecting the main conversation history.
public struct DelegateTool: Tool {
    private let client: LLMClient
    private let shelf: Shelf
    private let config: AgentConfig

    public init(client: LLMClient, shelf: Shelf, config: AgentConfig) {
        self.client = client
        self.shelf = shelf
        self.config = config
    }

    public var name: String { "delegate" }
    public var description: String {
        """
        Spawn an isolated subagent to handle a task independently. \
        The subagent has its own conversation, can use tools, and returns the result. \
        Use for research, file operations, or any task that benefits from isolation. \
        Multiple delegates can run in parallel.
        """
    }
    public var inputSchema: [String: JSONValue] {
        Schema.object(properties: [
            "task": Schema.string(description: "What the subagent should do"),
            "tools": Schema.string(description: "Comma-separated tool names to give the subagent (default: all)"),
        ], required: ["task"])
    }

    public func execute(input: [String: JSONValue]) async throws -> String {
        guard let task = input["task"]?.stringValue else {
            return "{\"error\": \"Missing task\"}"
        }

        // Create isolated agent with its own session
        let registry = ToolRegistry()
        let sessionMgr = SessionManager(sessionDir: config.sessionURL)
        sessionMgr.newSession()
        let sessionId = "delegate-\(UUID().uuidString.prefix(8))"

        // Give it the standard tools
        registry.register(ToolSet.standard(
            shelf: shelf, sessionId: sessionId, client: client
        ))

        let agent = AgentLoop(
            client: client, registry: registry, shelf: shelf,
            config: config, session: sessionMgr
        )

        do {
            let result = try await agent.run(input: task)
            // Truncate long results
            if result.count > 4000 {
                return String(result.prefix(4000)) + "\n... (truncated)"
            }
            return result
        } catch {
            return "{\"error\": \"Subagent failed: \(error.localizedDescription)\"}"
        }
    }
}
