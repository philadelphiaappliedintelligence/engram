import Foundation
import CryptoKit

/// Shared OAuth utilities used by both Anthropic and OpenAI flows.
public enum OAuthFlow {

    // MARK: - PKCE

    public static func generateVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    public static func generateChallenge(from verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLEncoded()
    }

    // MARK: - Token Persistence

    public static func saveToken(_ creds: TokenCredentials, to file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(creds)
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    public static func loadToken(from file: URL) -> TokenCredentials? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(TokenCredentials.self, from: data)
    }

    // MARK: - Token Exchange

    public static func exchangeToken(
        url: String, body: [String: String],
        contentType: String = "application/json"
    ) async throws -> (accessToken: String, refreshToken: String, expiresIn: Double) {
        let reqURL = URL(string: url)!
        var request = URLRequest(url: reqURL)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")

        if contentType.contains("json") {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } else {
            request.httpBody = body.map { "\($0.key)=\($0.value)" }
                .joined(separator: "&").data(using: .utf8)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OAuthError.tokenExchangeFailed(String(data: data, encoding: .utf8) ?? "")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw OAuthError.invalidTokenResponse
        }

        return (
            accessToken: accessToken,
            refreshToken: json["refresh_token"] as? String ?? "",
            expiresIn: json["expires_in"] as? Double ?? 3600
        )
    }

    // MARK: - Refresh

    public static func refreshToken(
        url: String, clientId: String, refreshToken: String,
        contentType: String = "application/json"
    ) async throws -> (accessToken: String, refreshToken: String, expiresIn: Double) {
        let body = [
            "grant_type": "refresh_token",
            "client_id": clientId,
            "refresh_token": refreshToken,
        ]
        return try await exchangeToken(url: url, body: body, contentType: contentType)
    }
}

// MARK: - Shared Types

public struct TokenCredentials: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public var isExpired: Bool {
        Date() >= expiresAt.addingTimeInterval(-300)
    }

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}
