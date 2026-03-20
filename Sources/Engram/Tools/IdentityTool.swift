import Foundation

// MARK: - Identity Read Tool

public struct IdentityReadTool: Tool {
    private let store: EngramStore

    public init(store: EngramStore) { self.store = store }

    public var name: String { "identity_read" }
    public var description: String {
        "Read an identity document (soul, user, or bootstrap). Returns the current content."
    }
    public var inputSchema: [String: JSONValue] {
        Schema.object(properties: [
            "key": Schema.string(description: "Identity key: 'soul', 'user', or 'bootstrap'"),
        ], required: ["key"])
    }

    public func execute(input: [String: JSONValue]) async throws -> String {
        guard let key = input["key"]?.stringValue else {
            return "{\"error\": \"Missing required parameter: key\"}"
        }

        let validKeys = ["soul", "user", "bootstrap"]
        guard validKeys.contains(key) else {
            return "{\"error\": \"Invalid key. Use: soul, user, or bootstrap\"}"
        }

        if let content = await store.getIdentity(key) {
            return content
        }
        return "{\"found\": false, \"key\": \"\(key)\"}"
    }
}

// MARK: - Identity Edit Tool

public struct IdentityEditTool: Tool {
    private let store: EngramStore

    public init(store: EngramStore) { self.store = store }

    public var name: String { "identity_edit" }
    public var description: String {
        "Update an identity document (soul, user, or bootstrap). Replaces the entire content."
    }
    public var inputSchema: [String: JSONValue] {
        Schema.object(properties: [
            "key": Schema.string(description: "Identity key: 'soul', 'user', or 'bootstrap'"),
            "content": Schema.string(description: "New content for the identity document"),
        ], required: ["key", "content"])
    }

    public func execute(input: [String: JSONValue]) async throws -> String {
        guard let key = input["key"]?.stringValue,
              let content = input["content"]?.stringValue else {
            return "{\"error\": \"Missing required parameters: key, content\"}"
        }

        let validKeys = ["soul", "user", "bootstrap"]
        guard validKeys.contains(key) else {
            return "{\"error\": \"Invalid key. Use: soul, user, or bootstrap\"}"
        }

        await store.setIdentity(key, content: content)
        return "{\"updated\": true, \"key\": \"\(key)\"}"
    }
}
