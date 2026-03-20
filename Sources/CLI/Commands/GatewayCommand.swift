import ArgumentParser
import Engram
import Foundation

struct GatewayCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gateway",
        abstract: "Configure messaging platforms (Telegram, Discord, Slack, Email, iMessage)"
    )

    @Argument(help: "Platform: telegram, discord, slack, email, imessage, status")
    var platform: String = "status"

    func run() async throws {
        var config = AgentConfig.load()
        if config.gateway == nil { config.gateway = GatewayConfig() }

        switch platform.lowercased() {
        case "status":
            let enabled = (config.gateway ?? GatewayConfig()).enabledPlatforms
            if enabled.isEmpty {
                print("No gateway platforms configured.")
                print("Setup: engram gateway <platform>")
                print("Platforms: telegram, discord, slack, email, imessage")
            } else {
                print("\(bold("Gateway")) -- \(enabled.count) platforms\n")
                for p in enabled { print("  \(cyan("●")) \(p)") }
                print("\nStart with: engram daemon start")
            }

        case "telegram":
            print("\(bold("Telegram Setup"))\n")
            print("1. Message @BotFather on Telegram")
            print("2. Send /newbot and follow the prompts")
            print("3. Copy the bot token\n")
            print("Bot token: ", terminator: ""); fflush(stdout)
            guard let token = readLine(), !token.isEmpty else { print("Cancelled."); return }

            let verifyURL = URL(string: "https://api.telegram.org/bot\(token)/getMe")!
            if let (data, resp) = try? await URLSession.shared.data(for: URLRequest(url: verifyURL)),
               let http = resp as? HTTPURLResponse, http.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let result = json["result"] as? [String: Any],
               let botName = result["username"] as? String {
                print("  Bot verified: @\(botName)")
            } else { print(red("  Invalid token.")); return }

            print("\n\(bold("Pairing")) -- Send any message to your bot on Telegram...")
            print(dim("  Waiting for a message (timeout: 60s)..."))

            var pairedChatId: String?
            var pairedName: String?
            let pairURL = URL(string: "https://api.telegram.org/bot\(token)/getUpdates?timeout=30&allowed_updates=[\"message\"]")!

            for attempt in 0..<2 {
                if let (data, resp) = try? await URLSession.shared.data(for: URLRequest(url: pairURL)),
                   let http = resp as? HTTPURLResponse, http.statusCode == 200,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let results = json["result"] as? [[String: Any]] {
                    for update in results.reversed() {
                        if let msg = update["message"] as? [String: Any],
                           let chat = msg["chat"] as? [String: Any],
                           let chatId = chat["id"] as? Int {
                            pairedChatId = "\(chatId)"
                            pairedName = chat["title"] as? String ??
                                (msg["from"] as? [String: Any])?["first_name"] as? String ?? ""
                            break
                        }
                    }
                    if pairedChatId != nil { break }
                }
                if attempt == 0 { print(dim("  Still waiting...")) }
            }

            if let chatId = pairedChatId {
                print("  Paired with: \(pairedName ?? "unknown") (chat ID: \(chatId))")
                print("\nAllow only this chat? (Y/n): ", terminator: ""); fflush(stdout)
                let answer = readLine() ?? "y"
                let chatIds: [String]? = answer.lowercased().hasPrefix("n") ? nil : [chatId]
                config.gateway?.telegram = TelegramConfig(botToken: token, allowedChatIds: chatIds)
                try config.save()

                let confirmURL = URL(string: "https://api.telegram.org/bot\(token)/sendMessage")!
                var confirmReq = URLRequest(url: confirmURL)
                confirmReq.httpMethod = "POST"
                confirmReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                confirmReq.httpBody = try? JSONSerialization.data(withJSONObject: [
                    "chat_id": chatId, "text": "Engram connected."
                ])
                _ = try? await URLSession.shared.data(for: confirmReq)
                print("\nTelegram configured. Start daemon: engram daemon start")
            } else {
                config.gateway?.telegram = TelegramConfig(botToken: token)
                try config.save()
                print("\nTelegram configured (open). Start daemon: engram daemon start")
            }

        case "discord":
            print("\(bold("Discord Setup"))\n")
            print("1. discord.com/developers/applications → Create app → Bot → copy token")
            print("2. Enable MESSAGE CONTENT intent")
            print("3. Invite bot to server\n")
            print("Bot token: ", terminator: ""); fflush(stdout)
            guard let token = readLine(), !token.isEmpty else { return }
            print("Allowed channel IDs (comma-separated, or Enter for all): ", terminator: ""); fflush(stdout)
            let chans = (readLine() ?? "").isEmpty ? nil :
                readLine()?.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            config.gateway?.discord = DiscordConfig(botToken: token, allowedChannelIds: chans)
            try config.save()
            print("\nDiscord configured. Start daemon: engram daemon start")

        case "slack":
            print("\(bold("Slack Setup"))\n")
            print("App token (xapp-...): ", terminator: ""); fflush(stdout)
            guard let appToken = readLine(), !appToken.isEmpty else { return }
            print("Bot token (xoxb-...): ", terminator: ""); fflush(stdout)
            guard let botToken = readLine(), !botToken.isEmpty else { return }
            config.gateway?.slack = SlackConfig(appToken: appToken, botToken: botToken)
            try config.save()
            print("\nSlack configured. Start daemon: engram daemon start")

        case "email":
            print("\(bold("Email Setup"))\n")
            print("IMAP server: ", terminator: ""); fflush(stdout)
            guard let imap = readLine(), !imap.isEmpty else { return }
            print("SMTP server: ", terminator: ""); fflush(stdout)
            guard let smtp = readLine(), !smtp.isEmpty else { return }
            print("Email: ", terminator: ""); fflush(stdout)
            guard let email = readLine(), !email.isEmpty else { return }
            print("Password: ", terminator: ""); fflush(stdout)
            guard let pass = readLine(), !pass.isEmpty else { return }
            config.gateway?.email = EmailConfig(imapServer: imap, smtpServer: smtp, email: email, password: pass)
            try config.save()
            print("\nEmail configured. Start daemon: engram daemon start")

        case "imessage":
            print("\(bold("iMessage Setup")) -- no tokens needed.\n")
            print("Requirements: Messages.app signed in + Full Disk Access\n")
            config.gateway?.imessage = IMessageConfig()
            try config.save()
            print("iMessage enabled. Start daemon: engram daemon start")

        default:
            print("Unknown: \(platform). Available: telegram, discord, slack, email, imessage, status")
        }
    }
}
