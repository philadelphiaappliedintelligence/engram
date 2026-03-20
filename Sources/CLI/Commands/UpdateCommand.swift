import ArgumentParser
import Engram
import Foundation

struct UpdateCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Update engram to the latest version"
    )

    func run() async throws {
        let repo = "https://github.com/philadelphiaappliedintelligence/engram.git"
        let buildDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".engram-build").path
        let installPath = "/usr/local/bin/engram"

        print("Updating engram...\n")

        // Pull or clone
        if FileManager.default.fileExists(atPath: "\(buildDir)/.git") {
            print("  Pulling latest...")
            try run("git", ["-C", buildDir, "pull", "--ff-only", "--quiet"])
        } else {
            print("  Cloning...")
            try? FileManager.default.removeItem(atPath: buildDir)
            try run("git", ["clone", "--quiet", repo, buildDir])
        }

        // Get new version info
        let newHash = (try? output("git", ["-C", buildDir, "rev-parse", "--short", "HEAD"])) ?? "unknown"
        print("  Latest: \(newHash.trimmingCharacters(in: .whitespacesAndNewlines))")

        // Build
        print("  Building...")
        try run("swift", ["build", "-c", "release", "--quiet", "--package-path", buildDir])

        // Stop daemon if running
        let daemonWasRunning = Daemon.isRunning
        if daemonWasRunning {
            print("  Stopping daemon...")
            try? Daemon.stop()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        // Install
        print("  Installing...")
        let binPath = try output("swift", ["build", "-c", "release", "--show-bin-path", "--package-path", buildDir])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try run("sudo", ["cp", "\(binPath)/engram", installPath])
        try run("sudo", ["codesign", "-s", "-", "-f", installPath])

        // Build IMCore helper if SIP disabled
        let sipStatus = (try? output("csrutil", ["status"])) ?? ""
        if sipStatus.contains("disabled") {
            let helperScript = "\(buildDir)/scripts/build-helper.sh"
            if FileManager.default.fileExists(atPath: helperScript) {
                print("  Building iMessage helper...")
                try? run("sh", [helperScript])
                let engramDir = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".engram").path
                try? FileManager.default.createDirectory(atPath: engramDir, withIntermediateDirectories: true)
                try? FileManager.default.copyItem(
                    atPath: "\(buildDir)/.build/release/engram-imcore-helper.dylib",
                    toPath: "\(engramDir)/engram-imcore-helper.dylib"
                )
            }
        }

        // Restart daemon if it was running
        if daemonWasRunning {
            print("  Restarting daemon...")
            try? Daemon.install()
            try? Daemon.start()
        }

        print("\n  Updated to \(newHash.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    private func run(_ executable: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable.hasPrefix("/") ? executable : "/usr/bin/env")
        process.arguments = executable.hasPrefix("/") ? args : [executable] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.commandFailed("\(executable) \(args.joined(separator: " "))")
        }
    }

    private func output(_ executable: String, _ args: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable.hasPrefix("/") ? executable : "/usr/bin/env")
        process.arguments = executable.hasPrefix("/") ? args : [executable] + args
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.commandFailed("\(executable) \(args.joined(separator: " "))")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

enum UpdateError: Error, LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let cmd): return "Command failed: \(cmd)"
        }
    }
}
