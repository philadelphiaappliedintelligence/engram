import Foundation

/// Minimal lock wrapper for Sendable conformance.
public final class LockedValue<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()

    public init(_ value: T) {
        self.value = value
    }

    @discardableResult
    public func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

// MARK: - Shell Helpers

/// Shell-escape a string for safe use in sh/zsh commands.
public func shellEscape(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// MARK: - Process Timeout

/// Run a Process with a timeout. Returns true if completed, false if timed out (process killed).
public func runWithTimeout(_ process: Process, seconds: Int) async -> Bool {
    await withCheckedContinuation { continuation in
        let resumed = LockedValue(false)

        DispatchQueue.global().async {
            process.waitUntilExit()
            let shouldResume = resumed.withLock { done -> Bool in
                if done { return false }; done = true; return true
            }
            if shouldResume { continuation.resume(returning: true) }
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(seconds)) {
            let shouldResume = resumed.withLock { done -> Bool in
                if done { return false }; done = true; return true
            }
            if shouldResume {
                process.terminate()
                continuation.resume(returning: false)
            }
        }
    }
}

// MARK: - Tool Output Limits

public enum OutputLimit {
    public static let standard = 12_000
    public static let file = 16_000
    public static let terminal = 8_000
}
