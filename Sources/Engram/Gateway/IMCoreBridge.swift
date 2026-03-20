import Foundation

// MARK: - Tapback Types

public enum TapbackType: Int, Sendable {
    case love = 2000
    case thumbsUp = 2001
    case thumbsDown = 2002
    case haha = 2003
    case emphasis = 2004
    case question = 2005
    case removeLove = 3000
    case removeThumbsUp = 3001
    case removeThumbsDown = 3002
    case removeHaha = 3003
    case removeEmphasis = 3004
    case removeQuestion = 3005

    public var displayName: String {
        switch self {
        case .love, .removeLove: return "love"
        case .thumbsUp, .removeThumbsUp: return "thumbsup"
        case .thumbsDown, .removeThumbsDown: return "thumbsdown"
        case .haha, .removeHaha: return "haha"
        case .emphasis, .removeEmphasis: return "emphasis"
        case .question, .removeQuestion: return "question"
        }
    }

    public static func from(string: String, remove: Bool = false) -> TapbackType? {
        let offset = remove ? 1000 : 0
        switch string.lowercased() {
        case "love", "heart": return TapbackType(rawValue: 2000 + offset)
        case "thumbsup", "like": return TapbackType(rawValue: 2001 + offset)
        case "thumbsdown", "dislike": return TapbackType(rawValue: 2002 + offset)
        case "haha", "laugh": return TapbackType(rawValue: 2003 + offset)
        case "emphasis", "exclaim", "!!": return TapbackType(rawValue: 2004 + offset)
        case "question", "?": return TapbackType(rawValue: 2005 + offset)
        default: return nil
        }
    }
}

// MARK: - SIP Check

public enum SIPStatus: Sendable {
    case enabled
    case disabled
    case unknown
}

public func checkSIPStatus() -> SIPStatus {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/csrutil")
    process.arguments = ["status"]
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return .unknown }
        if output.contains("disabled") { return .disabled }
        if output.contains("enabled") { return .enabled }
        return .unknown
    } catch {
        return .unknown
    }
}

// MARK: - IMCore Bridge (file-based IPC with injected dylib)

public final class IMCoreBridge: @unchecked Sendable {
    private let containerPath: String
    private let commandFile: String
    private let responseFile: String
    private let lockFile: String
    private let dylibSearchPaths: [String]
    private let lock = NSLock()

    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.containerPath = "\(home)/Library/Containers/com.apple.MobileSMS/Data"
        self.commandFile = "\(containerPath)/.engram-imcore-command.json"
        self.responseFile = "\(containerPath)/.engram-imcore-response.json"
        self.lockFile = "\(containerPath)/.engram-imcore-ready"

        let engramDir = AgentConfig.configDir.path
        self.dylibSearchPaths = [
            "\(engramDir)/engram-imcore-helper.dylib",
            "\(home)/bin/engram-imcore-helper.dylib",
            "/usr/local/lib/engram-imcore-helper.dylib",
            "\(home)/engram/.build/release/engram-imcore-helper.dylib",
        ]
    }

    // MARK: - Availability

    public var dylibPath: String? {
        dylibSearchPaths.first { FileManager.default.fileExists(atPath: $0) }
    }

    public var isAvailable: Bool { dylibPath != nil }

    public var isInjectedAndReady: Bool {
        guard FileManager.default.fileExists(atPath: lockFile) else { return false }
        guard let response = try? sendCommandSync(action: "ping", params: [:]) else { return false }
        return response["success"] as? Bool == true
    }

    // MARK: - Launch Messages.app with Injection

    public func ensureRunning() throws {
        if isInjectedAndReady { return }
        guard let dylib = dylibPath else {
            throw IMCoreError.dylibNotFound
        }

        killMessages()
        Thread.sleep(forTimeInterval: 1.0)

        // Clean old IPC files
        try? FileManager.default.removeItem(atPath: commandFile)
        try? FileManager.default.removeItem(atPath: responseFile)
        try? FileManager.default.removeItem(atPath: lockFile)

        // Launch with injection
        let messagesPath = "/System/Applications/Messages.app/Contents/MacOS/Messages"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: messagesPath)
        var env = ProcessInfo.processInfo.environment
        env["DYLD_INSERT_LIBRARIES"] = dylib
        task.environment = env
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()

        // Wait for ready
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: lockFile) {
                Thread.sleep(forTimeInterval: 0.5)
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw IMCoreError.timeout
    }

    public func killMessages() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["Messages"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }

    // MARK: - Commands

    public func setTyping(for handle: String, typing: Bool) async throws {
        _ = try await sendCommand(action: "typing", params: ["handle": handle, "typing": typing])
    }

    public func markAsRead(handle: String) async throws {
        _ = try await sendCommand(action: "read", params: ["handle": handle])
    }

    public func sendTapback(to handle: String, messageGUID: String, type: TapbackType) async throws {
        _ = try await sendCommand(action: "react", params: [
            "handle": handle, "guid": messageGUID, "type": type.rawValue
        ])
    }

    public func status() async throws -> [String: Any] {
        try await sendCommand(action: "status", params: [:])
    }

    // MARK: - IPC

    private func sendCommand(action: String, params: [String: Any]) async throws -> [String: Any] {
        try ensureRunning()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    let response = try self.sendCommandSync(action: action, params: params)
                    if response["success"] as? Bool == true {
                        continuation.resume(returning: response)
                    } else {
                        let error = response["error"] as? String ?? "Unknown error"
                        continuation.resume(throwing: IMCoreError.operationFailed(error))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func sendCommandSync(action: String, params: [String: Any]) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }

        let command: [String: Any] = [
            "id": Int(Date().timeIntervalSince1970 * 1000),
            "action": action,
            "params": params,
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: command)
        try jsonData.write(to: URL(fileURLWithPath: commandFile))

        // Poll for response
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)

            guard let responseData = try? Data(contentsOf: URL(fileURLWithPath: responseFile)),
                  responseData.count > 2 else { continue }

            if let cmdData = try? Data(contentsOf: URL(fileURLWithPath: commandFile)),
               cmdData.count <= 2 {
                guard let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                    throw IMCoreError.invalidResponse
                }
                try? "".write(toFile: responseFile, atomically: true, encoding: .utf8)
                return response
            }
        }
        throw IMCoreError.timeout
    }
}

// MARK: - Errors

public enum IMCoreError: Error, LocalizedError {
    case dylibNotFound
    case timeout
    case invalidResponse
    case operationFailed(String)
    case sipRequired

    public var errorDescription: String? {
        switch self {
        case .dylibNotFound: return "engram-imcore-helper.dylib not found. Run: scripts/build-helper.sh"
        case .timeout: return "Timeout waiting for Messages.app IMCore bridge"
        case .invalidResponse: return "Invalid response from IMCore bridge"
        case .operationFailed(let msg): return "IMCore: \(msg)"
        case .sipRequired: return "SIP must be disabled for iMessage advanced features"
        }
    }
}
