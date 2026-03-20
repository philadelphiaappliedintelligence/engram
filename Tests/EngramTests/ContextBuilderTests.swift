import Foundation
import Testing
@testable import Engram

@Test func contextBuilderDefaultIdentity() {
    let shelf = Shelf(
        saveDir: FileManager.default.temporaryDirectory
            .appendingPathComponent("ctx_test_\(UUID().uuidString)")
    )
    let loader = SkillLoader(searchDirs: [])
    let block = ContextBuilder.buildContextBlock(shelf: shelf, skillLoader: loader)

    #expect(block.contains("Engram") || block.contains("persistent"))
    #expect(block.contains("Tool Guidelines"))
    #expect(block.contains("memory_remember"))
}

@Test func contextBuilderWithPlatform() {
    let shelf = Shelf(
        saveDir: FileManager.default.temporaryDirectory
            .appendingPathComponent("ctx_plat_\(UUID().uuidString)")
    )
    let loader = SkillLoader(searchDirs: [])
    let block = ContextBuilder.buildContextBlock(
        shelf: shelf, skillLoader: loader, platformHint: "telegram"
    )

    #expect(block.contains("telegram"))
    #expect(block.contains("send_message"))
}

@Test func contextBuilderWithMemory() {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ctx_mem_\(UUID().uuidString)")
    let shelf = Shelf(saveDir: dir)
    shelf.remember(nugget: "test", key: "fact", value: "data")

    // Recall 3 times to promote
    _ = shelf.recall(query: "fact", nugget: "test", sessionId: "s1")
    _ = shelf.recall(query: "fact", nugget: "test", sessionId: "s2")
    _ = shelf.recall(query: "fact", nugget: "test", sessionId: "s3")

    let loader = SkillLoader(searchDirs: [])
    let block = ContextBuilder.buildContextBlock(shelf: shelf, skillLoader: loader)

    #expect(block.contains("Permanent Memory"))
    #expect(block.contains("fact"))
    #expect(block.contains("data"))
}

@Test func contextBuilderWithSkills() {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ctx_skill_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let skillDir = tempDir.appendingPathComponent("review")
    try? FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
    try? """
    ---
    name: review
    description: Code review
    auto_load: true
    ---
    Review code carefully.
    """.write(to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

    let shelf = Shelf(
        saveDir: FileManager.default.temporaryDirectory
            .appendingPathComponent("ctx_skill_shelf_\(UUID().uuidString)")
    )
    let loader = SkillLoader(searchDirs: [tempDir])
    loader.loadAll()

    let block = ContextBuilder.buildContextBlock(shelf: shelf, skillLoader: loader)
    #expect(block.contains("Active Skills"))
    #expect(block.contains("Review code carefully"))
}
