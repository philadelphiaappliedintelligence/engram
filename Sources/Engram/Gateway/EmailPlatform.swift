import Foundation

/// Email gateway using IMAP (receive) and SMTP (send) via subprocess.
/// Uses the system `curl` for IMAP polling and `/usr/sbin/sendmail` or `curl` for SMTP.
/// No external dependencies — these are built into macOS.
public actor EmailPlatform: Platform {
    public nonisolated var name: String { "email" }
    public nonisolated var isConnected: Bool { true }

    private let imapServer: String     // e.g. imaps://imap.gmail.com
    private let smtpServer: String     // e.g. smtps://smtp.gmail.com:465
    private let email: String
    private let password: String       // app password for Gmail
    private var lastUID: Int = 0

    public init(imapServer: String, smtpServer: String, email: String, password: String) {
        self.imapServer = imapServer
        self.smtpServer = smtpServer
        self.email = email
        self.password = password
    }

    public func start() async throws {
        // Test IMAP connection
        let result = shell(
            "curl -s --url '\(imapServer)' --user '\(email):\(password)' --request 'STATUS INBOX (MESSAGES)' 2>&1"
        )
        guard result.status == 0 else {
            throw GatewayError.connectionFailed("IMAP connection failed: \(result.output)")
        }
    }

    public func stop() async {}

    public func sendMessage(_ text: String, to recipient: String) async throws {
        // Build a minimal email
        let message = """
        From: \(email)
        To: \(recipient)
        Subject: From Engram
        Content-Type: text/plain; charset=utf-8

        \(text)
        """

        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram_email_\(UUID().uuidString).eml")
        try message.write(to: tempFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempFile) }

        let result = shell(
            "curl -s --url '\(smtpServer)' --user '\(email):\(password)' " +
            "--mail-from '\(email)' --mail-rcpt '\(recipient)' " +
            "--upload-file '\(tempFile.path)' 2>&1"
        )

        guard result.status == 0 else {
            throw GatewayError.sendFailed("SMTP send failed: \(result.output)")
        }
    }

    public func poll() async throws -> [(chatId: String, sender: String, text: String)] {
        // Fetch unseen messages via IMAP
        let result = shell(
            "curl -s --url '\(imapServer)/INBOX' --user '\(email):\(password)' " +
            "--request 'SEARCH UNSEEN' 2>&1"
        )

        guard result.status == 0 else { return [] }

        // Parse IMAP SEARCH response: "* SEARCH 1 2 3"
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.contains("SEARCH") else { return [] }

        let parts = output.components(separatedBy: "SEARCH ")
        guard parts.count > 1 else { return [] }

        let uids = parts[1].components(separatedBy: " ")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 > lastUID }

        var messages: [(chatId: String, sender: String, text: String)] = []

        for uid in uids.suffix(5) {  // Max 5 at a time
            let fetchResult = shell(
                "curl -s --url '\(imapServer)/INBOX;UID=\(uid)' " +
                "--user '\(email):\(password)' 2>&1"
            )

            if fetchResult.status == 0 {
                let (from, body) = parseEmail(fetchResult.output)
                if !body.isEmpty {
                    messages.append((chatId: from, sender: from, text: body))
                }
            }
            lastUID = max(lastUID, uid)
        }

        return messages
    }

    // MARK: - Helpers

    private func parseEmail(_ raw: String) -> (from: String, body: String) {
        var from = ""
        var inBody = false
        var body: [String] = []

        for line in raw.components(separatedBy: "\n") {
            if line.lowercased().hasPrefix("from:") {
                from = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                // Extract email from "Name <email@example.com>"
                if let start = from.firstIndex(of: "<"), let end = from.firstIndex(of: ">") {
                    from = String(from[from.index(after: start)..<end])
                }
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty && !inBody {
                inBody = true
                continue
            }
            if inBody { body.append(line) }
        }

        return (from, body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func shell(_ command: String) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
