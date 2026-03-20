import Foundation

/// The daemon main loop. Runs as a background process managed by launchd.
/// Polls gateway platforms, runs cron jobs, saves memory.
public actor DaemonLoop {
    private let config: AgentConfig
    private let shelf: Shelf
    private let cronStore: CronStore
    private let scheduler: CronScheduler
    private let store: EngramStore
    private let searchIndex: SessionSearchIndex
    private var platforms: [any Platform] = []
    private var chatSessions: [String: (agent: AgentLoop, lastActive: Date)] = [:]
    private var isRunning = false
    private let sessionMaxIdle: TimeInterval = 3600  // evict after 1 hour
    private let heartbeatInterval: TimeInterval = 60

    public init(config: AgentConfig, store: EngramStore) {
        self.config = config
        self.store = store
        self.searchIndex = SessionSearchIndex()
        self.shelf = Shelf(saveDir: config.memoryURL, store: store)

        let cronDir = AgentConfig.configDir.appendingPathComponent("cron")
        self.cronStore = CronStore(storeDir: cronDir, store: store)
        self.scheduler = CronScheduler(store: cronStore)
    }

    public func run() async {
        log("Engram daemon starting")

        shelf.loadAll()
        cronStore.load()
        await AgentConfig.ensureDefaultIdentities(store: store)
        isRunning = true

        log("Loaded \(shelf.nuggetNames.count) nuggets, \(cronStore.allJobs.count) cron jobs")

        writePidFile()
        let sigSources = installSignalHandlers()
        rotateLogs()

        // Start gateway platforms
        await startPlatforms()

        // Wire cron
        scheduler.onFire = { [weak self] job in
            guard let self else { return }
            Task { await self.executeCronJob(job) }
        }

        // Main loop — gateway drain every 1s, heartbeat every 60s
        var tick = 0
        while isRunning {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
            guard isRunning else { break }

            tick += 1

            // Poll gateway platforms every tick (5s)
            await pollPlatforms()

            // Cron + save + session eviction every 60s
            if tick % 60 == 0 {
                scheduler.tick()
                shelf.saveAll()
                evictIdleSessions()
            }

            // Reconnect dropped platforms every 5 minutes
            if tick % 300 == 0 {
                await reconnectPlatforms()
            }

            // Log every 5 minutes
            if tick % 300 == 0 {
                let mins = tick / 60
                log("Heartbeat — \(shelf.nuggetNames.count) nuggets, \(totalFacts()) facts, \(platforms.count) platforms, uptime \(mins)m")
            }

            // Memory consolidation every 6 hours
            if tick % 21600 == 0 {
                await consolidateMemory()
            }

            // Rotate logs daily
            if tick % 86400 == 0 { rotateLogs() }
        }

        // Cleanup
        for p in platforms { await p.stop() }
        shelf.saveAll()
        removePidFile()
        for src in sigSources { src.cancel() }
        log("Engram daemon stopped")
    }

    // MARK: - Gateway

    private func startPlatforms() async {
        guard let gw = config.gateway else {
            log("No gateway platforms configured")
            return
        }

        if let tg = gw.telegram, tg.enabled {
            let platform = TelegramPlatform(
                token: tg.botToken,
                allowedChatIds: tg.allowedChatIds ?? []
            )
            do {
                try await platform.start()
                platforms.append(platform)
                log("Telegram: connected")
            } catch {
                log("Telegram: failed — \(error.localizedDescription)")
            }
        }

        if let dc = gw.discord, dc.enabled {
            let platform = DiscordPlatform(
                token: dc.botToken,
                allowedChannelIds: dc.allowedChannelIds ?? []
            )
            do {
                try await platform.start()
                platforms.append(platform)
                log("Discord: connected")
            } catch {
                log("Discord: failed — \(error.localizedDescription)")
            }
        }

        if let sl = gw.slack, sl.enabled {
            let platform = SlackPlatform(
                appToken: sl.appToken,
                botToken: sl.botToken,
                allowedChannelIds: sl.allowedChannelIds ?? []
            )
            do {
                try await platform.start()
                platforms.append(platform)
                log("Slack: connected")
            } catch {
                log("Slack: failed — \(error.localizedDescription)")
            }
        }

        if let em = gw.email, em.enabled {
            let platform = EmailPlatform(
                imapServer: em.imapServer,
                smtpServer: em.smtpServer,
                email: em.email,
                password: em.password
            )
            do {
                try await platform.start()
                platforms.append(platform)
                log("Email: connected")
            } catch {
                log("Email: failed — \(error.localizedDescription)")
            }
        }

        if let ha = gw.homeassistant, ha.enabled {
            let platform = HomeAssistantPlatform(baseURL: ha.baseURL, token: ha.token)
            do {
                try await platform.start()
                platforms.append(platform)
                log("Home Assistant: connected")
            } catch { log("Home Assistant: failed -- \(error.localizedDescription)") }
        }

        if let im = gw.imessage, im.enabled {
            let platform = IMessagePlatform(config: im)
            do {
                try await platform.start()
                platforms.append(platform)
                let advanced = await platform.advancedFeaturesAvailable
                log("iMessage: connected\(advanced ? " (typing/read/tapback enabled)" : "")")
            } catch {
                log("iMessage: failed — \(error.localizedDescription)")
            }
        }

        log("\(platforms.count) gateway platforms active")
    }

    private func pollPlatforms() async {
        for platform in platforms {
            guard let messages = try? await platform.poll(), !messages.isEmpty else { continue }

            for msg in messages {
                log("[\(platform.name)] \(msg.sender): \(String(msg.text.prefix(80)))")
                await handleGatewayMessage(
                    text: msg.text,
                    chatId: msg.chatId,
                    sender: msg.sender,
                    platform: platform
                )
            }

        }
    }

    private func handleGatewayMessage(text: String, chatId: String, sender: String,
                                       platform: any Platform) async {
        let sessionKey = "\(platform.name):\(chatId)"
        let agent: AgentLoop

        if let existing = chatSessions[sessionKey] {
            agent = existing.agent
            chatSessions[sessionKey]?.lastActive = Date()
        } else {
            let oauthToken = await resolveOAuthToken()
            guard let apiKey = config.resolvedAPIKey() ?? oauthToken else {
                log("[\(platform.name)] No API key — cannot respond")
                return
            }

            let client = LLMClient(
                apiKey: apiKey,
                baseURL: config.resolvedBaseURL,
                provider: config.resolvedProvider
            )
            let registry = ToolRegistry()
            let sessionMgr = SessionManager(sessionDir: config.sessionURL, store: store, searchIndex: searchIndex)
            sessionMgr.newSession()

            registry.register(ToolSet.standard(
                shelf: shelf, sessionId: sessionKey, client: client,
                store: store, searchIndex: searchIndex,
                platform: platform, chatId: chatId
            ))

            agent = AgentLoop(
                client: client, registry: registry, shelf: shelf,
                config: config, session: sessionMgr,
                platformHint: platform.name, store: store
            )
            chatSessions[sessionKey] = (agent: agent, lastActive: Date())
        }

        do {
            try? await platform.sendTyping(to: chatId)

            let t0 = Date()
            let response = try await agent.run(input: text, onToolCall: { [weak self] name, _ in
                guard let self else { return }
                Task { await self.log("[\(platform.name)] tool: \(name)") }
            })
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(t0))
            log("[\(platform.name)] Response (\(elapsed)s): \(String(response.prefix(80)))")
            try await platform.sendMessage(response, to: chatId)
        } catch {
            log("[\(platform.name)] Error: \(error.localizedDescription)")
            try? await platform.sendMessage("Sorry, I encountered an error.", to: chatId)
        }
    }

    private func resolveOAuthToken() async -> String? {
        await OAuthClient().resolveToken()
    }

    // MARK: - Memory Consolidation

    private func consolidateMemory() async {
        let facts = shelf.status().reduce(0) { $0 + $1.factCount }
        guard facts > 10 else { return }

        let oauthToken = await resolveOAuthToken()
        guard let apiKey = config.resolvedAPIKey() ?? oauthToken else { return }

        log("Memory consolidation starting (\(facts) facts)")

        let client = LLMClient(
            apiKey: apiKey, baseURL: config.resolvedBaseURL,
            provider: config.resolvedProvider
        )
        let registry = ToolRegistry()
        let sessionMgr = SessionManager(sessionDir: config.sessionURL, store: store, searchIndex: searchIndex)
        sessionMgr.newSession()

        registry.register(ToolSet.standard(
            shelf: shelf, sessionId: "consolidation", client: client,
            store: store, searchIndex: searchIndex
        ))

        let agent = AgentLoop(
            client: client, registry: registry, shelf: shelf,
            config: config, session: sessionMgr, store: store
        )

        do {
            _ = try await agent.run(input: """
            Review your holographic memory (use memory_status). Look for:
            - Duplicate or redundant facts that can be merged
            - Outdated information that should be forgotten
            - Important patterns worth noting as new facts
            Do this silently. Do not output anything unless you find issues.
            """)
            log("Memory consolidation complete")
        } catch {
            log("Memory consolidation failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Session Eviction

    private func evictIdleSessions() {
        let now = Date()
        let stale = chatSessions.filter { now.timeIntervalSince($0.value.lastActive) > sessionMaxIdle }
        for key in stale.keys {
            chatSessions.removeValue(forKey: key)
            log("Session evicted (idle): \(key)")
        }
    }

    // MARK: - Platform Reconnection

    private func reconnectPlatforms() async {
        for platform in platforms {
            if !platform.isConnected {
                log("[\(platform.name)] Disconnected, reconnecting...")
                do {
                    try await platform.reconnect()
                    log("[\(platform.name)] Reconnected")
                } catch {
                    log("[\(platform.name)] Reconnect failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Cron

    private func executeCronJob(_ job: CronJob) async {
        log("Cron [\(job.id)] \(job.name) — firing")

        let oauthToken2 = await resolveOAuthToken()
        guard let apiKey = config.resolvedAPIKey() ?? oauthToken2 else {
            log("Cron [\(job.id)] — no API key")
            return
        }

        let client = LLMClient(
            apiKey: apiKey, baseURL: config.resolvedBaseURL,
            provider: config.resolvedProvider
        )
        let registry = ToolRegistry()
        let sessionMgr = SessionManager(sessionDir: config.sessionURL, store: store, searchIndex: searchIndex)
        sessionMgr.newSession()

        registry.register(ToolSet.standard(
            shelf: shelf, sessionId: UUID().uuidString, client: client,
            store: store, searchIndex: searchIndex
        ))

        let agent = AgentLoop(
            client: client, registry: registry, shelf: shelf,
            config: config, session: sessionMgr, store: store
        )

        do {
            let result = try await agent.run(input: job.prompt)
            log("Cron [\(job.id)] done — \(String(result.prefix(200)))")
            let outputDir = AgentConfig.configDir.appendingPathComponent("cron/outputs")
            try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            try? result.write(to: outputDir.appendingPathComponent("\(job.id)_latest.txt"),
                              atomically: true, encoding: .utf8)
        } catch {
            log("Cron [\(job.id)] failed — \(error.localizedDescription)")
        }
    }

    public func shutdown() { isRunning = false }

    private func totalFacts() -> Int {
        shelf.status().reduce(0) { $0 + $1.factCount }
    }

    // MARK: - PID / Signals / Logs

    private func writePidFile() {
        let pidFile = AgentConfig.configDir.appendingPathComponent("daemon.pid")
        try? String(ProcessInfo.processInfo.processIdentifier)
            .write(to: pidFile, atomically: true, encoding: .utf8)
    }

    private func removePidFile() {
        try? FileManager.default.removeItem(
            at: AgentConfig.configDir.appendingPathComponent("daemon.pid"))
    }

    private func installSignalHandlers() -> [DispatchSourceSignal] {
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                Task { await self.shutdown() }
            }
            source.resume()
            sources.append(source)
        }
        return sources
    }

    private func rotateLogs() {
        let logDir = AgentConfig.configDir.appendingPathComponent("logs")
        let logFile = logDir.appendingPathComponent("daemon.log")
        let fm = FileManager.default
        guard fm.fileExists(atPath: logFile.path),
              let attrs = try? fm.attributesOfItem(atPath: logFile.path),
              let size = attrs[.size] as? Int, size > 5_000_000 else { return }
        for i in stride(from: 4, through: 1, by: -1) {
            let old = logDir.appendingPathComponent("daemon.\(i).log")
            let new = logDir.appendingPathComponent("daemon.\(i + 1).log")
            try? fm.removeItem(at: new)
            try? fm.moveItem(at: old, to: new)
        }
        try? fm.moveItem(at: logFile, to: logDir.appendingPathComponent("daemon.1.log"))
        log("Logs rotated")
    }

    private func log(_ message: String) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        print("[\(f.string(from: Date()))] \(message)")
        fflush(stdout)
    }
}
