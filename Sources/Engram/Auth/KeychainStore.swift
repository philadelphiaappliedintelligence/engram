import Foundation
import Security

/// Keychain-backed credential storage using Security.framework.
/// Replaces plain JSON files for OAuth tokens and API keys.
public struct KeychainStore: Sendable {
    private let service: String

    public init(service: String = "com.engram.credentials") {
        self.service = service
    }

    // MARK: - CRUD

    /// Store a credential in the Keychain.
    @discardableResult
    public func set(_ key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Delete existing first (upsert pattern)
        delete(key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    /// Store a Codable value as JSON in the Keychain.
    @discardableResult
    public func setJSON<T: Encodable>(_ key: String, value: T) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(value) else { return false }
        guard let json = String(data: data, encoding: .utf8) else { return false }
        return set(key, value: json)
    }

    /// Retrieve a credential from the Keychain.
    public func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Retrieve and decode a JSON credential.
    public func getJSON<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard let json = get(key), let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }

    /// Delete a credential from the Keychain.
    @discardableResult
    public func delete(_ key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Check if a credential exists.
    public func has(_ key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: false,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}

// MARK: - Well-Known Keys

extension KeychainStore {
    public static let anthropicOAuth = "anthropic_oauth"
    public static let openaiOAuth = "openai_oauth"
    public static let anthropicAPIKey = "anthropic_api_key"
}
