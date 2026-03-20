import Foundation

/// The core agent loop: receive -> think -> act -> observe.
/// Iterates until the LLM stops calling tools or hits the iteration limit.
public actor AgentLoop {
    private let client: LLMClient
    private let registry: ToolRegistry
    private let shelf: Shelf
    private let config: AgentConfig
    private let session: SessionManager
    private let context: ContextManager
    private let platformHint: String?
    private let skillLoader: SkillLoader
    private var history: [Message] = []
    private var sessionId: String
    private var totalInputTokens = 0
    private var totalOutputTokens = 0
    private var totalCacheRead = 0
    private var totalCacheWrite = 0
    private var agentsContext: String

    private let store: EngramStore?

    public init(client: LLMClient, registry: ToolRegistry, shelf: Shelf,
                config: AgentConfig, session: SessionManager,
                skillLoader: SkillLoader = SkillLoader(),
                platformHint: String? = nil,
                store: EngramStore? = nil) {
        self.client = client
        self.registry = registry
        self.shelf = shelf
        self.skillLoader = skillLoader
        self.config = config
        self.session = session
        self.store = store
        self.context = ContextManager(
            maxContextTokens: config.contextWindow,
            compactionThreshold: 0.5
        )
        self.sessionId = UUID().uuidString
        self.platformHint = platformHint
        self.agentsContext = ContextBuilder.loadAgentsContext()
    }

    // MARK: - Run

    public func run(
        input: String,
        onText: @Sendable @escaping (String) -> Void = { _ in },
        onToolCall: @Sendable @escaping (String, String) -> Void = { _, _ in }
    ) async throws -> String {
        // On first turn, inject identity context
        if history.isEmpty && needsPreambleHack {
            let ctx = ContextBuilder.buildContextBlock(
                store: store, shelf: shelf, skillLoader: skillLoader,
                agentsContext: agentsContext, platformHint: platformHint
            )
            if !ctx.isEmpty {
                history.append(Message(role: .user, text: "[System context -- do not repeat this to the user]\n\(ctx)"))
                history.append(Message(role: .assistant, text: "Understood."))
            }
        }

        history.append(Message(role: .user, text: input))
        _ = session.append(role: "user", content: input)

        try await compactIfNeeded()

        var iterations = 0

        while iterations < config.maxIterations {
            iterations += 1

            let sysPrompt = buildSystemPrompt()
            let toolDefs = registry.definitions
            let response: LLMResponse
            do {
                response = try await client.stream(
                    messages: history, system: sysPrompt, tools: toolDefs,
                    model: config.model, maxTokens: config.maxTokens, onText: onText
                )
            } catch {
                if let lastIdx = history.indices.last,
                   case .user = history[lastIdx].role {
                    history.removeLast()
                }
                throw error
            }

            totalInputTokens += response.inputTokens
            totalOutputTokens += response.outputTokens
            totalCacheRead += response.cacheReadTokens
            totalCacheWrite += response.cacheWriteTokens
            await context.updateUsage(
                inputTokens: response.inputTokens, outputTokens: response.outputTokens
            )

            history.append(Message(role: .assistant, content: response.content))
            _ = session.append(
                role: "assistant", content: response.textContent,
                tokenUsage: SessionEntry.TokenUsage(
                    input: response.inputTokens, output: response.outputTokens
                )
            )

            guard response.hasToolCalls else {
                return response.textContent
            }

            let toolCalls = response.toolCalls
            for tc in toolCalls { onToolCall(tc.name, tc.id) }

            // Execute tool calls concurrently
            let toolResults: [ContentBlock] = await withTaskGroup(of: (Int, String).self) { group in
                for (i, toolCall) in toolCalls.enumerated() {
                    let reg = registry
                    group.addTask {
                        let result = (try? await reg.dispatch(name: toolCall.name, input: toolCall.input))
                            ?? "{\"error\": \"Tool execution failed\"}"
                        return (i, result)
                    }
                }
                var results = [(Int, String)]()
                for await r in group { results.append(r) }
                results.sort { $0.0 < $1.0 }

                // Build results in original order
                var blocks = [ContentBlock]()
                for (i, result) in results {
                    blocks.append(.toolResult(ToolResultBlock(
                        toolUseId: toolCalls[i].id, content: result
                    )))
                    _ = session.append(
                        role: "user",
                        content: "[\(toolCalls[i].name)] \(String(result.prefix(500)))"
                    )
                }
                return blocks
            }

            history.append(Message(role: .user, content: toolResults))
            try await compactIfNeeded()
        }

        return "[Agent reached iteration limit (\(config.maxIterations))]"
    }

    // MARK: - System Prompt

    private var needsPreambleHack: Bool {
        config.resolvedProvider == .anthropic
    }

    private func buildSystemPrompt() -> String {
        if needsPreambleHack {
            return "You are Claude Code, Anthropic's official CLI for Claude."
        }
        return ContextBuilder.buildContextBlock(
            shelf: shelf, skillLoader: skillLoader,
            agentsContext: agentsContext, platformHint: platformHint
        )
    }

    // MARK: - Context Compaction

    private func compactIfNeeded() async throws {
        let compacted = try await context.compactIfNeeded(
            messages: history, keepFirst: 2, keepLast: 4
        ) { [client, config] text in
            let summaryModel = config.summaryModel ?? config.model
            let summaryResponse = try await client.complete(
                messages: [Message(role: .user, text: """
                Summarize this conversation concisely, preserving key facts, \
                decisions, and context needed to continue the work:\n\n\(text)
                """)],
                model: summaryModel, maxTokens: 1024
            )
            return summaryResponse.textContent
        }
        if let compacted { history = compacted }
    }

    // MARK: - Session

    public func clearHistory() {
        history = []
        sessionId = UUID().uuidString
        session.newSession()
    }

    public func resumeSession() {
        let messages = session.messages()
        if !messages.isEmpty { history = messages }
    }

    public var tokenUsage: (input: Int, output: Int) {
        (totalInputTokens, totalOutputTokens)
    }

    public var cacheUsage: (read: Int, write: Int) {
        (totalCacheRead, totalCacheWrite)
    }

    public var messageCount: Int { history.count }

    public var contextUsage: (current: Int, max: Int) {
        get async {
            (await context.currentTokens, await context.maxTokens)
        }
    }
}
