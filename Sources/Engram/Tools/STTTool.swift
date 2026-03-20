import Foundation
import Speech

/// Speech-to-text transcription using macOS Speech framework.
/// Transcribes audio files locally (no API calls) using Apple's on-device recognizer.
public struct STTTool: Tool {
    public init() {}

    public var name: String { "transcribe_audio" }
    public var description: String {
        "Transcribe an audio file to text using on-device speech recognition. Supports mp3, m4a, wav, caf, aiff."
    }
    public var inputSchema: [String: JSONValue] {
        Schema.object(properties: [
            "path": Schema.string(description: "Absolute path to the audio file"),
            "locale": Schema.string(description: "Language locale (default: en-US)"),
        ], required: ["path"])
    }

    public func execute(input: [String: JSONValue]) async throws -> String {
        guard let path = input["path"]?.stringValue else {
            return "{\"error\": \"Missing required parameter: path\"}"
        }

        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)

        guard FileManager.default.fileExists(atPath: expanded) else {
            return "{\"error\": \"File not found: \(path)\"}"
        }

        let localeStr = input["locale"]?.stringValue ?? "en-US"

        // Check authorization
        let authStatus = SFSpeechRecognizer.authorizationStatus()
        if authStatus == .notDetermined {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { _ in
                    continuation.resume()
                }
            }
        }

        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            return "{\"error\": \"Speech recognition not authorized. Grant in System Settings > Privacy > Speech Recognition.\"}"
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeStr)) else {
            return "{\"error\": \"Speech recognizer not available for locale: \(localeStr)\"}"
        }

        guard recognizer.isAvailable else {
            return "{\"error\": \"Speech recognizer is not available\"}"
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false

        return await withCheckedContinuation { continuation in
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    continuation.resume(returning: "{\"error\": \"Transcription failed: \(error.localizedDescription)\"}")
                    return
                }
                guard let result, result.isFinal else { return }
                let text = result.bestTranscription.formattedString
                let escaped = text
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                continuation.resume(returning: "{\"transcription\": \"\(escaped)\"}")
            }
        }
    }
}
