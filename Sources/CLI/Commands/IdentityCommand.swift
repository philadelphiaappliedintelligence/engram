import ArgumentParser
import Engram
import Foundation

struct IdentityCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "identity",
        abstract: "View or edit identity documents (soul, user, bootstrap)"
    )

    @Argument(help: "Identity to edit: soul, user, or bootstrap (omit to list all)")
    var key: String?

    @Flag(name: .long, help: "Print content instead of opening editor")
    var show = false

    func run() async throws {
        let container = try EngramStore.makeContainer()
        let store = EngramStore(modelContainer: container)

        if let key {
            let validKeys = ["soul", "user", "bootstrap"]
            guard validKeys.contains(key) else {
                print("Invalid key '\(key)'. Use: soul, user, or bootstrap")
                throw ExitCode.failure
            }

            let current = await store.getIdentity(key) ?? defaultIdentity(for: key)

            // Just print if --show
            if show {
                print(current)
                return
            }

            // Write to temp file and open in editor
            let tmpFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("engram_\(key).md")
            try current.write(to: tmpFile, atomically: true, encoding: .utf8)

            let editor = ProcessInfo.processInfo.environment["EDITOR"]
                ?? ProcessInfo.processInfo.environment["VISUAL"]
                ?? "vi"
            let path = tmpFile.path

            // Run editor synchronously on a real thread (async context kills child TTY processes)
            let exitCode: Int32 = await withCheckedContinuation { continuation in
                DispatchQueue.global().sync {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                    process.arguments = ["-i", "-c", "\(editor) \(path)"]
                    process.standardInput = FileHandle.standardInput
                    process.standardOutput = FileHandle.standardOutput
                    process.standardError = FileHandle.standardError
                    do {
                        try process.run()
                        process.waitUntilExit()
                        continuation.resume(returning: process.terminationStatus)
                    } catch {
                        continuation.resume(returning: 1)
                    }
                }
            }

            guard exitCode == 0 else {
                print("Editor exited with error")
                throw ExitCode.failure
            }

            let newContent = try String(contentsOf: tmpFile, encoding: .utf8)
            await store.setIdentity(key, content: newContent)
            try? FileManager.default.removeItem(at: tmpFile)

            print("Updated \(key) identity.")
        } else {
            // List all identities
            let identities = await store.allIdentities()
            if identities.isEmpty {
                print("No identities stored. Run 'engram identity soul' to create one.")
                return
            }
            for id in identities {
                let preview = id.content.prefix(60).replacingOccurrences(of: "\n", with: " ")
                let formatter = DateFormatter()
                formatter.dateStyle = .short
                formatter.timeStyle = .short
                print("\(id.key): \(preview)... (updated \(formatter.string(from: id.updatedAt)))")
            }
        }
    }

    private func defaultIdentity(for key: String) -> String {
        switch key {
        case "soul":
            return "Your name is Engram. Be direct, helpful, no filler."
        case "user":
            return ""
        case "bootstrap":
            return "Ask the user their name and what to call you."
        default:
            return ""
        }
    }
}
