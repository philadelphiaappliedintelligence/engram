import ArgumentParser
import Engram
import Foundation

struct Login: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Authenticate with an LLM provider"
    )

    func run() async throws {
        let available = ProviderRegistry.availableProviders()

        print("\(bold("Login")) -- Choose a provider\n")
        for (i, entry) in available.enumerated() {
            let check = entry.hasAuth ? cyan(" [authenticated]") : ""
            print("  \(i + 1). \(entry.provider.name)\(check)")
            print("     \(dim(entry.provider.authType.rawValue))")
        }

        print("\nSelect provider (1-\(available.count)): ", terminator: ""); fflush(stdout)
        guard let input = readLine()?.trimmingCharacters(in: .whitespaces),
              let choice = Int(input), choice >= 1, choice <= available.count else {
            print("Cancelled."); return
        }

        let selected = available[choice - 1].provider
        var config = AgentConfig.load()

        switch selected.authType {
        case .oauth:
            if selected.id == "openai-codex" {
                let openai = OpenAIOAuth()
                let token = try await openai.login()
                config.provider = "codex"
                config.baseURL = selected.baseURL
                config.apiKey = token
                print("\nFetching available models...")
                var models = await ModelDiscovery.fetchCodex(token: token)
                if models.isEmpty {
                    models = [
                        DiscoveredModel(id: "gpt-4o", name: "GPT-4o", provider: "codex"),
                        DiscoveredModel(id: "o3", name: "o3", provider: "codex"),
                    ]
                }
                try config.save()
                try await selectModel(from: models, config: &config)
                return
            }

            let oauth = OAuthClient()
            let token = try await oauth.login()
            config.provider = "anthropic"
            config.baseURL = selected.baseURL
            config.apiKey = nil
            print("\nFetching available models...")
            var models = await ModelDiscovery.fetchAnthropic(token: token, isOAuth: true)
            if models.isEmpty {
                models = ModelCatalog.anthropic.map {
                    DiscoveredModel(id: $0.id, name: $0.name, provider: "anthropic")
                }
            }
            try config.save()
            try await selectModel(from: models, config: &config)

        case .apiKey:
            let envKey = selected.envVars.first.flatMap {
                ProcessInfo.processInfo.environment[$0]
            }
            if let envKey {
                print("\nFound key in env: \(String(envKey.prefix(12)))...")
                print("Use this key? (Y/n): ", terminator: "")
                let answer = readLine() ?? "y"
                if !answer.lowercased().hasPrefix("n") {
                    config.apiKey = envKey
                } else {
                    print("Enter API key: ", terminator: "")
                    config.apiKey = readLine()
                }
            } else {
                print("\nEnter API key for \(selected.name): ", terminator: "")
                config.apiKey = readLine()
            }

            guard let key = config.apiKey, !key.isEmpty else {
                print("No key provided."); return
            }

            config.provider = selected.llmProvider.rawValue
            config.baseURL = selected.baseURL

            let envFile = AgentConfig.configDir.appendingPathComponent(".env")
            let envVar = selected.envVars.first ?? "API_KEY"
            var envContent = (try? String(contentsOf: envFile, encoding: .utf8)) ?? ""
            envContent = envContent.components(separatedBy: "\n")
                .filter { !$0.hasPrefix(envVar + "=") }.joined(separator: "\n")
            envContent += "\n\(envVar)=\(key)\n"
            try envContent.write(to: envFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envFile.path)

            print("Fetching available models...")
            let models: [DiscoveredModel]
            if selected.id == "ollama" {
                models = await ModelDiscovery.fetchOllama()
            } else if selected.id == "openrouter" {
                models = await ModelDiscovery.fetchOpenRouter()
            } else {
                models = await ModelDiscovery.fetchOpenAI(baseURL: selected.baseURL, apiKey: key)
            }

            if !models.isEmpty {
                try config.save()
                try await selectModel(from: models, config: &config)
            } else {
                try config.save()
                print("Could not fetch models. Set manually with `engram model`.")
            }

        case .none:
            config.provider = selected.llmProvider.rawValue
            config.baseURL = selected.baseURL
            print("Checking for local models...")
            let models = await ModelDiscovery.fetchOllama()
            if models.isEmpty {
                print("No Ollama models found. Install with: ollama pull llama3.3")
            } else {
                try config.save()
                try await selectModel(from: models, config: &config)
            }
        }
    }
}
