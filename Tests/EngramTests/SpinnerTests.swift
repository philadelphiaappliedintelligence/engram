import Foundation
import Testing
@testable import Engram

@Test func spinnerStartStop() async throws {
    let spinner = Spinner()
    spinner.start(message: "testing")
    try await Task.sleep(nanoseconds: 200_000_000) // 200ms
    spinner.stop()
    // Should not crash
}

@Test func spinnerUpdate() async throws {
    let spinner = Spinner()
    spinner.start(message: "phase1")
    try await Task.sleep(nanoseconds: 100_000_000)
    spinner.update("phase2")
    try await Task.sleep(nanoseconds: 100_000_000)
    spinner.stop()
}

@Test func spinnerDoubleStop() {
    let spinner = Spinner()
    spinner.start()
    spinner.stop()
    spinner.stop() // Should not crash
}

@Test func spinnerDoubleStart() {
    let spinner = Spinner()
    spinner.start(message: "first")
    spinner.start(message: "second") // Should not create two loops
    spinner.stop()
}
