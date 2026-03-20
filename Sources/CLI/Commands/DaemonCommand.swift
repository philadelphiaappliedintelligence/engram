import ArgumentParser
import Engram
import Foundation

struct DaemonCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon", abstract: "Manage the background daemon"
    )

    @Argument(help: "Action: install, uninstall, start, stop, restart, status, run")
    var action: String = "status"

    func run() async throws {
        switch action.lowercased() {
        case "install":
            try Daemon.install()
            print("LaunchAgent installed. Start with: engram daemon start")

        case "uninstall":
            try Daemon.uninstall()
            print("LaunchAgent removed.")

        case "start":
            if !Daemon.isInstalled { try Daemon.install(); print("LaunchAgent installed.") }
            try Daemon.start()
            print("Daemon started.")

        case "stop":
            try Daemon.stop()
            print("Daemon stopped.")

        case "restart":
            try Daemon.restart()
            print("Daemon restarted.")

        case "status":
            let status = Daemon.status()
            print("Daemon: \(status.rawValue)")
            if Daemon.isInstalled {
                let logFile = AgentConfig.configDir.appendingPathComponent("logs/daemon.log")
                if FileManager.default.fileExists(atPath: logFile.path) {
                    print("Log: \(logFile.path)")
                    let p = Process(); let pipe = Pipe()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
                    p.arguments = ["-5", logFile.path]
                    p.standardOutput = pipe
                    try? p.run(); p.waitUntilExit()
                    if let tail = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
                       !tail.isEmpty { print(dim(tail)) }
                }
            }

        case "run":
            let config = AgentConfig.load()
            let container = try EngramStore.makeContainer()
            let store = EngramStore(modelContainer: container)
            let daemon = DaemonLoop(config: config, store: store)
            await daemon.run()

        default:
            print("Unknown: \(action). Actions: install, uninstall, start, stop, restart, status, run")
        }
    }
}
