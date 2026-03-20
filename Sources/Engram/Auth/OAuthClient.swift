import Foundation
import CryptoKit
import Security

// MARK: - OAuth Constants

enum OAuthConstants {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeURL = "https://claude.ai/oauth/authorize"
    static let tokenURL = "https://console.anthropic.com/v1/oauth/token"
    static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    static let scopes = "org:create_api_key user:profile user:inference"
}

// MARK: - Stored Credentials

public struct OAuthCredentials: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var scopes: String

    public var isExpired: Bool {
        Date() >= expiresAt.addingTimeInterval(-300) // 5 min buffer
    }
}

// MARK: - OAuth Client

/// Handles Claude Code-compatible OAuth: login, token exchange, refresh, and
/// reading existing Claude Code credentials from the macOS Keychain.
public final class OAuthClient: @unchecked Sendable {
    private let credFile: URL

    public init() {
        self.credFile = AgentConfig.configDir.appendingPathComponent("oauth.json")
    }

    // MARK: - Login Flow (OAuth Authorization Code + PKCE)

    /// Run the full interactive login flow.
    /// Returns the access token on success.
    public func login() async throws -> String {
        // 1. Generate PKCE pair
        let verifier = generateVerifier()
        let challenge = generateChallenge(from: verifier)

        // 2. Build authorization URL
        var components = URLComponents(string: OAuthConstants.authorizeURL)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: OAuthConstants.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: OAuthConstants.redirectURI),
            URLQueryItem(name: "scope", value: OAuthConstants.scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: verifier),
        ]

        let authURL = components.url!

        // 3. Open in browser
        print("Opening browser for authentication...")
        print("If it doesn't open, visit:\n\(authURL.absoluteString)\n")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [authURL.absoluteString]
        try? process.run()
        process.waitUntilExit()

        // 4. User pastes the authorization code
        print("After authorizing, paste the code from the browser (format: code#state):")
        print("> ", terminator: "")
        fflush(stdout)

        guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !input.isEmpty else {
            throw OAuthError.noCode
        }

        // Parse code#state format
        let code: String
        if input.contains("#") {
            code = String(input.split(separator: "#").first ?? "")
        } else {
            code = input
        }

        guard !code.isEmpty else {
            throw OAuthError.noCode
        }

        // 5. Exchange code for tokens
        let creds = try await exchangeCode(code: code, verifier: verifier)
        try saveCredentials(creds)

        print("Authenticated successfully.")
        return creds.accessToken
    }

    // MARK: - Token Exchange

    private func exchangeCode(code: String, verifier: String) async throws -> OAuthCredentials {
        let url = URL(string: OAuthConstants.tokenURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "grant_type": "authorization_code",
            "client_id": OAuthConstants.clientID,
            "code": code,
            "state": verifier,
            "redirect_uri": OAuthConstants.redirectURI,
            "code_verifier": verifier,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.tokenExchangeFailed(body)
        }

        return try parseTokenResponse(data)
    }

    // MARK: - Token Refresh

    public func refresh() async throws -> String {
        guard var creds = loadCredentials(), !creds.refreshToken.isEmpty else {
            throw OAuthError.noRefreshToken
        }

        let url = URL(string: OAuthConstants.tokenURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "client_id": OAuthConstants.clientID,
            "refresh_token": creds.refreshToken,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OAuthError.refreshFailed(body)
        }

        let newCreds = try parseTokenResponse(data)
        creds.accessToken = newCreds.accessToken
        creds.refreshToken = newCreds.refreshToken
        creds.expiresAt = newCreds.expiresAt
        try saveCredentials(creds)

        return creds.accessToken
    }

    // MARK: - Resolve Token

    /// Get a valid access token. Priority:
    /// 1. Engram's own stored OAuth token (auto-refresh if expired)
    /// 2. Claude Code's Keychain credentials
    /// 3. ANTHROPIC_API_KEY env var
    /// 4. ~/.engram/.env
    public func resolveToken() async -> String? {
        // 1. Our own OAuth credentials
        if let creds = loadCredentials() {
            if !creds.isExpired {
                return creds.accessToken
            }
            // Try refresh
            if let refreshed = try? await refresh() {
                return refreshed
            }
        }

        // 2. Claude Code Keychain — read token, refresh if expired
        if let keychainResult = readClaudeCodeKeychainFull() {
            if !keychainResult.isExpired {
                return keychainResult.accessToken
            }
            // Try to refresh using Claude Code's refresh token
            if !keychainResult.refreshToken.isEmpty,
               let refreshed = try? await refreshClaudeCodeToken(keychainResult.refreshToken) {
                return refreshed
            }
        }

        // 3. Env var
        if let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] {
            return key
        }

        return nil
    }

    /// Whether the resolved token is an OAuth token (needs Bearer auth + beta headers)
    public static func isOAuthToken(_ token: String) -> Bool {
        token.hasPrefix("sk-ant-oat")
    }

    // MARK: - Claude Code Keychain

    private struct KeychainCreds {
        let accessToken: String
        let refreshToken: String
        let isExpired: Bool
    }

    /// Read Claude Code's OAuth token + refresh token from macOS Keychain
    private func readClaudeCodeKeychainFull() -> KeychainCreds? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else { return nil }

        let refreshToken = oauth["refreshToken"] as? String ?? ""

        var isExpired = false
        if let expiresAt = oauth["expiresAt"] as? Double {
            let expiry = Date(timeIntervalSince1970: expiresAt / 1000)
            isExpired = Date() >= expiry.addingTimeInterval(-300)
        }

        return KeychainCreds(accessToken: token, refreshToken: refreshToken, isExpired: isExpired)
    }

    /// Refresh using Claude Code's refresh token and update the Keychain
    private func refreshClaudeCodeToken(_ refreshToken: String) async throws -> String {
        let url = URL(string: OAuthConstants.tokenURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "client_id": OAuthConstants.clientID,
            "refresh_token": refreshToken,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newToken = json["access_token"] as? String else {
            throw OAuthError.refreshFailed("Claude Code token refresh failed")
        }

        let newRefresh = json["refresh_token"] as? String ?? refreshToken
        let expiresIn = json["expires_in"] as? Double ?? 28800

        // Update the Keychain entry so Claude Code also gets the refreshed token
        updateClaudeCodeKeychain(accessToken: newToken, refreshToken: newRefresh, expiresIn: expiresIn)

        return newToken
    }

    /// Write refreshed token back to Claude Code's Keychain entry
    private func updateClaudeCodeKeychain(accessToken: String, refreshToken: String, expiresIn: Double) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var oauth = json["claudeAiOauth"] as? [String: Any] else { return }

        oauth["accessToken"] = accessToken
        oauth["refreshToken"] = refreshToken
        oauth["expiresAt"] = (Date().timeIntervalSince1970 + expiresIn) * 1000
        json["claudeAiOauth"] = oauth

        guard let updatedData = try? JSONSerialization.data(withJSONObject: json) else { return }

        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
        ]
        let updateAttrs: [String: Any] = [
            kSecValueData as String: updatedData,
        ]
        SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)
    }

    // MARK: - Credential Storage

    public func loadCredentials() -> OAuthCredentials? {
        guard let data = try? Data(contentsOf: credFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(OAuthCredentials.self, from: data)
    }

    private func saveCredentials(_ creds: OAuthCredentials) throws {
        try FileManager.default.createDirectory(
            at: credFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(creds)
        try data.write(to: credFile, options: .atomic)
        // Restrictive permissions
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: credFile.path)
    }

    // MARK: - Parse Token Response

    private func parseTokenResponse(_ data: Data) throws -> OAuthCredentials {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw OAuthError.invalidTokenResponse
        }

        let refreshToken = json["refresh_token"] as? String ?? ""
        let expiresIn = json["expires_in"] as? Double ?? 3600
        let expiresAt = Date().addingTimeInterval(expiresIn)

        return OAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            scopes: OAuthConstants.scopes
        )
    }

    // MARK: - PKCE

    private func generateVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    private func generateChallenge(from verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLEncoded()
    }
}

// MARK: - Base64URL

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Errors

public enum OAuthError: Error, LocalizedError {
    case noCode
    case tokenExchangeFailed(String)
    case refreshFailed(String)
    case noRefreshToken
    case invalidTokenResponse

    public var errorDescription: String? {
        switch self {
        case .noCode: return "No authorization code provided"
        case .tokenExchangeFailed(let msg): return "Token exchange failed: \(msg)"
        case .refreshFailed(let msg): return "Token refresh failed: \(msg)"
        case .noRefreshToken: return "No refresh token available. Run `engram login` to authenticate."
        case .invalidTokenResponse: return "Invalid token response from server"
        }
    }
}
