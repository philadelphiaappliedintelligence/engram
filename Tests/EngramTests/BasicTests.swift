import Testing
@testable import Engram

@Test func smokeTest() {
    let config = AgentConfig()
    #expect(config.model == "claude-opus-4-6")
}
