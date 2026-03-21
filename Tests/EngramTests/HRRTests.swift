import Foundation
import Testing
@testable import Engram

// MARK: - PRNG

@Test func mulberry32Deterministic() {
    var rng1 = Mulberry32(seed: 42)
    var rng2 = Mulberry32(seed: 42)
    for _ in 0..<100 { #expect(rng1.next() == rng2.next()) }
}

@Test func mulberry32Range() {
    var rng = Mulberry32(seed: 12345)
    for _ in 0..<1000 {
        let val = rng.next()
        #expect(val >= 0.0 && val < 1.0)
    }
}

@Test func mulberry32DifferentSeeds() {
    var rng1 = Mulberry32(seed: 1)
    var rng2 = Mulberry32(seed: 2)
    var same = 0
    for _ in 0..<100 { if rng1.next() == rng2.next() { same += 1 } }
    #expect(same < 5, "Different seeds should produce different sequences")
}

@Test func mulberry32SeedFromString() {
    let s1 = Mulberry32.seed(from: "hello")
    let s2 = Mulberry32.seed(from: "hello")
    let s3 = Mulberry32.seed(from: "world")
    #expect(s1 == s2)
    #expect(s1 != s3)
}

// MARK: - ComplexVector

@Test func vectorDeterminism() {
    let v1 = ComplexVector.random(for: "test_string", dimension: 256)
    let v2 = ComplexVector.random(for: "test_string", dimension: 256)
    #expect(v1.re == v2.re)
    #expect(v1.im == v2.im)
}

@Test func vectorDifferentStrings() {
    let v1 = ComplexVector.random(for: "alpha", dimension: 256)
    let v2 = ComplexVector.random(for: "beta", dimension: 256)
    #expect(v1.re != v2.re)
}

@Test func vectorDimension() {
    let v = ComplexVector(dimension: 128)
    #expect(v.dimension == 128)
    #expect(v.re.count == 128)
    #expect(v.im.count == 128)
}

@Test func vectorFromPhases() {
    let phases = [0.0, Double.pi / 2, Double.pi]
    let v = ComplexVector(phases: phases)
    #expect(v.dimension == 3)
    #expect(abs(v.re[0] - 1.0) < 1e-10) // cos(0) = 1
    #expect(abs(v.im[1] - 1.0) < 1e-10) // sin(pi/2) = 1
    #expect(abs(v.re[2] - (-1.0)) < 1e-10) // cos(pi) = -1
}

@Test func complexVectorBindUnbind() {
    let a = ComplexVector.random(for: "hello", dimension: 512)
    let b = ComplexVector.random(for: "world", dimension: 512)
    let bound = a.bind(with: b)
    let recovered = bound.unbind(with: a)
    let similarity = recovered.cosineSimilarity(with: b)
    #expect(similarity > 0.9, "Unbinding should recover the original vector")
}

@Test func complexVectorSuperposition() {
    let key1 = ComplexVector.random(for: "key:name", dimension: 512)
    let val1 = ComplexVector.random(for: "val:Alice", dimension: 512)
    let key2 = ComplexVector.random(for: "key:color", dimension: 512)
    let val2 = ComplexVector.random(for: "val:blue", dimension: 512)

    let memory = key1.bind(with: val1).add(key2.bind(with: val2))

    let decoded1 = memory.unbind(with: key1)
    #expect(decoded1.cosineSimilarity(with: val1) > decoded1.cosineSimilarity(with: val2))

    let decoded2 = memory.unbind(with: key2)
    #expect(decoded2.cosineSimilarity(with: val2) > decoded2.cosineSimilarity(with: val1))
}

@Test func vectorAdd() {
    let a = ComplexVector(re: [1, 2], im: [3, 4])
    let b = ComplexVector(re: [5, 6], im: [7, 8])
    let c = a.add(b)
    #expect(c.re == [6, 8])
    #expect(c.im == [10, 12])
}

@Test func vectorSubtract() {
    let a = ComplexVector(re: [5, 6], im: [7, 8])
    let b = ComplexVector(re: [1, 2], im: [3, 4])
    let c = a.subtract(b)
    #expect(c.re == [4, 4])
    #expect(c.im == [4, 4])
}

@Test func vectorScale() {
    let v = ComplexVector(re: [1, 2], im: [3, 4])
    let s = v.scale(by: 2)
    #expect(s.re == [2, 4])
    #expect(s.im == [6, 8])
}

@Test func vectorMagnitude() {
    let v = ComplexVector(re: [3, 0], im: [4, 0])
    #expect(abs(v.magnitude() - 5.0) < 1e-10)
}

@Test func vectorNormalized() {
    let v = ComplexVector.random(for: "test", dimension: 64)
    let n = v.normalized()
    #expect(abs(n.magnitude() - 1.0) < 1e-10)
}

@Test func vectorCosineSelfSimilarity() {
    let v = ComplexVector.random(for: "self", dimension: 256)
    let sim = v.cosineSimilarity(with: v)
    #expect(abs(sim - 1.0) < 1e-10)
}

@Test func vectorCosineOrthogonal() {
    let v1 = ComplexVector(re: [1, 0], im: [0, 0])
    let v2 = ComplexVector(re: [0, 1], im: [0, 0])
    let sim = v1.cosineSimilarity(with: v2)
    #expect(abs(sim) < 1e-10)
}

@Test func vectorSharpen() {
    let v = ComplexVector.random(for: "sharp", dimension: 64)
    let sharpened = v.sharpen(power: 2.0)
    #expect(sharpened.dimension == v.dimension)
    let identity = v.sharpen(power: 1.0)
    #expect(identity.re == v.re)
}

@Test func vectorUnitPhase() {
    let v = ComplexVector(re: [3, -1], im: [4, 2])
    let up = v.toUnitPhase()
    // Each element should have magnitude 1
    for i in 0..<up.dimension {
        let mag = sqrt(up.re[i] * up.re[i] + up.im[i] * up.im[i])
        #expect(abs(mag - 1.0) < 1e-10)
    }
}

// MARK: - Artifact

@Test func artifactRememberRecall() {
    let artifact = Artifact(name: "test", dimension: 512)
    artifact.remember(key: "favorite_color", value: "blue")
    artifact.remember(key: "name", value: "Evan")
    artifact.remember(key: "city", value: "Philadelphia")

    #expect(artifact.recall(query: "favorite_color").answer == "blue")
    #expect(artifact.recall(query: "name").answer == "Evan")
    #expect(artifact.recall(query: "city").answer == "Philadelphia")
}

@Test func artifactForget() {
    let artifact = Artifact(name: "test", dimension: 512)
    artifact.remember(key: "temp", value: "data")
    #expect(artifact.factCount == 1)
    artifact.forget(key: "temp")
    #expect(artifact.factCount == 0)
}

@Test func artifactForgetCaseInsensitive() {
    let artifact = Artifact(name: "test", dimension: 512)
    artifact.remember(key: "Name", value: "Evan")
    #expect(artifact.forget(key: "name"))
    #expect(artifact.factCount == 0)
}

@Test func artifactOverwrite() {
    let artifact = Artifact(name: "test", dimension: 512)
    artifact.remember(key: "color", value: "blue")
    artifact.remember(key: "color", value: "red")
    #expect(artifact.factCount == 1)
    #expect(artifact.recall(query: "color").answer == "red")
}

@Test func artifactHitTracking() {
    let artifact = Artifact(name: "test", dimension: 512)
    artifact.remember(key: "fact", value: "important")

    _ = artifact.recall(query: "fact", sessionId: "s1")
    #expect(artifact.facts[0].hits == 1)

    _ = artifact.recall(query: "fact", sessionId: "s1")
    #expect(artifact.facts[0].hits == 1, "Same session shouldn't double-count")

    _ = artifact.recall(query: "fact", sessionId: "s2")
    #expect(artifact.facts[0].hits == 2)
}

@Test func artifactPromotable() {
    let artifact = Artifact(name: "test", dimension: 512)
    artifact.remember(key: "fact", value: "data")

    _ = artifact.recall(query: "fact", sessionId: "s1")
    _ = artifact.recall(query: "fact", sessionId: "s2")
    #expect(artifact.promotableFacts.isEmpty)

    _ = artifact.recall(query: "fact", sessionId: "s3")
    #expect(artifact.promotableFacts.count == 1)
}

@Test func artifactEmptyRecall() {
    let artifact = Artifact(name: "empty", dimension: 512)
    let result = artifact.recall(query: "anything")
    #expect(!result.found)
    #expect(result.answer == nil)
}

@Test func artifactPersistence() throws {
    let artifact = Artifact(name: "persist_test", dimension: 256)
    artifact.remember(key: "a", value: "1")
    artifact.remember(key: "b", value: "2")

    let tempFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("test_artifact_\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tempFile) }

    try artifact.save(to: tempFile)
    let loaded = try Artifact.load(from: tempFile)

    #expect(loaded.name == "persist_test")
    #expect(loaded.factCount == 2)
    #expect(loaded.recall(query: "a").found)
    #expect(loaded.recall(query: "a").answer == "1")
}

@Test func manyFactsRecall() {
    let artifact = Artifact(name: "stress", dimension: 1024)
    let facts = [
        ("language", "Swift"), ("framework", "SwiftUI"), ("os", "macOS"),
        ("editor", "Xcode"), ("package_manager", "SPM"), ("testing", "Swift Testing"),
        ("database", "SQLite"), ("networking", "URLSession"), ("ui", "AppKit"),
        ("concurrency", "async/await"),
    ]
    for (k, v) in facts { artifact.remember(key: k, value: v) }

    var correct = 0
    for (k, v) in facts { if artifact.recall(query: k).answer == v { correct += 1 } }
    #expect(correct >= 8, "Should correctly recall at least 8/10 facts, got \(correct)")
}

// MARK: - Shelf

@Test func shelfCrossArtifactRecall() {
    let shelf = Shelf(
        saveDir: FileManager.default.temporaryDirectory
            .appendingPathComponent("test_shelf_\(UUID().uuidString)"),
        dimension: 512
    )

    shelf.remember(artifact: "people", key: "boss", value: "Leo")
    shelf.remember(artifact: "project", key: "deadline", value: "March 25th")

    let r1 = shelf.recall(query: "boss", artifact: "people")
    #expect(r1.result.found)
    #expect(r1.result.answer == "Leo")

    let r2 = shelf.recall(query: "deadline")
    #expect(r2.result.found)
    #expect(r2.artifactName == "project")
}

@Test func shelfStatus() {
    let shelf = Shelf(
        saveDir: FileManager.default.temporaryDirectory
            .appendingPathComponent("test_shelf_status_\(UUID().uuidString)"),
        dimension: 512
    )
    shelf.remember(artifact: "a", key: "k1", value: "v1")
    shelf.remember(artifact: "a", key: "k2", value: "v2")
    shelf.remember(artifact: "b", key: "k3", value: "v3")

    let statuses = shelf.status()
    #expect(statuses.count == 2)
    let totalFacts = statuses.reduce(0) { $0 + $1.factCount }
    #expect(totalFacts == 3)
}

@Test func shelfPersistence() {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("test_shelf_persist_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }

    let shelf1 = Shelf(saveDir: dir, dimension: 256)
    shelf1.remember(artifact: "test", key: "key", value: "value")
    shelf1.saveAll()

    let shelf2 = Shelf(saveDir: dir, dimension: 256)
    shelf2.loadAll()
    #expect(shelf2.artifactNames.contains("test"))
    let result = shelf2.recall(query: "key", artifact: "test")
    #expect(result.result.found)
}

@Test func shelfRemoveArtifact() {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("test_shelf_remove_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }

    let shelf = Shelf(saveDir: dir)
    shelf.remember(artifact: "temp", key: "k", value: "v")
    #expect(shelf.hasArtifact(named: "temp"))
    shelf.removeArtifact(named: "temp")
    #expect(!shelf.hasArtifact(named: "temp"))
}

@Test func shelfPromotedFacts() {
    let shelf = Shelf(
        saveDir: FileManager.default.temporaryDirectory
            .appendingPathComponent("test_shelf_promo_\(UUID().uuidString)"),
        dimension: 512
    )
    shelf.remember(artifact: "test", key: "fact", value: "data")

    _ = shelf.recall(query: "fact", artifact: "test", sessionId: "s1")
    _ = shelf.recall(query: "fact", artifact: "test", sessionId: "s2")
    _ = shelf.recall(query: "fact", artifact: "test", sessionId: "s3")

    let promoted = shelf.promotedFacts()
    #expect(promoted.count == 1)
    #expect(promoted[0].fact.value == "data")
}
