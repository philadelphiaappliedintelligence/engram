import ArgumentParser
import Engram
import Foundation

struct Chat: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Interactive chat with the agent")

    @Option(name: .shortAndLong, help: "Model to use")
    var model: String?

    @Flag(name: .shortAndLong, help: "Resume most recent session")
    var resume = false

    @Argument(help: "One-shot message (omit for interactive mode)")
    var message: [String] = []

    func run() async throws {
        var config = AgentConfig.load()
        if let model { config.model = model }

        let oauth = OAuthClient()
        let openaiOAuth = OpenAIOAuth()
        let resolvedKey: String?
        switch config.resolvedProvider {
        case .codex: resolvedKey = await openaiOAuth.resolveToken() ?? config.resolvedAPIKey()
        case .anthropic: resolvedKey = await oauth.resolveToken() ?? config.resolvedAPIKey()
        case .openai: resolvedKey = config.resolvedAPIKey()
        }
        guard let apiKey = resolvedKey else {
            print("\(TUI.red)No credentials found.\(TUI.reset) Run \(TUI.cyan)engram login\(TUI.reset)")
            throw ExitCode.failure
        }

        let client = LLMClient(
            apiKey: apiKey, baseURL: config.resolvedBaseURL,
            provider: config.resolvedProvider, oauth: oauth
        )
        let shelf = Shelf(saveDir: config.memoryURL)
        shelf.loadAll()
        let sessionMgr = SessionManager(sessionDir: config.sessionURL)
        let skillLoader = SkillLoader(); skillLoader.loadAll()
        let cronStore = CronStore(storeDir: AgentConfig.configDir.appendingPathComponent("cron"))
        cronStore.load()

        let registry = ToolRegistry()
        let sessionId = UUID().uuidString
        registry.register(ToolSet.standard(
            shelf: shelf, sessionId: sessionId, client: client,
            config: config, skillLoader: skillLoader, cronStore: cronStore
        ))

        let mcpManager = MCPManager()
        if let mcpServers = config.mcpServers, !mcpServers.isEmpty {
            let mcpTools = mcpManager.startServers(from: mcpServers)
            registry.register(mcpTools)
        }

        if resume {
            if sessionMgr.resumeLatest() {
                print("\(TUI.dim)Resumed: \(sessionMgr.currentSessionFile?.lastPathComponent ?? "")\(TUI.reset)")
            } else { sessionMgr.newSession() }
        } else { sessionMgr.newSession() }

        let agent = AgentLoop(
            client: client, registry: registry, shelf: shelf,
            config: config, session: sessionMgr, skillLoader: skillLoader
        )
        if resume { await agent.resumeSession() }

        // One-shot mode — no TUI, just stream output
        if !message.isEmpty {
            let input = message.joined(separator: " ")
            let spinner = Spinner()
            var hasText = false
            spinner.start()
            _ = try await agent.run(input: input, onText: { text in
                if !hasText { spinner.stop() }
                print(text, terminator: ""); hasText = true
            }, onToolCall: { name, _ in
                if !hasText { spinner.update(name) }
            })
            spinner.stop(); print(); shelf.saveAll()
            return
        }

        // ─── Interactive mode: Raw Terminal TUI ───

        let term = RawTerminal()

        // Print banner in normal mode first
        printBanner(config: config, shelf: shelf, toolCount: registry.count,
                    skillCount: skillLoader.count)

        // Enter raw mode
        term.enableRawMode()
        installRawSignalHandlers(shelf: shelf, term: term)

        // Auto-save
        let autoSaveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                shelf.saveAll()
            }
        }
        defer {
            autoSaveTask.cancel()
            term.disableRawMode()
        }

        let cwd = shortenCwd()
        var totalInput = 0, totalOutput = 0, totalCacheRead = 0
        var ctxCurrent = 0, ctxMax = config.contextWindow

        // Draw initial footer
        term.drawFooter(
            cwd: cwd, model: config.model,
            contextMax: ctxMax
        )

        // Main loop
        while true {
            guard let line = term.readLine() else {
                // Ctrl+C or Ctrl+D with empty buffer
                shelf.saveAll()
                term.disableRawMode()
                print("\nGoodbye.")
                return
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                term.drawFooter(
                    cwd: cwd, model: config.model,
                    inputTokens: totalInput, outputTokens: totalOutput,
                    cacheRead: totalCacheRead,
                    contextCurrent: ctxCurrent, contextMax: ctxMax
                )
                continue
            }

            if trimmed.lowercased() == "exit" || trimmed.lowercased() == "quit" {
                shelf.saveAll()
                term.disableRawMode()
                print("\nGoodbye.")
                return
            }

            // Slash commands — drop to cooked mode temporarily
            if trimmed.hasPrefix("/") {
                term.disableRawMode()
                let cmd = String(trimmed.dropFirst())
                _ = await handleSlashCommand(cmd, shelf: shelf, config: config,
                                             agent: agent, session: sessionMgr,
                                             skills: skillLoader, cronStore: cronStore)
                term.enableRawMode()
                term.drawFooter(
                    cwd: cwd, model: config.model,
                    inputTokens: totalInput, outputTokens: totalOutput,
                    cacheRead: totalCacheRead,
                    contextCurrent: ctxCurrent, contextMax: ctxMax
                )
                continue
            }

            // Bash shortcut
            if trimmed.hasPrefix("!") {
                term.disableRawMode()
                let cmd = String(trimmed.dropFirst())
                let tool = TerminalTool()
                let result = try await tool.execute(input: ["command": .string(cmd)])
                print(result)
                term.enableRawMode()
                term.drawFooter(
                    cwd: cwd, model: config.model,
                    inputTokens: totalInput, outputTokens: totalOutput,
                    cacheRead: totalCacheRead,
                    contextCurrent: ctxCurrent, contextMax: ctxMax
                )
                continue
            }

            // ─── Chat message ───

            // Clear input and show user message in chat
            term.clearInput()
            term.moveToChatEnd()
            let w = term.width
            let userBar = "\u{001B}[48;5;236m \(trimmed)\(String(repeating: " ", count: max(0, w - trimmed.count - 1)))\u{001B}[0m"
            print("\(userBar)\n")

            let spinner = Spinner()
            var hasText = false
            spinner.start()

            do {
                _ = try await agent.run(input: trimmed, onText: { text in
                    if !hasText { spinner.stop() }
                    print(text, terminator: "")
                    fflush(stdout)
                    hasText = true
                }, onToolCall: { name, _ in
                    if !hasText { spinner.update(name) }
                })
                spinner.stop()
                print("\n")  // newline to end response + blank line after

                // Update stats
                let usage = await agent.tokenUsage
                let cache = await agent.cacheUsage
                let ctx = await agent.contextUsage
                totalInput = usage.input
                totalOutput = usage.output
                totalCacheRead = cache.read
                ctxCurrent = ctx.current
                ctxMax = ctx.max
            } catch {
                spinner.stop()
                print("\n\u{001B}[31mError: \(error.localizedDescription)\u{001B}[0m\n")
            }

            // Redraw footer with updated stats
            term.drawFooter(
                cwd: cwd, model: config.model,
                inputTokens: totalInput, outputTokens: totalOutput,
                cacheRead: totalCacheRead,
                contextCurrent: ctxCurrent, contextMax: ctxMax
            )
        }
    }
}

private func shortenCwd() -> String {
    var path = FileManager.default.currentDirectoryPath
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if path.hasPrefix(home) { path = "~" + String(path.dropFirst(home.count)) }
    let gitHead = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".git/HEAD")
    if let head = try? String(contentsOf: gitHead, encoding: .utf8) {
        let branch = head.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "ref: refs/heads/", with: "")
        path += " (\(branch))"
    }
    return path
}

private func installRawSignalHandlers(shelf: Shelf, term: RawTerminal) {
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            shelf.saveAll()
            term.disableRawMode()
            print("\nGoodbye.")
            exit(0)
        }
        source.resume()
        _signalSources.append(source)
    }
    // Handle window resize
    signal(SIGWINCH, SIG_IGN)
    let winch = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .main)
    winch.setEventHandler {
        term.updateSize()
    }
    winch.resume()
    _signalSources.append(winch)
}
