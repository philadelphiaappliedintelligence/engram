import Foundation

/// Native Safari browser control via AppleScript + screencapture.
/// The agent can see what's on screen via vision, read DOM content,
/// and interact via JavaScript injection. Zero dependencies.
public struct BrowserTool: Tool {
    private let client: LLMClient

    public init(client: LLMClient) {
        self.client = client
    }

    public var name: String { "browser" }
    public var description: String {
        """
        Control Safari browser. Actions: open (navigate to URL), read (get page text), \
        screenshot (capture and analyze what's on screen), click (click element by CSS selector), \
        type (type text into element), js (execute JavaScript), tabs (list open tabs), \
        scroll (scroll the page). Use screenshot to SEE what's on the page before acting.
        """
    }
    public var inputSchema: [String: JSONValue] {
        Schema.object(properties: [
            "action": Schema.stringEnum(
                description: "What to do",
                values: ["open", "read", "screenshot", "click", "type", "js", "tabs", "scroll"]
            ),
            "url": Schema.string(description: "URL to open (for 'open' action)"),
            "selector": Schema.string(description: "CSS selector for click/type actions"),
            "text": Schema.string(description: "Text to type (for 'type' action)"),
            "code": Schema.string(description: "JavaScript to execute (for 'js' action)"),
            "direction": Schema.string(description: "Scroll direction: up or down (default: down)"),
            "question": Schema.string(description: "What to look for in the screenshot (for 'screenshot' action)"),
        ], required: ["action"])
    }

    public func execute(input: [String: JSONValue]) async throws -> String {
        guard let action = input["action"]?.stringValue else {
            return "{\"error\": \"Missing required parameter: action\"}"
        }

        switch action {
        case "open":
            return await openURL(input["url"]?.stringValue ?? "about:blank")
        case "read":
            return await readPage()
        case "screenshot":
            return await screenshot(question: input["question"]?.stringValue)
        case "click":
            guard let selector = input["selector"]?.stringValue else {
                return "{\"error\": \"Missing selector for click\"}"
            }
            return await click(selector: selector)
        case "type":
            guard let selector = input["selector"]?.stringValue,
                  let text = input["text"]?.stringValue else {
                return "{\"error\": \"Missing selector or text for type\"}"
            }
            return await typeText(selector: selector, text: text)
        case "js":
            guard let code = input["code"]?.stringValue else {
                return "{\"error\": \"Missing code for js\"}"
            }
            return await executeJS(code)
        case "tabs":
            return await listTabs()
        case "scroll":
            let direction = input["direction"]?.stringValue ?? "down"
            return await scroll(direction: direction)
        default:
            return "{\"error\": \"Unknown action: \(action)\"}"
        }
    }

    // MARK: - Actions

    private func openURL(_ urlStr: String) async -> String {
        let script = """
        tell application "Safari"
            activate
            if (count of windows) = 0 then
                make new document with properties {URL:"\(escapeAS(urlStr))"}
            else
                set URL of current tab of front window to "\(escapeAS(urlStr))"
            end if
        end tell
        """
        let result = runAppleScript(script)
        if result.status != 0 {
            return "{\"error\": \"Failed to open URL: \(result.output)\"}"
        }
        // Wait for page to load
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        return "{\"opened\": \"\(urlStr)\"}"
    }

    private func readPage() async -> String {
        // Get page text content via JavaScript
        let script = """
        tell application "Safari"
            set pageText to do JavaScript "document.body.innerText" in current tab of front window
            return pageText
        end tell
        """
        let result = runAppleScript(script)
        if result.status != 0 {
            return "{\"error\": \"Failed to read page: \(result.output)\"}"
        }

        var text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)

        // Also get the URL and title
        let titleScript = """
        tell application "Safari"
            set pageTitle to name of current tab of front window
            set pageURL to URL of current tab of front window
            return pageTitle & "\\n" & pageURL
        end tell
        """
        let titleResult = runAppleScript(titleScript)
        var header = ""
        if titleResult.status == 0 {
            let parts = titleResult.output.components(separatedBy: "\n")
            if parts.count >= 2 {
                header = "Title: \(parts[0].trimmingCharacters(in: .whitespaces))\nURL: \(parts[1].trimmingCharacters(in: .whitespaces))\n\n"
            }
        }

        // Truncate long pages
        if text.count > 12000 {
            text = String(text.prefix(12000)) + "\n... (truncated)"
        }

        return header + text
    }

    private func screenshot(question: String?) async -> String {
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("engram_browser_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        // Capture the front Safari window
        // -l flag captures a specific window; we use -w for the front window
        let captureResult = shell("screencapture -x -o -l $(osascript -e 'tell application \"Safari\" to id of front window') \(tmpFile.path) 2>&1")

        // Fallback: capture front window without window ID
        if captureResult.status != 0 || !FileManager.default.fileExists(atPath: tmpFile.path) {
            let fallback = shell("screencapture -x -w \(tmpFile.path) 2>&1")
            if fallback.status != 0 || !FileManager.default.fileExists(atPath: tmpFile.path) {
                return "{\"error\": \"Screenshot failed. Is Safari open?\"}"
            }
        }

        // Read and send to vision
        guard let imageData = try? Data(contentsOf: tmpFile) else {
            return "{\"error\": \"Failed to read screenshot\"}"
        }

        let base64 = imageData.base64EncodedString()
        let prompt = question ?? "Describe what you see on this browser page. Note any buttons, forms, text content, errors, or important UI elements."

        do {
            let analysis = try await client.analyzeImage(
                base64: base64, mediaType: "image/png", prompt: prompt
            )
            return analysis
        } catch {
            // Fallback to reading the DOM text
            return await readPage()
        }
    }

    private func click(selector: String) async -> String {
        let js = "document.querySelector('\(escapeJS(selector))').click(); 'clicked'"
        return await executeJS(js)
    }

    private func typeText(selector: String, text: String) async -> String {
        let js = """
        (function() {
            var el = document.querySelector('\(escapeJS(selector))');
            if (!el) return 'Element not found: \(escapeJS(selector))';
            el.focus();
            el.value = '\(escapeJS(text))';
            el.dispatchEvent(new Event('input', {bubbles: true}));
            el.dispatchEvent(new Event('change', {bubbles: true}));
            return 'typed';
        })()
        """
        return await executeJS(js)
    }

    private func scroll(direction: String) async -> String {
        let pixels = direction == "up" ? -500 : 500
        let js = "window.scrollBy(0, \(pixels)); 'scrolled \(direction)'"
        return await executeJS(js)
    }

    private func executeJS(_ code: String) async -> String {
        let escaped = code.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Safari"
            set result to do JavaScript "\(escaped)" in current tab of front window
            return result
        end tell
        """
        let result = runAppleScript(script)
        if result.status != 0 {
            return "{\"error\": \"JS failed: \(result.output)\"}"
        }
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? "(no output)" : output
    }

    private func listTabs() async -> String {
        let script = """
        tell application "Safari"
            set tabList to ""
            repeat with w in windows
                repeat with t in tabs of w
                    set tabList to tabList & name of t & "\\n" & URL of t & "\\n---\\n"
                end repeat
            end repeat
            return tabList
        end tell
        """
        let result = runAppleScript(script)
        if result.status != 0 {
            return "{\"error\": \"Failed to list tabs\"}"
        }
        return result.output.isEmpty ? "(no tabs open)" : result.output
    }

    // MARK: - Helpers

    private func runAppleScript(_ script: String) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func shell(_ command: String) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func escapeAS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func escapeJS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "'", with: "\\'")
         .replacingOccurrences(of: "\n", with: "\\n")
    }
}
