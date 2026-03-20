import Foundation

/// Configuration for all gateway platforms. Stored in ~/.engram/config.json under "gateway".
public struct GatewayConfig: Codable, Sendable {
    public var telegram: TelegramConfig?
    public var discord: DiscordConfig?
    public var slack: SlackConfig?
    public var email: EmailConfig?
    public var imessage: IMessageConfig?
    public var homeassistant: HomeAssistantConfig?

    public init() {}

    public var enabledPlatforms: [String] {
        var list: [String] = []
        if telegram?.enabled == true { list.append("telegram") }
        if discord?.enabled == true { list.append("discord") }
        if slack?.enabled == true { list.append("slack") }
        if email?.enabled == true { list.append("email") }
        if imessage?.enabled == true { list.append("imessage") }
        if homeassistant?.enabled == true { list.append("homeassistant") }
        return list
    }
}

public struct TelegramConfig: Codable, Sendable {
    public var enabled: Bool
    public var botToken: String
    public var allowedChatIds: [String]?

    public init(botToken: String, allowedChatIds: [String]? = nil) {
        self.enabled = true
        self.botToken = botToken
        self.allowedChatIds = allowedChatIds
    }
}

public struct DiscordConfig: Codable, Sendable {
    public var enabled: Bool
    public var botToken: String
    public var allowedChannelIds: [String]?

    public init(botToken: String, allowedChannelIds: [String]? = nil) {
        self.enabled = true
        self.botToken = botToken
        self.allowedChannelIds = allowedChannelIds
    }
}

public struct SlackConfig: Codable, Sendable {
    public var enabled: Bool
    public var appToken: String      // xapp-... (Socket Mode)
    public var botToken: String      // xoxb-... (Bot)
    public var allowedChannelIds: [String]?

    public init(appToken: String, botToken: String, allowedChannelIds: [String]? = nil) {
        self.enabled = true
        self.appToken = appToken
        self.botToken = botToken
        self.allowedChannelIds = allowedChannelIds
    }
}

public struct EmailConfig: Codable, Sendable {
    public var enabled: Bool
    public var imapServer: String    // e.g. imaps://imap.gmail.com
    public var smtpServer: String    // e.g. smtps://smtp.gmail.com:465
    public var email: String
    public var password: String      // app password

    public init(imapServer: String, smtpServer: String, email: String, password: String) {
        self.enabled = true
        self.imapServer = imapServer
        self.smtpServer = smtpServer
        self.email = email
        self.password = password
    }
}

public struct IMessageConfig: Codable, Sendable {
    public var enabled: Bool

    public init() {
        self.enabled = true
    }
}

public struct HomeAssistantConfig: Codable, Sendable {
    public var enabled: Bool
    public var baseURL: String       // e.g. http://homeassistant.local:8123
    public var token: String         // Long-lived access token

    public init(baseURL: String, token: String) {
        self.enabled = true
        self.baseURL = baseURL
        self.token = token
    }
}
