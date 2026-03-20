import Foundation
import SQLite3

/// FTS5 full-text search across all session history.
/// Indexes session JSONL files into an SQLite FTS5 virtual table.
public final class SessionSearch: @unchecked Sendable {
    private var db: OpaquePointer?
    private let dbPath: URL
    private let lock = NSLock()

    public init(sessionDir: URL) {
        self.dbPath = sessionDir.appendingPathComponent("search.db")
        openDB()
    }

    deinit {
        sqlite3_close(db)
    }

    private func openDB() {
        let path = dbPath.path
        guard sqlite3_open(path, &db) == SQLITE_OK else { return }

        // Create FTS5 table
        let sql = """
        CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
            session_file, role, content, timestamp
        );
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    /// Index all session files that haven't been indexed yet.
    public func indexSessions(in dir: URL) {
        lock.lock()
        defer { lock.unlock() }

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for file in files where file.pathExtension == "jsonl" {
            guard let data = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let filename = file.lastPathComponent

            // Check if already indexed
            var checkStmt: OpaquePointer?
            sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM messages_fts WHERE session_file = ?", -1, &checkStmt, nil)
            sqlite3_bind_text(checkStmt, 1, filename, -1, nil)
            if sqlite3_step(checkStmt) == SQLITE_ROW && sqlite3_column_int(checkStmt, 0) > 0 {
                sqlite3_finalize(checkStmt)
                continue
            }
            sqlite3_finalize(checkStmt)

            // Index each line
            for line in data.components(separatedBy: "\n") where !line.isEmpty {
                guard let lineData = line.data(using: .utf8),
                      let entry = try? decoder.decode(SessionEntry.self, from: lineData) else { continue }

                var stmt: OpaquePointer?
                sqlite3_prepare_v2(db,
                    "INSERT INTO messages_fts (session_file, role, content, timestamp) VALUES (?, ?, ?, ?)",
                    -1, &stmt, nil)
                sqlite3_bind_text(stmt, 1, filename, -1, nil)
                sqlite3_bind_text(stmt, 2, entry.role, -1, nil)
                sqlite3_bind_text(stmt, 3, entry.content, -1, nil)
                let ts = ISO8601DateFormatter().string(from: entry.timestamp)
                sqlite3_bind_text(stmt, 4, ts, -1, nil)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }

    /// Search across all sessions. Returns matching content with context.
    public func search(query: String, limit: Int = 20) -> [SearchResult] {
        lock.lock()
        defer { lock.unlock() }

        var results: [SearchResult] = []

        var stmt: OpaquePointer?
        let sql = """
        SELECT session_file, role, content, timestamp,
               highlight(messages_fts, 2, '**', '**') as highlighted
        FROM messages_fts
        WHERE messages_fts MATCH ?
        ORDER BY rank
        LIMIT ?
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, query, -1, nil)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        while sqlite3_step(stmt) == SQLITE_ROW {
            let sessionFile = String(cString: sqlite3_column_text(stmt, 0))
            let role = String(cString: sqlite3_column_text(stmt, 1))
            let content = String(cString: sqlite3_column_text(stmt, 2))
            let timestamp = String(cString: sqlite3_column_text(stmt, 3))
            let highlighted = String(cString: sqlite3_column_text(stmt, 4))

            results.append(SearchResult(
                sessionFile: sessionFile, role: role,
                content: content, timestamp: timestamp,
                highlighted: highlighted
            ))
        }
        sqlite3_finalize(stmt)
        return results
    }
}

public struct SearchResult: Sendable {
    public let sessionFile: String
    public let role: String
    public let content: String
    public let timestamp: String
    public let highlighted: String
}
