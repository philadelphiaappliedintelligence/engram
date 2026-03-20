import Foundation
import Testing
import SwiftData
@testable import Engram

// MARK: - EngramStore Tests

@Test func storeIdentityCRUD() async throws {
    let container = try makeTestContainer()
    let store = EngramStore(modelContainer: container)

    // Initially empty
    let initial = await store.getIdentity("soul")
    #expect(initial == nil)

    // Set and get
    await store.setIdentity("soul", content: "I am Engram.")
    let soul = await store.getIdentity("soul")
    #expect(soul == "I am Engram.")

    // Update
    await store.setIdentity("soul", content: "I am updated Engram.")
    let updated = await store.getIdentity("soul")
    #expect(updated == "I am updated Engram.")

    // Multiple identities
    await store.setIdentity("user", content: "Evan")
    let all = await store.allIdentities()
    #expect(all.count == 2)
}

@Test func storeConfigCRUD() async throws {
    let container = try makeTestContainer()
    let store = EngramStore(modelContainer: container)

    await store.setConfig("fda_status", value: "granted")
    let val = await store.getConfig("fda_status")
    #expect(val == "granted")

    await store.setConfig("fda_status", value: "skipped")
    let updated = await store.getConfig("fda_status")
    #expect(updated == "skipped")
}

@Test func storeFactsCRUD() async throws {
    let container = try makeTestContainer()
    let store = EngramStore(modelContainer: container)

    // Save and load facts
    await store.saveFact(nugget: "prefs", key: "color", value: "blue", hits: 0)
    await store.saveFact(nugget: "prefs", key: "editor", value: "vim", hits: 1)
    await store.saveFact(nugget: "people", key: "name", value: "Evan", hits: 5)

    let prefs = await store.loadFacts(nugget: "prefs")
    #expect(prefs.count == 2)

    let all = await store.loadAllFacts()
    #expect(all.count == 2) // 2 nuggets
    #expect(all["prefs"]?.count == 2)
    #expect(all["people"]?.count == 1)

    // Delete
    let deleted = await store.deleteFact(nugget: "prefs", key: "color")
    #expect(deleted == true)

    let after = await store.loadFacts(nugget: "prefs")
    #expect(after.count == 1)

    // Update hit
    await store.updateHit(nugget: "prefs", key: "editor", hits: 10, session: "s1")
    let updated = await store.loadFacts(nugget: "prefs")
    #expect(updated.first?.hits == 10)
    #expect(updated.first?.session == "s1")
}

@Test func storeSessionCRUD() async throws {
    let container = try makeTestContainer()
    let store = EngramStore(modelContainer: container)

    await store.createSession(id: "test-session-1")
    await store.appendMessage(sessionId: "test-session-1", role: "user", content: "Hello!", tokensIn: 10, tokensOut: nil)
    await store.appendMessage(sessionId: "test-session-1", role: "assistant", content: "Hi there!", tokensIn: nil, tokensOut: 20)

    let messages = await store.loadMessages(sessionId: "test-session-1")
    #expect(messages.count == 2)
    #expect(messages[0].role == "user")
    #expect(messages[1].role == "assistant")

    let sessions = await store.listSessions()
    #expect(sessions.count == 1)
    #expect(sessions[0].id == "test-session-1")
    #expect(sessions[0].preview == "Hello!")
    #expect(sessions[0].count == 2)

    let latest = await store.latestSessionId()
    #expect(latest == "test-session-1")
}

@Test func storeCronJobsCRUD() async throws {
    let container = try makeTestContainer()
    let store = EngramStore(modelContainer: container)

    await store.saveCronJob(id: "j1", name: "Daily Report", schedule: "0 9 * * *", prompt: "Generate report")
    await store.saveCronJob(id: "j2", name: "Backup", schedule: "0 0 * * 0", prompt: "Run backup", enabled: false)

    let jobs = await store.loadCronJobs()
    #expect(jobs.count == 2)

    await store.setCronJobEnabled(id: "j2", enabled: true)
    let updated = await store.loadCronJobs()
    #expect(updated.first { $0.id == "j2" }?.enabled == true)

    let deleted = await store.deleteCronJob(id: "j1")
    #expect(deleted == true)

    let remaining = await store.loadCronJobs()
    #expect(remaining.count == 1)
}

@Test func storeFactUpsert() async throws {
    let container = try makeTestContainer()
    let store = EngramStore(modelContainer: container)

    await store.saveFact(nugget: "prefs", key: "color", value: "blue")
    await store.saveFact(nugget: "prefs", key: "color", value: "red") // upsert

    let facts = await store.loadFacts(nugget: "prefs")
    #expect(facts.count == 1)
    #expect(facts.first?.value == "red")
}

// MARK: - KeychainStore Tests

@Test func keychainStoreBasicOps() {
    let kc = KeychainStore(service: "com.engram.test.\(UUID().uuidString)")

    // Set and get
    #expect(kc.set("test_key", value: "test_value"))
    #expect(kc.get("test_key") == "test_value")

    // Has
    #expect(kc.has("test_key"))
    #expect(!kc.has("nonexistent"))

    // Delete
    #expect(kc.delete("test_key"))
    #expect(kc.get("test_key") == nil)
}

@Test func keychainStoreJSON() {
    let kc = KeychainStore(service: "com.engram.test.\(UUID().uuidString)")

    struct TestCreds: Codable, Equatable {
        let token: String
        let expiresAt: Date
    }

    let creds = TestCreds(token: "sk-test-123", expiresAt: Date(timeIntervalSince1970: 1000000))
    #expect(kc.setJSON("creds", value: creds))

    let loaded = kc.getJSON("creds", as: TestCreds.self)
    #expect(loaded?.token == "sk-test-123")
    #expect(loaded?.expiresAt == creds.expiresAt)

    kc.delete("creds")
}

// MARK: - Helpers

private func makeTestContainer() throws -> ModelContainer {
    let schema = SwiftData.Schema([
        Identity.self, ConfigEntry.self, MemoryFact.self,
        ChatSession.self, ChatMessage.self, CronJobModel.self,
        GatewayEntry.self, MCPServerEntry.self, SkillIndexEntry.self,
    ])
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: schema, configurations: [config])
}
