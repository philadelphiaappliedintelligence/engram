import Foundation

/// MCP (Model Context Protocol) client — connects to external tool servers
/// via JSON-RPC 2.0 over stdin/stdout. This is the plugin system.
///
/// Config in ~/.engram/config.json:
/// ```json
/// {
///   "mcpServers": {
///     "filesystem": {
///       "command": "npx",
///       "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
///     }
///   }
/// }
/// ```
public final class MCPClient: @unchecked Sendable {
    private let name: String
    private let command: String
    private let args: [String]
    private let env: [String: String]
    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var requestId = 0
    private let lock = NSLock()

    public init(name: String, command: String, args: [String] = [], env: [String: String] = [:]) {
        self.name = name
        self.command = command
        self.args = args
        self.env = env
    }

    deinit { stop() }

    // MARK: - Lifecycle

    public func start() throws {
        let proc = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()

        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = [command] + args
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = FileHandle.nullDevice

        var procEnv = ProcessInfo.processInfo.environment
        for (k, v) in env { procEnv[k] = v }
        proc.environment = procEnv

        try proc.run()

        self.process = proc
        self.stdin = stdinPipe.fileHandleForWriting
        self.stdout = stdoutPipe.fileHandleForReading

        // Initialize
        let initResult = try sendRequest(method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "engram", "version": "1.0"] as [String: Any],
        ] as [String: Any])

        guard initResult != nil else {
            throw MCPError.initFailed("No response to initialize")
        }

        // Send initialized notification
        sendNotification(method: "notifications/initialized")
    }

    public func stop() {
        process?.terminate()
        process = nil
        stdin = nil
        stdout = nil
    }

    public var isRunning: Bool {
        process?.isRunning ?? false
    }

    // MARK: - Tool Discovery

    /// List all tools provided by this MCP server.
    public func listTools() throws -> [MCPToolInfo] {
        guard let result = try sendRequest(method: "tools/list", params: [:] as [String: Any]) else {
            return []
        }
        guard let tools = result["tools"] as? [[String: Any]] else { return [] }

        return tools.compactMap { tool in
            guard let name = tool["name"] as? String,
                  let description = tool["description"] as? String else { return nil }
            let schema = tool["inputSchema"] as? [String: Any] ?? [:]
            return MCPToolInfo(name: name, description: description, inputSchema: schema)
        }
    }

    // MARK: - Tool Execution

    /// Call a tool on this MCP server.
    public func callTool(name: String, arguments: [String: Any]) throws -> String {
        let result = try sendRequest(method: "tools/call", params: [
            "name": name,
            "arguments": arguments,
        ] as [String: Any])

        guard let content = result?["content"] as? [[String: Any]] else {
            return result.map { "\($0)" } ?? "{\"error\": \"No result\"}"
        }

        // Extract text content
        return content.compactMap { block -> String? in
            if block["type"] as? String == "text" { return block["text"] as? String }
            return nil
        }.joined(separator: "\n")
    }

    // MARK: - JSON-RPC

    private func nextId() -> Int {
        lock.lock(); defer { lock.unlock() }
        requestId += 1
        return requestId
    }

    private func sendRequest(method: String, params: [String: Any]) throws -> [String: Any]? {
        let id = nextId()
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: request),
              var line = String(data: data, encoding: .utf8) else {
            throw MCPError.serializationFailed
        }

        line += "\n"
        guard let lineData = line.data(using: .utf8) else {
            throw MCPError.serializationFailed
        }

        stdin?.write(lineData)

        // Read response line
        guard let response = readLine() else {
            throw MCPError.noResponse
        }

        guard let responseData = response.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw MCPError.invalidResponse(response)
        }

        if let error = json["error"] as? [String: Any] {
            let msg = error["message"] as? String ?? "Unknown error"
            throw MCPError.serverError(msg)
        }

        return json["result"] as? [String: Any]
    }

    private func sendNotification(method: String) {
        let notification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: notification),
           var line = String(data: data, encoding: .utf8) {
            line += "\n"
            if let lineData = line.data(using: .utf8) {
                stdin?.write(lineData)
            }
        }
    }

    private func readLine() -> String? {
        guard let stdout else { return nil }

        var buffer = Data()
        while true {
            let byte = stdout.readData(ofLength: 1)
            if byte.isEmpty { return nil }
            if byte[0] == UInt8(ascii: "\n") { break }
            buffer.append(byte)
        }
        return String(data: buffer, encoding: .utf8)
    }
}

