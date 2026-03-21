import Foundation

// MARK: - Terminal Tool

public struct TerminalTool: Tool {
    public init() {}

    public var name: String { "terminal" }
    public var description: String {
        "Execute a shell command and return its output. Use for system operations, git, builds, etc. Supports setting the working directory."
    }
    public var inputSchema: [String: JSONValue] {
        Schema.object(properties: [
            "command": Schema.string(description: "The shell command to execute"),
            "cwd": Schema.string(description: "Working directory (default: current directory)"),
            "timeout": Schema.number(description: "Timeout in seconds (default: 30)"),
        ], required: ["command"])
    }

    public func execute(input: [String: JSONValue]) async throws -> String {
        guard let command = input["command"]?.stringValue else {
            return "{\"error\": \"Missing required parameter: command\"}"
        }

        let timeout = input["timeout"]?.numberValue ?? 30

        if isDangerous(command) {
            return "{\"error\": \"Blocked: this command looks destructive. Use the terminal directly if you're sure.\"}"
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.standardOutput = stdout
        process.standardError = stderr
        process.environment = ProcessInfo.processInfo.environment

        if let cwd = input["cwd"]?.stringValue {
            let expanded = (cwd as NSString).expandingTildeInPath
            process.currentDirectoryURL = URL(fileURLWithPath: expanded)
        }

        do {
            try process.run()
        } catch {
            return "{\"error\": \"Failed to launch: \(error.localizedDescription)\"}"
        }

        let timeoutSeconds = Int(timeout)
        let completed = await runWithTimeout(process, seconds: timeoutSeconds)

        if !completed {
            return "{\"error\": \"Command timed out after \(timeoutSeconds)s\"}"
        }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let outStr = String(data: outData, encoding: .utf8) ?? ""
        let errStr = String(data: errData, encoding: .utf8) ?? ""

        let exitCode = process.terminationStatus

        // Truncate long output
        let maxLen = OutputLimit.terminal
        let truncatedOut = outStr.count > maxLen
            ? String(outStr.prefix(maxLen)) + "\n... (truncated)"
            : outStr

        if exitCode == 0 {
            return truncatedOut.isEmpty ? "(no output)" : truncatedOut
        } else {
            let output = [truncatedOut, errStr].filter { !$0.isEmpty }.joined(separator: "\n")
            return "Exit code \(exitCode)\n\(output)"
        }
    }

    private func isDangerous(_ command: String) -> Bool {
        let patterns = [
            "rm -rf /", "rm -rf ~", "rm -rf /*",
            "mkfs", "dd if=/dev/zero", "dd if=/dev/random",
            ":(){:|:&};:", "shutdown", "reboot",
            "chmod -R 777 /", "chown -R",
        ]
        let lower = command.lowercased()
        return patterns.contains { lower.contains($0) }
    }
}
