import Foundation
import SwiftData

@ModelActor public actor EngramStore {

    // MARK: - Container Factory

    public static func makeContainer() throws -> ModelContainer {
        let schema = SwiftData.Schema([
            Identity.self, ConfigEntry.self, MemoryFact.self,
            ChatSession.self, ChatMessage.self, CronJobModel.self,
            GatewayEntry.self, MCPServerEntry.self, SkillIndexEntry.self,
        ])

        let storeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".engram")
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)

        let storeURL = storeDir.appendingPathComponent("engram.store")
        let config = ModelConfiguration(url: storeURL)
        return try ModelContainer(for: schema, configurations: [config])
    }

    // MARK: - Identity

    public func getIdentity(_ key: String) -> String? {
        let predicate = #Predicate<Identity> { $0.key == key }
        let descriptor = FetchDescriptor<Identity>(predicate: predicate)
        return (try? modelContext.fetch(descriptor))?.first?.content
    }

    public func setIdentity(_ key: String, content: String) {
        let predicate = #Predicate<Identity> { $0.key == key }
        let descriptor = FetchDescriptor<Identity>(predicate: predicate)

        if let existing = (try? modelContext.fetch(descriptor))?.first {
            existing.content = content
            existing.updatedAt = Date()
        } else {
            modelContext.insert(Identity(key: key, content: content))
        }
        try? modelContext.save()
    }

    public func allIdentities() -> [(key: String, content: String, updatedAt: Date)] {
        let descriptor = FetchDescriptor<Identity>()
        guard let results = try? modelContext.fetch(descriptor) else { return [] }
        return results.map { (key: $0.key, content: $0.content, updatedAt: $0.updatedAt) }
    }

    // MARK: - Config

    public func getConfig(_ key: String) -> String? {
        let predicate = #Predicate<ConfigEntry> { $0.key == key }
        let descriptor = FetchDescriptor<ConfigEntry>(predicate: predicate)
        return (try? modelContext.fetch(descriptor))?.first?.value
    }

    public func setConfig(_ key: String, value: String) {
        let predicate = #Predicate<ConfigEntry> { $0.key == key }
        let descriptor = FetchDescriptor<ConfigEntry>(predicate: predicate)

        if let existing = (try? modelContext.fetch(descriptor))?.first {
            existing.value = value
        } else {
            modelContext.insert(ConfigEntry(key: key, value: value))
        }
        try? modelContext.save()
    }

    // MARK: - Facts (HRR Memory)

    public func saveFact(artifact: String, key: String, value: String, hits: Int = 0, session: String? = nil) {
        let predicate = #Predicate<MemoryFact> { $0.artifact == artifact && $0.key == key }
        let descriptor = FetchDescriptor<MemoryFact>(predicate: predicate)

        if let existing = (try? modelContext.fetch(descriptor))?.first {
            existing.value = value
            existing.hits = hits
            existing.lastHitSession = session
        } else {
            modelContext.insert(MemoryFact(artifact: artifact, key: key, value: value, hits: hits, lastHitSession: session))
        }
        try? modelContext.save()
    }

    public func loadFacts(artifact: String) -> [(key: String, value: String, hits: Int, session: String?)] {
        let predicate = #Predicate<MemoryFact> { $0.artifact == artifact }
        let descriptor = FetchDescriptor<MemoryFact>(predicate: predicate)
        guard let results = try? modelContext.fetch(descriptor) else { return [] }
        return results.map { (key: $0.key, value: $0.value, hits: $0.hits, session: $0.lastHitSession) }
    }

    public func loadAllFacts() -> [String: [(key: String, value: String, hits: Int, session: String?)]] {
        let descriptor = FetchDescriptor<MemoryFact>()
        guard let results = try? modelContext.fetch(descriptor) else { return [:] }

        var grouped: [String: [(key: String, value: String, hits: Int, session: String?)]] = [:]
        for fact in results {
            grouped[fact.artifact, default: []].append(
                (key: fact.key, value: fact.value, hits: fact.hits, session: fact.lastHitSession)
            )
        }
        return grouped
    }

    public func deleteFact(artifact: String, key: String) -> Bool {
        let predicate = #Predicate<MemoryFact> { $0.artifact == artifact && $0.key == key }
        let descriptor = FetchDescriptor<MemoryFact>(predicate: predicate)
        guard let existing = (try? modelContext.fetch(descriptor))?.first else { return false }
        modelContext.delete(existing)
        try? modelContext.save()
        return true
    }

    public func updateHit(artifact: String, key: String, hits: Int, session: String) {
        let predicate = #Predicate<MemoryFact> { $0.artifact == artifact && $0.key == key }
        let descriptor = FetchDescriptor<MemoryFact>(predicate: predicate)
        guard let existing = (try? modelContext.fetch(descriptor))?.first else { return }
        existing.hits = hits
        existing.lastHitSession = session
        try? modelContext.save()
    }

    // MARK: - Sessions

    public func createSession(id: String) {
        let session = ChatSession(sessionId: id)
        modelContext.insert(session)
        try? modelContext.save()
    }

    public func appendMessage(sessionId: String, role: String, content: String,
                              tokensIn: Int? = nil, tokensOut: Int? = nil) {
        let predicate = #Predicate<ChatSession> { $0.sessionId == sessionId }
        let descriptor = FetchDescriptor<ChatSession>(predicate: predicate)
        guard let session = (try? modelContext.fetch(descriptor))?.first else { return }

        let message = ChatMessage(role: role, content: content, tokensIn: tokensIn, tokensOut: tokensOut)
        message.session = session
        session.messages.append(message)
        session.messageCount += 1

        // Set preview from first user message
        if session.preview == nil && role == "user" {
            session.preview = String(content.prefix(80))
        }

        try? modelContext.save()
    }

    public func loadMessages(sessionId: String) -> [(role: String, content: String, tokensIn: Int?, tokensOut: Int?, timestamp: Date)] {
        let predicate = #Predicate<ChatSession> { $0.sessionId == sessionId }
        let descriptor = FetchDescriptor<ChatSession>(predicate: predicate)
        guard let session = (try? modelContext.fetch(descriptor))?.first else { return [] }

        return session.messages
            .sorted { $0.timestamp < $1.timestamp }
            .map { (role: $0.role, content: $0.content, tokensIn: $0.tokensIn, tokensOut: $0.tokensOut, timestamp: $0.timestamp) }
    }

    public func listSessions() -> [(id: String, preview: String?, count: Int, date: Date)] {
        var descriptor = FetchDescriptor<ChatSession>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 100
        guard let results = try? modelContext.fetch(descriptor) else { return [] }
        return results.map { (id: $0.sessionId, preview: $0.preview, count: $0.messageCount, date: $0.createdAt) }
    }

    public func latestSessionId() -> String? {
        var descriptor = FetchDescriptor<ChatSession>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first?.sessionId
    }

    // MARK: - Cron Jobs

    public func loadCronJobs() -> [(id: String, name: String, schedule: String, prompt: String, enabled: Bool, lastRun: Date?, createdAt: Date)] {
        let descriptor = FetchDescriptor<CronJobModel>()
        guard let results = try? modelContext.fetch(descriptor) else { return [] }
        return results.map { (id: $0.jobId, name: $0.name, schedule: $0.schedule, prompt: $0.prompt, enabled: $0.enabled, lastRun: $0.lastRun, createdAt: $0.createdAt) }
    }

    public func saveCronJob(id: String, name: String, schedule: String, prompt: String,
                            enabled: Bool = true, lastRun: Date? = nil) {
        let predicate = #Predicate<CronJobModel> { $0.jobId == id }
        let descriptor = FetchDescriptor<CronJobModel>(predicate: predicate)

        if let existing = (try? modelContext.fetch(descriptor))?.first {
            existing.name = name
            existing.schedule = schedule
            existing.prompt = prompt
            existing.enabled = enabled
            existing.lastRun = lastRun
        } else {
            modelContext.insert(CronJobModel(jobId: id, name: name, schedule: schedule,
                                             prompt: prompt, enabled: enabled, lastRun: lastRun))
        }
        try? modelContext.save()
    }

    public func deleteCronJob(id: String) -> Bool {
        let predicate = #Predicate<CronJobModel> { $0.jobId == id }
        let descriptor = FetchDescriptor<CronJobModel>(predicate: predicate)
        guard let existing = (try? modelContext.fetch(descriptor))?.first else { return false }
        modelContext.delete(existing)
        try? modelContext.save()
        return true
    }

    public func updateCronJobLastRun(id: String, date: Date) {
        let predicate = #Predicate<CronJobModel> { $0.jobId == id }
        let descriptor = FetchDescriptor<CronJobModel>(predicate: predicate)
        guard let existing = (try? modelContext.fetch(descriptor))?.first else { return }
        existing.lastRun = date
        try? modelContext.save()
    }

    public func setCronJobEnabled(id: String, enabled: Bool) {
        let predicate = #Predicate<CronJobModel> { $0.jobId == id }
        let descriptor = FetchDescriptor<CronJobModel>(predicate: predicate)
        guard let existing = (try? modelContext.fetch(descriptor))?.first else { return }
        existing.enabled = enabled
        try? modelContext.save()
    }

    // MARK: - Gateway

    public func loadGateways() -> [(platform: String, enabled: Bool, config: String)] {
        let descriptor = FetchDescriptor<GatewayEntry>()
        guard let results = try? modelContext.fetch(descriptor) else { return [] }
        return results.map { (platform: $0.platform, enabled: $0.enabled, config: $0.configJSON) }
    }

    public func saveGateway(platform: String, enabled: Bool, config: String) {
        let predicate = #Predicate<GatewayEntry> { $0.platform == platform }
        let descriptor = FetchDescriptor<GatewayEntry>(predicate: predicate)

        if let existing = (try? modelContext.fetch(descriptor))?.first {
            existing.enabled = enabled
            existing.configJSON = config
        } else {
            modelContext.insert(GatewayEntry(platform: platform, enabled: enabled, configJSON: config))
        }
        try? modelContext.save()
    }

    // MARK: - MCP Servers

    public func loadMCPServers() -> [(name: String, command: String, args: String, env: String)] {
        let descriptor = FetchDescriptor<MCPServerEntry>()
        guard let results = try? modelContext.fetch(descriptor) else { return [] }
        return results.map { (name: $0.name, command: $0.command, args: $0.argsJSON, env: $0.envJSON) }
    }

    public func saveMCPServer(name: String, command: String, args: String = "[]", env: String = "{}") {
        let predicate = #Predicate<MCPServerEntry> { $0.name == name }
        let descriptor = FetchDescriptor<MCPServerEntry>(predicate: predicate)

        if let existing = (try? modelContext.fetch(descriptor))?.first {
            existing.command = command
            existing.argsJSON = args
            existing.envJSON = env
        } else {
            modelContext.insert(MCPServerEntry(name: name, command: command, argsJSON: args, envJSON: env))
        }
        try? modelContext.save()
    }
}
