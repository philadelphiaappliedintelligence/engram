import Foundation
import AVFoundation

/// Text-to-speech using macOS native AVSpeechSynthesizer.
/// No API keys, no network — runs entirely on-device.
public struct TTSTool: Tool {
    public init() {}

    public var name: String { "speak" }
    public var description: String {
        "Speak text aloud using macOS text-to-speech. Runs on-device, no API needed."
    }
    public var inputSchema: [String: JSONValue] {
        Schema.object(properties: [
            "text": Schema.string(description: "Text to speak aloud"),
            "rate": Schema.number(description: "Speech rate 0.0-1.0 (default: 0.5)"),
        ], required: ["text"])
    }

    public func execute(input: [String: JSONValue]) async throws -> String {
        guard let text = input["text"]?.stringValue else {
            return "{\"error\": \"Missing required parameter: text\"}"
        }

        let rate = Float(input["rate"]?.numberValue ?? 0.5)

        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = max(0, min(1, rate))
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")

        return await withCheckedContinuation { continuation in
            let delegate = SpeechDelegate {
                continuation.resume(returning: "{\"spoken\": true, \"chars\": \(text.count)}")
            }
            // Keep delegate alive
            objc_setAssociatedObject(synthesizer, "delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
            synthesizer.delegate = delegate
            synthesizer.speak(utterance)
        }
    }
}

private class SpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) { onFinish() }
}
