import Foundation

/// A messaging platform that can receive and send messages.
public protocol Platform: Sendable {
    var name: String { get }
    var isConnected: Bool { get }
    func start() async throws
    func stop() async
    func sendMessage(_ text: String, to chatId: String) async throws
    func sendFile(path: String, caption: String?, to chatId: String) async throws
    func sendTyping(to chatId: String) async throws
    /// Poll for new messages. Returns array of (chatId, senderName, messageText).
    func poll() async throws -> [(chatId: String, sender: String, text: String)]
}

/// Default implementations so platforms don't have to implement everything
extension Platform {
    public func sendFile(path: String, caption: String?, to chatId: String) async throws {
        let name = URL(fileURLWithPath: path).lastPathComponent
        try await sendMessage(caption ?? "File: \(name)", to: chatId)
    }
    public func sendTyping(to chatId: String) async throws {}
    public func reconnect() async throws { try await start() }
}
