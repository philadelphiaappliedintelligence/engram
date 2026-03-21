import Engram
import Foundation

// MARK: - Signal Handlers

func installSignalHandlers(shelf: Shelf) {
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            shelf.saveAll()
            print("\n\(TUI.dim)Memory saved. Goodbye.\(TUI.reset)")
            exit(0)
        }
        source.resume()
        _signalSources.append(source)
    }
}
var _signalSources: [any DispatchSourceSignal] = []

func isHousekeepingTool(_ name: String) -> Bool {
    name.hasPrefix("memory_")
}

// MARK: - ANSI (convenience wrappers around TUI)

func bold(_ s: String) -> String { "\(TUI.bold)\(s)\(TUI.reset)" }
func dim(_ s: String) -> String { "\(TUI.dim)\(s)\(TUI.reset)" }
func cyan(_ s: String) -> String { "\(TUI.cyan)\(s)\(TUI.reset)" }
func red(_ s: String) -> String { "\(TUI.red)\(s)\(TUI.reset)" }

func printBanner(config: AgentConfig, shelf: Shelf, toolCount: Int, skillCount: Int) {
    let statuses = shelf.status()
    TUI.banner(
        model: config.model,
        artifacts: statuses.count,
        facts: statuses.reduce(0) { $0 + $1.factCount },
        promoted: statuses.reduce(0) { $0 + $1.promotableCount },
        tools: toolCount,
        skills: skillCount,
        daemon: Daemon.status().rawValue
    )
}

/// Interactive model picker used by login and model commands
func selectModel(from models: [DiscoveredModel], config: inout AgentConfig) async throws {
    print("\n\(bold("Available models")) (\(models.count))\n")

    let display = Array(models.prefix(20))
    for (i, m) in display.enumerated() {
        let current = m.id == config.model ? " \(cyan("<--"))" : ""
        print("  \(i + 1). \(bold(m.name))\(current)")
        print("     \(dim(m.id))")
    }
    if models.count > 20 { print(dim("  ... and \(models.count - 20) more")) }

    print("\nSelect model (1-\(display.count), or Enter for current): ", terminator: "")
    fflush(stdout)
    guard let input = readLine()?.trimmingCharacters(in: .whitespaces),
          !input.isEmpty,
          let choice = Int(input), choice >= 1, choice <= display.count else { return }

    config.model = display[choice - 1].id
    try config.save()
    print("Model set to \(bold(display[choice - 1].name)) (\(display[choice - 1].id))")
}
