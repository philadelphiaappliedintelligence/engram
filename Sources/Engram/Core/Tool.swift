import Foundation

// MARK: - Tool Protocol

/// A tool the agent can invoke. Implementations are compiled in — no runtime discovery.
public protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    var inputSchema: [String: JSONValue] { get }
    func execute(input: [String: JSONValue]) async throws -> String
}

// MARK: - Tool Registry

/// Central dispatch for all tools. Tools are registered at startup, never at runtime.
public final class ToolRegistry: @unchecked Sendable {
    private var tools: [String: any Tool] = [:]

    /// Tools that require user approval before execution.
    /// Set to nil to disable approvals (e.g. in daemon/gateway mode).
    public var approvalHandler: (@Sendable (String, String) async -> Bool)?

    /// Tool names that require approval. Empty = no approvals.
    public static let requiresApproval: Set<String> = [
        "terminal", "file_write", "edit", "execute_code",
    ]

    public init() {}

    public func register(_ tool: any Tool) {
        tools[tool.name] = tool
    }

    public func register(_ toolList: [any Tool]) {
        for tool in toolList { register(tool) }
    }

    public func get(_ name: String) -> (any Tool)? {
        tools[name]
    }

    public func dispatch(name: String, input: [String: JSONValue]) async throws -> String {
        guard let tool = tools[name] else {
            return "{\"error\": \"Unknown tool: \(name)\"}"
        }

        // Approval check for dangerous tools
        if let handler = approvalHandler, Self.requiresApproval.contains(name) {
            let preview = formatApprovalPreview(name: name, input: input)
            let approved = await handler(name, preview)
            if !approved {
                return "{\"denied\": true, \"tool\": \"\(name)\", \"reason\": \"User denied execution\"}"
            }
        }

        do {
            return try await tool.execute(input: input)
        } catch {
            return "{\"error\": \"\(error.localizedDescription)\"}"
        }
    }

    private func formatApprovalPreview(name: String, input: [String: JSONValue]) -> String {
        switch name {
        case "terminal":
            return input["command"]?.stringValue ?? "(unknown command)"
        case "execute_code":
            let lang = input["language"]?.stringValue ?? "code"
            let code = input["code"]?.stringValue ?? ""
            return "[\(lang)] \(String(code.prefix(200)))"
        case "file_write":
            return input["path"]?.stringValue ?? "(unknown path)"
        case "edit":
            return input["file_path"]?.stringValue ?? "(unknown path)"
        default:
            return name
        }
    }

    /// Tool definitions formatted for the Anthropic API
    public var definitions: [ToolDefinition] {
        tools.values.map { tool in
            ToolDefinition(
                name: tool.name,
                description: tool.description,
                inputSchema: tool.inputSchema
            )
        }.sorted { $0.name < $1.name }
    }

    public var count: Int { tools.count }
    public var names: [String] { tools.keys.sorted() }
    public var all: [any Tool] { Array(tools.values) }
}

// MARK: - Schema Helpers

/// Convenience for building JSON Schema input definitions
public enum Schema {
    public static func object(
        properties: [String: JSONValue],
        required: [String] = []
    ) -> [String: JSONValue] {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        return schema
    }

    public static func string(description: String) -> JSONValue {
        .object([
            "type": .string("string"),
            "description": .string(description),
        ])
    }

    public static func number(description: String) -> JSONValue {
        .object([
            "type": .string("number"),
            "description": .string(description),
        ])
    }

    public static func boolean(description: String) -> JSONValue {
        .object([
            "type": .string("boolean"),
            "description": .string(description),
        ])
    }

    public static func stringEnum(description: String, values: [String]) -> JSONValue {
        .object([
            "type": .string("string"),
            "description": .string(description),
            "enum": .array(values.map { .string($0) }),
        ])
    }
}
