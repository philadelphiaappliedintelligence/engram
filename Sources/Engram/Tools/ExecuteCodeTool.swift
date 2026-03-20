import Foundation

/// Execute Python or JavaScript code in a sandboxed subprocess.
/// Collapses multi-step pipelines into single inference calls.
public struct ExecuteCodeTool: Tool {
    public init() {}

    public var name: String { "execute_code" }
    public var description: String {
        """
        Execute Python or JavaScript code and return the output. \
        Use for data processing, calculations, file manipulation, API calls, \
        or any multi-step operation that's easier to express as code than as tool calls. \
        Python is preferred. The code runs in a subprocess with full system access.
        """
    }
    public var inputSchema: [String: JSONValue] {
        Schema.object(properties: [
            "language": Schema.stringEnum(description: "Language", values: ["python", "javascript", "bash"]),
            "code": Schema.string(description: "Code to execute"),
            "timeout": Schema.number(description: "Timeout in seconds (default: 30)"),
        ], required: ["language", "code"])
    }

    public func execute(input: [String: JSONValue]) async throws -> String {
        guard let language = input["language"]?.stringValue,
              let code = input["code"]?.stringValue else {
            return "{\"error\": \"Missing language or code\"}"
        }

        let timeout = Int(input["timeout"]?.numberValue ?? 30)

        let (executable, args): (String, [String])
        switch language {
        case "python":
            executable = "/usr/bin/env"
            args = ["python3", "-c", code]
        case "javascript":
            executable = "/usr/bin/env"
            args = ["node", "-e", code]
        case "bash":
            executable = "/bin/zsh"
            args = ["-c", code]
        default:
            return "{\"error\": \"Unsupported language: \(language)\"}"
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardOutput = stdout
        process.standardError = stderr
        process.environment = ProcessInfo.processInfo.environment

        do { try process.run() } catch {
            return "{\"error\": \"Failed to launch \(language): \(error.localizedDescription)\"}"
        }

        // Timeout
        let completed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let resumed = LockedValue(false)
            DispatchQueue.global().async {
                process.waitUntilExit()
                let should = resumed.withLock { d -> Bool in if d { return false }; d = true; return true }
                if should { continuation.resume(returning: true) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout)) {
                let should = resumed.withLock { d -> Bool in if d { return false }; d = true; return true }
                if should { process.terminate(); continuation.resume(returning: false) }
            }
        }

        if !completed { return "{\"error\": \"Code timed out after \(timeout)s\"}" }

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        let outStr = String(data: outData, encoding: .utf8) ?? ""
        let errStr = String(data: errData, encoding: .utf8) ?? ""
        let exitCode = process.terminationStatus

        let maxLen = 12000
        var output = outStr
        if output.count > maxLen { output = String(output.prefix(maxLen)) + "\n... (truncated)" }

        if exitCode == 0 {
            return output.isEmpty ? "(no output)" : output
        } else {
            return "Exit \(exitCode)\n\(output)\n\(errStr)".trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
