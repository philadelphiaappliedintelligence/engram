import Foundation
import Testing
@testable import Engram

// MARK: - Config Defaults

@Test func configDefaults() {
    let config = AgentConfig()
    #expect(config.model == "claude-opus-4-6")
    #expect(config.maxTokens == 8192)
    #expect(config.maxIterations == 50)
    #expect(config.contextWindow == 200_000)
    #expect(config.resolvedProvider == .anthropic)
}

// MARK: - Validation

@Test func configValidation() {
    var config = AgentConfig()
    #expect(config.validate().isEmpty)

    config.model = ""
    #expect(config.validate().contains("model is empty"))

    config.model = "test"; config.maxTokens = -1
    #expect(config.validate().contains("maxTokens must be > 0"))

    config.maxTokens = 100; config.maxIterations = 0
    #expect(config.validate().contains("maxIterations must be > 0"))

    config.maxIterations = 50; config.contextWindow = -1
    #expect(config.validate().contains("contextWindow must be > 0"))

    config.contextWindow = 200000; config.provider = "invalid"
    #expect(config.validate().contains { $0.contains("unknown provider") })
}

@Test func configValidProviders() {
    var config = AgentConfig()
    config.provider = "anthropic"
    #expect(config.validate().isEmpty)
    config.provider = "openai"
    #expect(config.validate().isEmpty)
    config.provider = "codex"
    #expect(config.validate().isEmpty)
}

// MARK: - Provider Resolution

@Test func configProviderResolution() {
    var config = AgentConfig()
    #expect(config.resolvedProvider == .anthropic)

    config.provider = "openai"
    #expect(config.resolvedProvider == .openai)

    config.provider = "codex"
    #expect(config.resolvedProvider == .codex)

    config.provider = "garbage"
    #expect(config.resolvedProvider == .anthropic)
}

@Test func configBaseURLResolution() {
    var config = AgentConfig()
    #expect(config.resolvedBaseURL == "https://api.anthropic.com")

    config.provider = "openai"
    #expect(config.resolvedBaseURL == "https://api.openai.com")

    config.provider = "codex"
    #expect(config.resolvedBaseURL == "https://chatgpt.com/backend-api/codex")

    config.baseURL = "https://custom.api.com"
    #expect(config.resolvedBaseURL == "https://custom.api.com")
}

// MARK: - Persistence

@Test func configSaveLoad() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("config_test_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let file = tempDir.appendingPathComponent("config.json")
    var config = AgentConfig()
    config.model = "test-model"
    config.maxTokens = 4096

    let encoder = JSONEncoder(); encoder.outputFormatting = .prettyPrinted
    try encoder.encode(config).write(to: file)

    let loaded = try JSONDecoder().decode(AgentConfig.self, from: Data(contentsOf: file))
    #expect(loaded.model == "test-model")
    #expect(loaded.maxTokens == 4096)
}

@Test func configGateway() throws {
    var config = AgentConfig()
    config.gateway = GatewayConfig()
    config.gateway?.telegram = TelegramConfig(botToken: "test:token")

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(AgentConfig.self, from: data)
    #expect(decoded.gateway?.telegram?.botToken == "test:token")
    #expect(decoded.gateway?.telegram?.enabled == true)
}

// MARK: - Types

@Test func jsonValueCodable() throws {
    let values: [String: JSONValue] = [
        "str": .string("hello"),
        "num": .number(42),
        "bool": .bool(true),
        "null": .null,
        "arr": .array([.string("a"), .number(1)]),
        "obj": .object(["key": .string("val")]),
    ]

    let data = try JSONEncoder().encode(values)
    let decoded = try JSONDecoder().decode([String: JSONValue].self, from: data)
    #expect(decoded["str"]?.stringValue == "hello")
    #expect(decoded["num"]?.numberValue == 42)
    #expect(decoded["bool"]?.boolValue == true)
    #expect(decoded["null"] == .null)
    #expect(decoded["arr"]?.arrayValue?.count == 2)
    #expect(decoded["obj"]?.objectValue?["key"]?.stringValue == "val")
}

@Test func messageTextContent() {
    let msg = Message(role: .user, text: "hello")
    #expect(msg.textContent == "hello")
    #expect(msg.role == .user)
}

@Test func messageMultiContent() {
    let msg = Message(role: .assistant, content: [
        .text("part1"),
        .text("part2"),
    ])
    #expect(msg.textContent == "part1\npart2")
}

@Test func llmResponseProperties() {
    let response = LLMResponse(
        content: [.text("hello"), .toolUse(ToolUse(id: "1", name: "test", input: [:]))],
        stopReason: .toolUse,
        inputTokens: 100, outputTokens: 50,
        cacheReadTokens: 10, cacheWriteTokens: 20
    )
    #expect(response.textContent == "hello")
    #expect(response.hasToolCalls)
    #expect(response.toolCalls.count == 1)
    #expect(response.stopReason == .toolUse)
}

// MARK: - Session

@Test func sessionManagerBasic() {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("session_test_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let mgr = SessionManager(sessionDir: tempDir)
    mgr.newSession()
    #expect(mgr.currentSessionFile != nil)

    _ = mgr.append(role: "user", content: "hello")
    _ = mgr.append(role: "assistant", content: "hi there")

    let entries = mgr.currentEntries
    #expect(entries.count == 2)
    #expect(entries[0].role == "user")
    #expect(entries[1].content == "hi there")
}

@Test func sessionManagerList() {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("session_list_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let mgr = SessionManager(sessionDir: tempDir)
    mgr.newSession()
    _ = mgr.append(role: "user", content: "first session")

    mgr.newSession()
    _ = mgr.append(role: "user", content: "second session")

    let sessions = mgr.listSessions()
    #expect(sessions.count == 2)
}
