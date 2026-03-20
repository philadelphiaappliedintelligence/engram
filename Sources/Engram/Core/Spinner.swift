import Foundation

/// Animated terminal spinner with live-updating message.
public final class Spinner: @unchecked Sendable {
    private let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private var task: Task<Void, Never>?
    private var isSpinning = false
    private var message = "thinking"
    private let lock = NSLock()

    public init() {}

    public func start(message: String = "thinking") {
        lock.lock()
        self.message = message
        guard !isSpinning else { lock.unlock(); return }
        isSpinning = true
        lock.unlock()

        task = Task.detached { [weak self] in
            guard let self else { return }
            var i = 0
            while true {
                let (spinning, msg) = self.lock.withLock {
                    (self.isSpinning, self.message)
                }
                guard spinning else { break }

                let frame = self.frames[i % self.frames.count]
                FileHandle.standardError.write(
                    "\r\u{001B}[K\u{001B}[2m\(frame) \(msg)\u{001B}[0m".data(using: .utf8)!
                )
                i += 1
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
        }
    }

    /// Update the spinner message without stopping/restarting.
    public func update(_ message: String) {
        lock.withLock { self.message = message }
    }

    public func stop() {
        lock.lock()
        guard isSpinning else { lock.unlock(); return }
        isSpinning = false
        lock.unlock()

        task?.cancel()
        task = nil

        FileHandle.standardError.write("\r\u{001B}[K".data(using: .utf8)!)
    }
}
