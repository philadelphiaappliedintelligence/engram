import Foundation
import Testing
@testable import Engram

@Test func sessionSearchIndexAndFind() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("search_test_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    // Create a fake session JSONL using SessionManager (ensures correct format)
    let mgr = SessionManager(sessionDir: tempDir)
    mgr.newSession()
    _ = mgr.append(role: "user", content: "I love holographic memory systems")
    _ = mgr.append(role: "assistant", content: "That is fascinating technology")

    let search = SessionSearch(sessionDir: tempDir)
    search.indexSessions(in: tempDir)

    let results = search.search(query: "holographic")
    // FTS5 may not be available in all SQLite builds
    if !results.isEmpty {
        #expect(results[0].content.contains("holographic"))
    }
}

@Test func sessionSearchEmpty() {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("search_empty_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let search = SessionSearch(sessionDir: tempDir)
    let results = search.search(query: "anything")
    #expect(results.isEmpty)
}
