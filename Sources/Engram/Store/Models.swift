import Foundation
import SwiftData

// MARK: - Identity

@Model public final class Identity {
    @Attribute(.unique) public var key: String
    public var content: String
    public var updatedAt: Date

    public init(key: String, content: String, updatedAt: Date = Date()) {
        self.key = key
        self.content = content
        self.updatedAt = updatedAt
    }
}

// MARK: - Config

@Model public final class ConfigEntry {
    @Attribute(.unique) public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

// MARK: - Memory (HRR Facts)

@Model public final class MemoryFact {
    public var artifact: String
    public var key: String
    public var value: String
    public var hits: Int
    public var lastHitSession: String?

    // Uniqueness on (artifact, key) enforced in EngramStore upsert logic

    public init(artifact: String, key: String, value: String, hits: Int = 0, lastHitSession: String? = nil) {
        self.artifact = artifact
        self.key = key
        self.value = value
        self.hits = hits
        self.lastHitSession = lastHitSession
    }
}

// MARK: - Chat Sessions

@Model public final class ChatSession {
    @Attribute(.unique) public var sessionId: String
    public var createdAt: Date
    public var preview: String?
    public var messageCount: Int
    @Relationship(deleteRule: .cascade) public var messages: [ChatMessage]

    public init(sessionId: String, createdAt: Date = Date(), preview: String? = nil,
                messageCount: Int = 0, messages: [ChatMessage] = []) {
        self.sessionId = sessionId
        self.createdAt = createdAt
        self.preview = preview
        self.messageCount = messageCount
        self.messages = messages
    }
}

@Model public final class ChatMessage {
    public var role: String
    public var content: String
    public var tokensIn: Int?
    public var tokensOut: Int?
    public var timestamp: Date
    public var session: ChatSession?

    public init(role: String, content: String, tokensIn: Int? = nil, tokensOut: Int? = nil,
                timestamp: Date = Date(), session: ChatSession? = nil) {
        self.role = role
        self.content = content
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.timestamp = timestamp
        self.session = session
    }
}

// MARK: - Cron Jobs

@Model public final class CronJobModel {
    @Attribute(.unique) public var jobId: String
    public var name: String
    public var schedule: String
    public var prompt: String
    public var enabled: Bool
    public var lastRun: Date?
    public var createdAt: Date

    public init(jobId: String, name: String, schedule: String, prompt: String,
                enabled: Bool = true, lastRun: Date? = nil, createdAt: Date = Date()) {
        self.jobId = jobId
        self.name = name
        self.schedule = schedule
        self.prompt = prompt
        self.enabled = enabled
        self.lastRun = lastRun
        self.createdAt = createdAt
    }
}

// MARK: - Gateway

@Model public final class GatewayEntry {
    @Attribute(.unique) public var platform: String
    public var enabled: Bool
    public var configJSON: String

    public init(platform: String, enabled: Bool, configJSON: String) {
        self.platform = platform
        self.enabled = enabled
        self.configJSON = configJSON
    }
}

// MARK: - MCP Servers

@Model public final class MCPServerEntry {
    @Attribute(.unique) public var name: String
    public var command: String
    public var argsJSON: String
    public var envJSON: String

    public init(name: String, command: String, argsJSON: String = "[]", envJSON: String = "{}") {
        self.name = name
        self.command = command
        self.argsJSON = argsJSON
        self.envJSON = envJSON
    }
}

// MARK: - Skills Index

@Model public final class SkillIndexEntry {
    @Attribute(.unique) public var name: String
    public var desc: String?
    public var autoLoad: Bool
    public var tagsJSON: String?
    public var path: String

    public init(name: String, desc: String? = nil, autoLoad: Bool = false,
                tagsJSON: String? = nil, path: String) {
        self.name = name
        self.desc = desc
        self.autoLoad = autoLoad
        self.tagsJSON = tagsJSON
        self.path = path
    }
}
