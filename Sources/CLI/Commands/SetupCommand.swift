import ArgumentParser
import Engram
import Foundation

struct Setup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Configure Engram (API key, model). Use `engram login` for OAuth instead."
    )

    func run() async throws {
        var config = AgentConfig.load()
        print("\(bold("Engram Setup"))\n")

        let oauth = OAuthClient()
        if let token = await oauth.resolveToken() {
            let source = OAuthClient.isOAuthToken(token) ? "OAuth" : "API key"
            print("Auth: \(source) (\(String(token.prefix(12)))...)")
        } else {
            print("Auth: not configured")
            print("  Use `engram login` for OAuth (Claude Pro/Max/Team)")
            print("  Or enter an API key below\n")
        }

        let masked = config.resolvedAPIKey().map { String($0.prefix(8)) + "..." } ?? "(not set)"
        print("API key: \(masked)")
        print("Enter API key (or Enter to skip):")
        print("> ", terminator: "")
        if let key = readLine(), !key.isEmpty { config.apiKey = key }

        print("\nModel: \(config.model)")
        print("Enter model (or Enter to skip). Use `engram model` for full list.")
        print("> ", terminator: "")
        if let m = readLine(), !m.isEmpty { config.model = m }

        try config.save()
        print("\nSaved to \(AgentConfig.configFile.path)")

        if let key = config.apiKey {
            let envFile = AgentConfig.configDir.appendingPathComponent(".env")
            try "ANTHROPIC_API_KEY=\(key)\n".write(to: envFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envFile.path)
            print("API key saved to \(envFile.path)")
        }
    }
}

struct Memory: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "View holographic memory")

    func run() async throws {
        let config = AgentConfig.load()
        let container = try EngramStore.makeContainer()
        let store = EngramStore(modelContainer: container)
        let shelf = Shelf(saveDir: config.memoryURL, store: store)
        shelf.loadAll()
        // Give async store load a moment to complete
        try? await Task.sleep(nanoseconds: 100_000_000)
        let statuses = shelf.status()
        if statuses.isEmpty { print("Memory is empty."); return }

        var totalFacts = 0, totalPromoted = 0
        for s in statuses {
            totalFacts += s.factCount; totalPromoted += s.promotableCount
            print("\n\(bold(s.name)) (\(s.factCount) facts, \(s.promotableCount) promoted)")
            for fact in s.topFacts {
                print("  \(fact.key): \(fact.value) [\(fact.hits) hits]\(fact.hits >= 3 ? " *" : "")")
            }
        }
        print("\nTotal: \(totalFacts) facts, \(statuses.count) nuggets (\(totalPromoted) promoted)")
    }
}

struct Sessions: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List saved sessions")

    func run() async throws {
        let config = AgentConfig.load()
        let container = try EngramStore.makeContainer()
        let store = EngramStore(modelContainer: container)
        let sessions = await SessionManager(sessionDir: config.sessionURL, store: store).listSessions()
        if sessions.isEmpty { print("No saved sessions."); return }
        print("\(bold("Sessions")) (\(sessions.count))\n")
        for (i, s) in sessions.enumerated() {
            print("  \(i + 1). \(dim(s.filename)) -- \(s.messageCount) msgs -- \(s.preview.isEmpty ? "(empty)" : String(s.preview.prefix(60)))")
        }
        print("\nResume latest: engram chat -r")
    }
}
