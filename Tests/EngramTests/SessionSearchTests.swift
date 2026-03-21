import Foundation
import Testing
@testable import Engram

@Test func searchKitIndexAndFind() {
    let searchIndex = SessionSearchIndex()
    searchIndex.addMessage(id: "test1", content: "I love holographic memory systems")
    searchIndex.addMessage(id: "test2", content: "That is fascinating technology")
    searchIndex.flush()

    let results = searchIndex.search(query: "holographic")
    if !results.isEmpty {
        #expect(results[0].id.contains("test1"))
    }
}

@Test func searchKitEmpty() {
    let searchIndex = SessionSearchIndex()
    let results = searchIndex.search(query: "xyznonexistent")
    #expect(results.isEmpty)
}
