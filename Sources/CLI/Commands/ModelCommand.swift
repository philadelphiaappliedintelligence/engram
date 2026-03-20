import ArgumentParser
import Engram
import Foundation

struct ModelCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "model",
        abstract: "View and select the active model (fetches live from provider)"
    )

    @Flag(name: .long, help: "Use static catalog instead of live API")
    var offline = false

    func run() async throws {
        var config = AgentConfig.load()

        print("\(bold("Models"))\n")
        print("  Current: \(bold(config.model))")
        print("  Provider: \(config.resolvedProvider.rawValue)\n")

        let models: [DiscoveredModel]

        if offline {
            let catalog = ModelCatalog.currentModels(for: config.resolvedProvider)
            models = catalog.map { DiscoveredModel(id: $0.id, name: $0.name, provider: config.resolvedProvider.rawValue) }
        } else {
            print(dim("  Fetching models from API..."))
            let oauth = OAuthClient()
            let token = await oauth.resolveToken() ?? config.resolvedAPIKey()

            if let token {
                if config.resolvedProvider == .anthropic {
                    models = await ModelDiscovery.fetchAnthropic(
                        token: token, isOAuth: OAuthClient.isOAuthToken(token))
                } else if config.resolvedBaseURL.contains("127.0.0.1:11434") ||
                          config.resolvedBaseURL.contains("localhost:11434") {
                    models = await ModelDiscovery.fetchOllama()
                } else if config.resolvedBaseURL.contains("openrouter") {
                    models = await ModelDiscovery.fetchOpenRouter()
                } else {
                    models = await ModelDiscovery.fetchOpenAI(
                        baseURL: config.resolvedBaseURL, apiKey: token)
                }
            } else { models = [] }
        }

        if models.isEmpty {
            print("  No models found. Try `engram model --offline` for static catalog.")
            return
        }

        let display = Array(models.prefix(30))
        for (i, m) in display.enumerated() {
            let current = m.id == config.model ? " \(cyan("<--"))" : ""
            print("  \(i + 1). \(m.name)\(current)")
            print("     \(dim(m.id))")
        }
        if models.count > 30 { print(dim("  ... and \(models.count - 30) more")) }

        print("\nSelect model (1-\(display.count), or Enter to keep current):")
        print("> ", terminator: ""); fflush(stdout)

        guard let input = readLine()?.trimmingCharacters(in: .whitespaces),
              !input.isEmpty,
              let choice = Int(input), choice >= 1, choice <= display.count else { return }

        config.model = display[choice - 1].id
        try config.save()
        print("Model set to \(bold(display[choice - 1].name)) (\(display[choice - 1].id))")
    }
}
