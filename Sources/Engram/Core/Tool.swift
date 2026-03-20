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
        do {
            return try await tool.execute(input: input)
        } catch {
            return "{\"error\": \"\(error.localizedDescription)\"}"
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
