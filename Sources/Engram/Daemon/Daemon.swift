import Foundation

/// Manages the Engram LaunchAgent — a macOS daemon that keeps Engram
/// running in the background, auto-restarting on crash.
///
/// Installs a plist at ~/Library/LaunchAgents/com.engram.agent.plist
/// that runs `engram daemon` and restarts it if it exits.
public enum Daemon {
    public static let label = "com.engram.agent"

    private static var plistURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    // MARK: - Install

    /// Install the LaunchAgent plist. Does NOT start it.
    public static func install(binaryPath: String? = nil) throws {
        let binary = binaryPath ?? findBinary()
        guard !binary.isEmpty else {
            throw DaemonError.binaryNotFound
        }

        let plist = buildPlist(binary: binary)

        let dir = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Uninstall

    public static func uninstall() throws {
        // Stop first if running
        try? stop()
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    // MARK: - Start / Stop / Status

    public static func start() throws {
        let result = shell("launchctl load \(plistURL.path)")
        if result.status != 0 && !result.output.contains("already loaded") {
            throw DaemonError.launchctlFailed(result.output)
        }
    }

    public static func stop() throws {
        let result = shell("launchctl unload \(plistURL.path)")
        if result.status != 0 && !result.output.contains("Could not find") {
            throw DaemonError.launchctlFailed(result.output)
        }
    }

    public static func restart() throws {
        try? stop()
        try start()
    }

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    public static var isRunning: Bool {
        let result = shell("launchctl list | grep \(label)")
        return result.status == 0 && !result.output.isEmpty
    }

    public static func status() -> DaemonStatus {
        if !isInstalled { return .notInstalled }
        if isRunning { return .running }
        return .stopped
    }

    // MARK: - Plist Generation

    private static func buildPlist(binary: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let logDir = "\(home)/.engram/logs"

        // Ensure log directory exists
        try? FileManager.default.createDirectory(
            atPath: logDir, withIntermediateDirectories: true
        )

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>

            <key>ProgramArguments</key>
            <array>
                <string>\(binary)</string>
                <string>daemon</string>
                <string>run</string>
            </array>

            <key>RunAtLoad</key>
            <true/>

            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
            </dict>

            <key>ThrottleInterval</key>
            <integer>5</integer>

            <key>StandardOutPath</key>
            <string>\(logDir)/daemon.log</string>

            <key>StandardErrorPath</key>
            <string>\(logDir)/daemon.err</string>

            <key>EnvironmentVariables</key>
            <dict>
                <key>HOME</key>
                <string>\(home)</string>
                <key>PATH</key>
                <string>/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin</string>
            </dict>

            <key>WorkingDirectory</key>
            <string>\(home)</string>

            <key>ProcessType</key>
            <string>Background</string>
        </dict>
        </plist>
        """
    }

    // MARK: - Binary Discovery

    private static func findBinary() -> String {
        // Check if we're running from a known location
        let candidates = [
            "/usr/local/bin/engram",
            "\(FileManager.default.homeDirectoryForCurrentUser.path)/.engram/bin/engram",
            ProcessInfo.processInfo.arguments.first ?? "",
        ]
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        // Try `which`
        let result = shell("which engram")
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.status == 0 && !path.isEmpty {
            return path
        }
        return ""
    }

    // MARK: - Shell Helper

    private static func shell(_ command: String) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

// MARK: - Types

public enum DaemonStatus: String, Sendable {
    case running = "running"
    case stopped = "stopped"
    case notInstalled = "not installed"
}

public enum DaemonError: Error, LocalizedError {
    case binaryNotFound
    case launchctlFailed(String)

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "Could not find the engram binary. Install it to /usr/local/bin or specify the path."
        case .launchctlFailed(let output):
            return "launchctl failed: \(output)"
        }
    }
}
