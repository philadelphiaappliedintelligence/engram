import Foundation

/// OpenAI Codex OAuth via device code flow.
/// Same flow used by Codex CLI and Hermes Agent.
public final class OpenAIOAuth {
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let deviceCodeURL = "https://auth.openai.com/api/accounts/deviceauth/usercode"
    private static let deviceTokenURL = "https://auth.openai.com/api/accounts/deviceauth/token"
    private static let tokenURL = "https://auth.openai.com/oauth/token"
    private static let callbackURI = "https://auth.openai.com/deviceauth/callback"
    private static let deviceAuthPage = "https://auth.openai.com/codex/device"

    private let credFile: URL
    private let keychain: KeychainStore

    public init() {
        self.credFile = AgentConfig.configDir.appendingPathComponent("openai_oauth.json")
        self.keychain = KeychainStore()
    }

    // MARK: - Device Code Login

    /// Run the interactive device code login flow.
    /// Returns the access token on success.
    public func login() async throws -> String {
        // Step 1: Request device code
        let (userCode, deviceAuthId, interval) = try await requestDeviceCode()

        print("\nOpen this URL in your browser:")
        print("  \(Self.deviceAuthPage)")
        print("\nEnter this code: \(userCode)\n")

        // Open browser
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [Self.deviceAuthPage]
        try? process.run()
        process.waitUntilExit()

        print("Waiting for authorization...")

        // Step 2: Poll for authorization
        let (authCode, codeVerifier) = try await pollForAuth(
            deviceAuthId: deviceAuthId, userCode: userCode,
            interval: interval, maxWait: 900  // 15 minutes
        )

        // Step 3: Exchange for tokens
        let creds = try await exchangeCode(code: authCode, codeVerifier: codeVerifier)
        try saveCredentials(creds)

        print("Authenticated with OpenAI successfully.")
        return creds.accessToken
    }

    // MARK: - Step 1: Request Device Code

    private func requestDeviceCode() async throws -> (userCode: String, deviceAuthId: String, interval: Int) {
        let url = URL(string: Self.deviceCodeURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": Self.clientID
        ])

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw OpenAIOAuthError.deviceCodeFailed(String(data: data, encoding: .utf8) ?? "")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userCode = json["user_code"] as? String,
              let deviceAuthId = json["device_auth_id"] as? String else {
            throw OpenAIOAuthError.invalidResponse
        }

        let interval = json["interval"] as? Int ?? 5
        return (userCode, deviceAuthId, interval)
    }

    // MARK: - Step 2: Poll for Authorization

    private func pollForAuth(deviceAuthId: String, userCode: String,
                             interval: Int, maxWait: Int) async throws -> (code: String, verifier: String) {
        let url = URL(string: Self.deviceTokenURL)!
        let pollInterval = max(interval, 2)
        let maxAttempts = maxWait / pollInterval

        for _ in 0..<maxAttempts {
            try await Task.sleep(nanoseconds: UInt64(pollInterval) * 1_000_000_000)

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "device_auth_id": deviceAuthId,
                "user_code": userCode,
            ])

            let (data, resp) = try await URLSession.shared.data(for: request)
            guard let http = resp as? HTTPURLResponse else { continue }

            if http.statusCode == 200 {
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let authCode = json["authorization_code"] as? String,
                      let codeVerifier = json["code_verifier"] as? String else {
                    throw OpenAIOAuthError.invalidResponse
                }
                return (authCode, codeVerifier)
            }

            // 403/404 = still pending, keep polling
            if http.statusCode == 403 || http.statusCode == 404 {
                continue
            }

            // Other error
            throw OpenAIOAuthError.pollFailed(http.statusCode)
        }

        throw OpenAIOAuthError.timeout
    }

    // MARK: - Step 3: Exchange Code for Tokens

    private func exchangeCode(code: String, codeVerifier: String) async throws -> OpenAICredentials {
        let url = URL(string: Self.tokenURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type=authorization_code",
            "code=\(code)",
            "redirect_uri=\(Self.callbackURI)",
            "client_id=\(Self.clientID)",
            "code_verifier=\(codeVerifier)",
        ].joined(separator: "&")

        request.httpBody = body.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw OpenAIOAuthError.tokenExchangeFailed(String(data: data, encoding: .utf8) ?? "")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw OpenAIOAuthError.invalidResponse
        }

        let refreshToken = json["refresh_token"] as? String ?? ""
        let expiresIn = json["expires_in"] as? Double ?? 3600

        return OpenAICredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
    }

    // MARK: - Token Refresh

    public func refresh() async throws -> String {
        guard let creds = loadCredentials(), !creds.refreshToken.isEmpty else {
            throw OpenAIOAuthError.noRefreshToken
        }

        let url = URL(string: Self.tokenURL)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type=refresh_token",
            "refresh_token=\(creds.refreshToken)",
            "client_id=\(Self.clientID)",
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: request)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newToken = json["access_token"] as? String else {
            throw OpenAIOAuthError.refreshFailed
        }

        let newRefresh = json["refresh_token"] as? String ?? creds.refreshToken
        let expiresIn = json["expires_in"] as? Double ?? 3600

        let newCreds = OpenAICredentials(
            accessToken: newToken, refreshToken: newRefresh,
            expiresAt: Date().addingTimeInterval(expiresIn)
        )
        try saveCredentials(newCreds)
        return newToken
    }

    // MARK: - Token Resolution

    public func resolveToken() async -> String? {
        if let creds = loadCredentials() {
            if !creds.isExpired { return creds.accessToken }
            if let refreshed = try? await refresh() { return refreshed }
        }
        return nil
    }

    // MARK: - Persistence (file + Keychain)

    public func loadCredentials() -> OpenAICredentials? {
        if let data = try? Data(contentsOf: credFile) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            if let creds = try? decoder.decode(OpenAICredentials.self, from: data) {
                return creds
            }
        }
        if let creds = keychain.getJSON(KeychainStore.openaiOAuth, as: OpenAICredentials.self) {
            try? saveToFile(creds)
            return creds
        }
        return nil
    }

    private func saveCredentials(_ creds: OpenAICredentials) throws {
        try saveToFile(creds)
        keychain.setJSON(KeychainStore.openaiOAuth, value: creds)
    }

    private func saveToFile(_ creds: OpenAICredentials) throws {
        try FileManager.default.createDirectory(
            at: credFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(creds)
        try data.write(to: credFile, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: credFile.path)
    }
}

// MARK: - Types

public struct OpenAICredentials: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public var isExpired: Bool {
        Date() >= expiresAt.addingTimeInterval(-300)
    }
}

public enum OpenAIOAuthError: Error, LocalizedError {
    case deviceCodeFailed(String)
    case invalidResponse
    case pollFailed(Int)
    case timeout
    case tokenExchangeFailed(String)
    case refreshFailed
    case noRefreshToken

    public var errorDescription: String? {
        switch self {
        case .deviceCodeFailed(let msg): return "Device code request failed: \(msg)"
        case .invalidResponse: return "Invalid response from OpenAI"
        case .pollFailed(let code): return "Poll failed with status \(code)"
        case .timeout: return "Authorization timed out (15 minutes)"
        case .tokenExchangeFailed(let msg): return "Token exchange failed: \(msg)"
        case .refreshFailed: return "Token refresh failed"
        case .noRefreshToken: return "No refresh token. Run `engram login` to authenticate."
        }
    }
}