// MARK: - MCP Tool Wrapper

/// Wraps an MCP server tool as an Engram Tool for the registry.
public struct MCPToolWrapper: Tool {
    private let client: MCPClient
    private let toolInfo: MCPToolInfo

    public init(client: MCPClient, toolInfo: MCPToolInfo) {
        self.client = client
        self.toolInfo = toolInfo
    }

    public var name: String { "mcp_\(toolInfo.name)" }
    public var description: String { toolInfo.description }
    public var inputSchema: [String: JSONValue] {
        // Convert the raw schema dict to JSONValue
        jsonDictToJSONValue(toolInfo.inputSchema)
    }

    public func execute(input: [String: JSONValue]) async throws -> String {
        var args: [String: Any] = [:]
        for (k, v) in input { args[k] = jsonValueToAnyPublic(v) }
        do {
            return try client.callTool(name: toolInfo.name, arguments: args)
        } catch {
            return "{\"error\": \"\(error.localizedDescription)\"}"
        }
    }
}

// MARK: - MCP Manager

/// Manages multiple MCP server connections.
public final class MCPManager: @unchecked Sendable {
    private var clients: [String: MCPClient] = [:]

    public init() {}

    /// Start MCP servers from config and return discovered tools.
    public func startServers(from config: [String: MCPServerConfig]) -> [any Tool] {
        var tools: [any Tool] = []

        for (name, serverConfig) in config {
            let client = MCPClient(
                name: name,
                command: serverConfig.command,
                args: serverConfig.args,
                env: serverConfig.env
            )

            do {
                try client.start()
                clients[name] = client

                let serverTools = try client.listTools()
                for toolInfo in serverTools {
                    tools.append(MCPToolWrapper(client: client, toolInfo: toolInfo))
                }
            } catch {
                // Log but don't crash — MCP server might not be available
                print("MCP server '\(name)' failed to start: \(error.localizedDescription)")
            }
        }

        return tools
    }

    public func stopAll() {
        for (_, client) in clients { client.stop() }
        clients.removeAll()
    }

    public var serverNames: [String] { Array(clients.keys).sorted() }
    public var serverCount: Int { clients.count }
}

// MARK: - Types

public struct MCPToolInfo: @unchecked Sendable {
    public let name: String
    public let description: String
    public let inputSchema: [String: Any]

    public init(name: String, description: String, inputSchema: [String: Any]) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public struct MCPServerConfig: Codable, Sendable {
    public let command: String
    public let args: [String]
    public let env: [String: String]

    public init(command: String, args: [String] = [], env: [String: String] = [:]) {
        self.command = command
        self.args = args
        self.env = env
    }
}

public enum MCPError: Error, LocalizedError {
    case initFailed(String)
    case serializationFailed
    case noResponse
    case invalidResponse(String)
    case serverError(String)

    public var errorDescription: String? {
        switch self {
        case .initFailed(let msg): return "MCP init failed: \(msg)"
        case .serializationFailed: return "Failed to serialize JSON-RPC"
        case .noResponse: return "No response from MCP server"
        case .invalidResponse(let r): return "Invalid response: \(String(r.prefix(100)))"
        case .serverError(let msg): return "MCP error: \(msg)"
        }
    }
}

// MARK: - Helpers

private func jsonDictToJSONValue(_ dict: [String: Any]) -> [String: JSONValue] {
    var result: [String: JSONValue] = [:]
    for (k, v) in dict {
        result[k] = anyToJSONValue(v)
    }
    return result
}

private func anyToJSONValue(_ value: Any) -> JSONValue {
    if let s = value as? String { return .string(s) }
    if let n = value as? Double { return .number(n) }
    if let n = value as? Int { return .number(Double(n)) }
    if let b = value as? Bool { return .bool(b) }
    if let a = value as? [Any] { return .array(a.map { anyToJSONValue($0) }) }
    if let d = value as? [String: Any] { return .object(jsonDictToJSONValue(d)) }
    return .null
}

func jsonValueToAnyPublic(_ value: JSONValue) -> Any {
    switch value {
    case .string(let s): return s
    case .number(let n): return n
    case .bool(let b): return b
    case .null: return NSNull()
    case .array(let a): return a.map { jsonValueToAnyPublic($0) }
    case .object(let o): return o.mapValues { jsonValueToAnyPublic($0) }
    }
}
