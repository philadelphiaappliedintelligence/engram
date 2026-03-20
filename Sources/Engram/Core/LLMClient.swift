import Foundation

// MARK: - Provider

public enum LLMProvider: String, Codable, Sendable {
    case anthropic
    case openai       // OpenAI Chat Completions, OpenRouter, Ollama, any compatible API
    case codex        // OpenAI Codex Responses API (ChatGPT Plus/Pro OAuth)
}

// MARK: - LLM Client

/// Multi-provider LLM client with retry, prompt caching, and streaming.
/// Supports both API key auth and Claude Code OAuth (Bearer token).
public actor LLMClient {
    private var apiKey: String
    private let baseURL: String
    private let provider: LLMProvider
    private let isOAuth: Bool
    private let oauth: OAuthClient?
    private let session: URLSession
    private let maxRetries: Int

    public init(
        apiKey: String,
        baseURL: String = "https://api.anthropic.com",
        provider: LLMProvider = .anthropic,
        maxRetries: Int = 3,
        oauth: OAuthClient? = nil
    ) {
        self.apiKey = apiKey
        self.provider = provider
        self.maxRetries = maxRetries
        self.isOAuth = OAuthClient.isOAuthToken(apiKey)
        self.oauth = oauth

        if baseURL == "https://api.anthropic.com" && provider == .openai {
            self.baseURL = "https://api.openai.com"
        } else {
            self.baseURL = baseURL
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
    }

    /// Refresh the OAuth token if needed before a request.
    private func ensureValidToken() async {
        guard isOAuth, let oauth else { return }
        if let creds = oauth.loadCredentials(), creds.isExpired {
            if let newToken = try? await oauth.refresh() {
                apiKey = newToken
            }
        }
    }

    // MARK: - Non-Streaming Completion

    public func complete(
        messages: [Message],
        system: String? = nil,
        tools: [ToolDefinition] = [],
        model: String = "claude-sonnet-4-20250514",
        maxTokens: Int = 8192
    ) async throws -> LLMResponse {
        try await withRetry {
            switch self.provider {
            case .anthropic:
                return try await self.anthropicRequest(
                    messages: messages, system: system, tools: tools,
                    model: model, maxTokens: maxTokens, stream: false, onText: nil
                )
            case .openai:
                return try await self.openaiRequest(
                    messages: messages, system: system, tools: tools,
                    model: model, maxTokens: maxTokens, stream: false, onText: nil
                )
            case .codex:
                return try await self.codexRequest(
                    messages: messages, system: system, tools: tools,
                    model: model, maxTokens: maxTokens, onText: nil
                )
            }
        }
    }

    // MARK: - Streaming Completion

    public func stream(
        messages: [Message],
        system: String? = nil,
        tools: [ToolDefinition] = [],
        model: String = "claude-sonnet-4-20250514",
        maxTokens: Int = 8192,
        onText: @Sendable @escaping (String) -> Void
    ) async throws -> LLMResponse {
        try await withRetry {
            switch self.provider {
            case .anthropic:
                return try await self.anthropicRequest(
                    messages: messages, system: system, tools: tools,
                    model: model, maxTokens: maxTokens, stream: true, onText: onText
                )
            case .openai:
                return try await self.openaiRequest(
                    messages: messages, system: system, tools: tools,
                    model: model, maxTokens: maxTokens, stream: true, onText: onText
                )
            case .codex:
                return try await self.codexRequest(
                    messages: messages, system: system, tools: tools,
                    model: model, maxTokens: maxTokens, onText: onText
                )
            }
        }
    }

    // MARK: - Image Analysis

    /// Send an image to the LLM for vision analysis (Anthropic only for now)
    public func analyzeImage(base64: String, mediaType: String, prompt: String) async throws -> String {
        await ensureValidToken()

        let url = URL(string: "\(baseURL)/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        if isOAuth {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("claude-code-20250219,oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("true", forHTTPHeaderField: "anthropic-dangerous-direct-browser-access")
            request.setValue("claude-cli/2.1.2 (external, cli)", forHTTPHeaderField: "user-agent")
            request.setValue("cli", forHTTPHeaderField: "x-app")
        } else {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }

        let body: [String: Any] = [
            "model": "claude-sonnet-4-6",
            "max_tokens": 1024,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image", "source": [
                        "type": "base64", "media_type": mediaType, "data": base64
                    ] as [String: Any]] as [String: Any],
                    ["type": "text", "text": prompt] as [String: Any],
                ]
            ] as [String: Any]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let errBody = String(data: data, encoding: .utf8) ?? ""
            throw LLMError.apiError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: errBody)
        }
        let parsed = try parseAnthropicResponse(data)
        return parsed.textContent
    }

    // MARK: - Retry with Exponential Backoff

    private func withRetry(_ operation: () async throws -> LLMResponse) async throws -> LLMResponse {
        var lastError: Error?

        for attempt in 0..<maxRetries {
            do {
                return try await operation()
            } catch let error as LLMError {
                lastError = error
                if case .apiError(let status, _) = error {
                    // Retry on rate limit (429), server error (500+), overloaded (529)
                    if status == 429 || status >= 500 {
                        let delay = min(pow(2.0, Double(attempt)), 32.0)
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue
                    }
                }
                throw error  // Don't retry client errors (400, 401, etc.)
            } catch {
                lastError = error
                // Retry network errors
                let delay = min(pow(2.0, Double(attempt)), 32.0)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }

        throw lastError ?? LLMError.invalidResponse
    }

    // MARK: - Codex Responses API

    private func codexRequest(
        messages: [Message], system: String?, tools: [ToolDefinition],
        model: String, maxTokens: Int, onText: ((String) -> Void)? = nil
    ) async throws -> LLMResponse {
        await ensureValidToken()

        let stripped = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let url = URL(string: "\(stripped)/responses")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        // Build input items from messages (skip system — goes in instructions)
        var inputItems: [[String: Any]] = []
        for msg in messages {
            let role = msg.role.rawValue
            if role == "system" { continue }

            // Tool results
            let toolResults = msg.content.compactMap { block -> ToolResultBlock? in
                if case .toolResult(let tr) = block { return tr }
                return nil
            }
            if !toolResults.isEmpty {
                for tr in toolResults {
                    inputItems.append([
                        "type": "function_call_output",
                        "call_id": tr.toolUseId,
                        "output": tr.content,
                    ])
                }
                continue
            }

            // Tool calls from assistant
            let toolUses = msg.content.compactMap { block -> ToolUse? in
                if case .toolUse(let tu) = block { return tu }
                return nil
            }
            if !toolUses.isEmpty {
                for tu in toolUses {
                    var args: [String: Any] = [:]
                    for (k, v) in tu.input { args[k] = jsonValueToAny(v) }
                    let argsStr = (try? JSONSerialization.data(withJSONObject: args))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    inputItems.append([
                        "type": "function_call",
                        "name": tu.name,
                        "arguments": argsStr,
                        "call_id": tu.id,
                    ])
                }
                // Also add text if present
                let text = msg.textContent
                if !text.isEmpty {
                    inputItems.append(["role": "assistant", "content": text])
                }
                continue
            }

            // Regular message
            inputItems.append(["role": role, "content": msg.textContent])
        }

        // Build tools in Responses format
        var toolsList: [[String: Any]]?
        if !tools.isEmpty {
            toolsList = tools.map { tool -> [String: Any] in
                var schema: [String: Any] = [:]
                for (k, v) in tool.inputSchema { schema[k] = jsonValueToAny(v) }
                return [
                    "type": "function",
                    "name": tool.name,
                    "description": tool.description,
                    "strict": false,
                    "parameters": schema,
                ]
            }
        }

        var body: [String: Any] = [
            "model": model,
            "instructions": system ?? "",
            "input": inputItems,
            "store": false,
            "stream": true,
        ]
        if let toolsList { body["tools"] = toolsList }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            var errBody = ""
            for try await line in bytes.lines { errBody += line }
            throw LLMError.apiError(status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                                     body: errBody)
        }

        return try await parseCodexSSE(bytes: bytes, onText: onText)
    }

    private func parseCodexSSE(
        bytes: URLSession.AsyncBytes, onText: ((String) -> Void)?
    ) async throws -> LLMResponse {
        var blocks: [ContentBlock] = []
        var currentText = ""
        var toolCalls: [(id: String, name: String, args: String)] = []
        var inputTokens = 0, outputTokens = 0

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6))
            guard jsonStr != "[DONE]",
                  let data = jsonStr.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else { continue }

            switch type {
            case "response.output_text.delta":
                if let delta = event["delta"] as? String {
                    currentText += delta
                    onText?(delta)
                }

            case "response.function_call_arguments.done":
                let name = event["name"] as? String ?? ""
                let callId = event["call_id"] as? String ?? "call_\(UUID().uuidString.prefix(8))"
                let args = event["arguments"] as? String ?? "{}"
                toolCalls.append((id: callId, name: name, args: args))

            case "response.completed":
                if let resp = event["response"] as? [String: Any],
                   let usage = resp["usage"] as? [String: Any] {
                    inputTokens = usage["input_tokens"] as? Int ?? 0
                    outputTokens = usage["output_tokens"] as? Int ?? 0
                }

            case "response.failed":
                let error = event["error"] as? [String: Any]
                let msg = error?["message"] as? String ?? "Codex request failed"
                throw LLMError.apiError(status: 400, body: msg)

            default: break
            }
        }

        if !currentText.isEmpty { blocks.append(.text(currentText)) }

        for tc in toolCalls {
            let input: [String: JSONValue]
            if let d = tc.args.data(using: .utf8),
               let p = try? JSONDecoder().decode([String: JSONValue].self, from: d) {
                input = p
            } else { input = [:] }
            blocks.append(.toolUse(ToolUse(id: tc.id, name: tc.name, input: input)))
        }

        let hasTools = blocks.contains { if case .toolUse = $0 { return true }; return false }

        return LLMResponse(
            content: blocks,
            stopReason: hasTools ? .toolUse : .endTurn,
            inputTokens: inputTokens, outputTokens: outputTokens,
            cacheReadTokens: 0, cacheWriteTokens: 0
        )
    }

    // MARK: - Anthropic API

    private func anthropicRequest(
        messages: [Message], system: String?, tools: [ToolDefinition],
        model: String, maxTokens: Int, stream: Bool,
        onText: ((String) -> Void)?
    ) async throws -> LLMResponse {
        await ensureValidToken()

        let url = URL(string: "\(baseURL)/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        if isOAuth {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue(
                "claude-code-20250219,oauth-2025-04-20,interleaved-thinking-2025-05-14",
                forHTTPHeaderField: "anthropic-beta")
            request.setValue("true", forHTTPHeaderField: "anthropic-dangerous-direct-browser-access")
            request.setValue("claude-cli/2.1.2 (external, cli)", forHTTPHeaderField: "user-agent")
            request.setValue("cli", forHTTPHeaderField: "x-app")
        } else {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": encodeAnthropicMessages(messages),
        ]
        if stream { body["stream"] = true }

        // System prompt
        if let system {
            if isOAuth {
                // OAuth tokens: plain system prompt (cache_control may not be supported)
                body["system"] = system
            } else {
                // API key: use cache_control for prompt caching
                body["system"] = [
                    ["type": "text", "text": system,
                     "cache_control": ["type": "ephemeral"]] as [String: Any]
                ]
            }
        }

        if !tools.isEmpty {
            body["tools"] = tools.map { $0.toAnthropicDict() }
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let requestData = request.httpBody!

        if stream {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
            guard http.statusCode == 200 else {
                var errBody = ""
                for try await line in bytes.lines { errBody += line }
                // Include request snippet for debugging 400s
                if http.statusCode == 400 {
                    let reqStr = String(data: requestData, encoding: .utf8) ?? ""
                    let preview = String(reqStr.prefix(500))
                    errBody += "\n[Request preview: \(preview)]"
                }
                throw LLMError.apiError(status: http.statusCode, body: errBody)
            }
            return try await parseAnthropicSSE(bytes: bytes, onText: onText ?? { _ in })
        } else {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
            guard http.statusCode == 200 else {
                throw LLMError.apiError(status: http.statusCode,
                                         body: String(data: data, encoding: .utf8) ?? "")
            }
            return try parseAnthropicResponse(data)
        }
    }

    // MARK: - OpenAI-Compatible API

    private func openaiRequest(
        messages: [Message], system: String?, tools: [ToolDefinition],
        model: String, maxTokens: Int, stream: Bool,
        onText: ((String) -> Void)?
    ) async throws -> LLMResponse {
        // Standard: {baseURL}/v1/chat/completions
        // Codex/custom: baseURL may already include path prefix, just append /chat/completions
        let stripped = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let chatPath: String
        if stripped.hasSuffix("/v1") || stripped.hasSuffix("openai.com") ||
           stripped.hasSuffix("openrouter.ai/api") {
            chatPath = "\(stripped)/v1/chat/completions"
        } else {
            chatPath = "\(stripped)/chat/completions"
        }
        let url = URL(string: chatPath)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        var msgs: [[String: Any]] = []
        if let system {
            msgs.append(["role": "system", "content": system])
        }
        msgs.append(contentsOf: encodeOpenAIMessages(messages))

        var body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": msgs,
        ]
        if stream { body["stream"] = true }

        if !tools.isEmpty {
            body["tools"] = tools.map { $0.toOpenAIDict() }
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        if stream {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
            guard http.statusCode == 200 else {
                var errBody = ""
                for try await line in bytes.lines { errBody += line }
                throw LLMError.apiError(status: http.statusCode, body: errBody)
            }
            return try await parseOpenAISSE(bytes: bytes, onText: onText ?? { _ in })
        } else {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
            guard http.statusCode == 200 else {
                throw LLMError.apiError(status: http.statusCode,
                                         body: String(data: data, encoding: .utf8) ?? "")
            }
            return try parseOpenAIResponse(data)
        }
    }

    // MARK: - Anthropic SSE Parser

    private func parseAnthropicSSE(
        bytes: URLSession.AsyncBytes, onText: (String) -> Void
    ) async throws -> LLMResponse {
        var contentBlocks: [ContentBlock] = []
        var currentText = ""
        var currentToolId = "", currentToolName = "", currentToolJSON = ""
        var stopReason: StopReason = .unknown
        var inputTokens = 0, outputTokens = 0, cacheRead = 0, cacheWrite = 0
        var inToolBlock = false

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6))
            guard jsonStr != "[DONE]",
                  let data = jsonStr.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String
            else { continue }

            switch type {
            case "message_start":
                if let msg = event["message"] as? [String: Any],
                   let usage = msg["usage"] as? [String: Any] {
                    inputTokens = usage["input_tokens"] as? Int ?? 0
                    cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                    cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
                }

            case "content_block_start":
                if let block = event["content_block"] as? [String: Any],
                   let blockType = block["type"] as? String {
                    if blockType == "tool_use" {
                        inToolBlock = true
                        currentToolId = block["id"] as? String ?? ""
                        currentToolName = block["name"] as? String ?? ""
                        currentToolJSON = ""
                        if !currentText.isEmpty {
                            contentBlocks.append(.text(currentText))
                            currentText = ""
                        }
                    } else { inToolBlock = false }
                }

            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any],
                   let deltaType = delta["type"] as? String {
                    if deltaType == "text_delta", let text = delta["text"] as? String {
                        currentText += text
                        onText(text)
                    } else if deltaType == "input_json_delta",
                              let partial = delta["partial_json"] as? String {
                        currentToolJSON += partial
                    }
                }

            case "content_block_stop":
                if inToolBlock {
                    let input: [String: JSONValue]
                    if let d = currentToolJSON.data(using: .utf8),
                       let parsed = try? JSONDecoder().decode([String: JSONValue].self, from: d) {
                        input = parsed
                    } else { input = [:] }
                    contentBlocks.append(.toolUse(ToolUse(
                        id: currentToolId, name: currentToolName, input: input)))
                    inToolBlock = false
                }

            case "message_delta":
                if let delta = event["delta"] as? [String: Any],
                   let reason = delta["stop_reason"] as? String {
                    stopReason = StopReason(rawValue: reason) ?? .unknown
                }
                if let usage = event["usage"] as? [String: Any] {
                    outputTokens = usage["output_tokens"] as? Int ?? 0
                }

            default: break
            }
        }

        if !currentText.isEmpty { contentBlocks.append(.text(currentText)) }

        return LLMResponse(
            content: contentBlocks, stopReason: stopReason,
            inputTokens: inputTokens, outputTokens: outputTokens,
            cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite
        )
    }

    // MARK: - OpenAI SSE Parser

    private func parseOpenAISSE(
        bytes: URLSession.AsyncBytes, onText: (String) -> Void
    ) async throws -> LLMResponse {
        var contentBlocks: [ContentBlock] = []
        var currentText = ""
        var toolCalls: [String: (name: String, json: String)] = [:]  // index → (name, partial_json)
        var stopReason: StopReason = .unknown

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6))
            guard jsonStr != "[DONE]",
                  let data = jsonStr.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = event["choices"] as? [[String: Any]],
                  let choice = choices.first
            else { continue }

            if let reason = choice["finish_reason"] as? String {
                stopReason = reason == "tool_calls" ? .toolUse :
                    (reason == "stop" ? .endTurn : .unknown)
            }

            if let delta = choice["delta"] as? [String: Any] {
                if let content = delta["content"] as? String {
                    currentText += content
                    onText(content)
                }
                if let tcs = delta["tool_calls"] as? [[String: Any]] {
                    for tc in tcs {
                        let idx = String(tc["index"] as? Int ?? 0)
                        if let fn = tc["function"] as? [String: Any] {
                            if let name = fn["name"] as? String {
                                toolCalls[idx] = (name: name, json: toolCalls[idx]?.json ?? "")
                            }
                            if let args = fn["arguments"] as? String {
                                var existing = toolCalls[idx] ?? (name: "", json: "")
                                existing.json += args
                                toolCalls[idx] = existing
                            }
                        }
                    }
                }
            }
        }

        if !currentText.isEmpty { contentBlocks.append(.text(currentText)) }

        for (_, tc) in toolCalls.sorted(by: { $0.key < $1.key }) {
            let input: [String: JSONValue]
            if let d = tc.json.data(using: .utf8),
               let parsed = try? JSONDecoder().decode([String: JSONValue].self, from: d) {
                input = parsed
            } else { input = [:] }
            contentBlocks.append(.toolUse(ToolUse(
                id: "call_\(UUID().uuidString.prefix(8))", name: tc.name, input: input)))
        }

        return LLMResponse(
            content: contentBlocks, stopReason: stopReason,
            inputTokens: 0, outputTokens: 0,
            cacheReadTokens: 0, cacheWriteTokens: 0
        )
    }

    // MARK: - Anthropic Response Parser

    private func parseAnthropicResponse(_ data: Data) throws -> LLMResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.invalidResponse
        }
        var blocks: [ContentBlock] = []
        if let content = json["content"] as? [[String: Any]] {
            for block in content {
                guard let type = block["type"] as? String else { continue }
                if type == "text", let text = block["text"] as? String {
                    blocks.append(.text(text))
                } else if type == "tool_use" {
                    let input: [String: JSONValue]
                    if let d = block["input"], let id = try? JSONSerialization.data(withJSONObject: d),
                       let p = try? JSONDecoder().decode([String: JSONValue].self, from: id) {
                        input = p
                    } else { input = [:] }
                    blocks.append(.toolUse(ToolUse(
                        id: block["id"] as? String ?? "", name: block["name"] as? String ?? "",
                        input: input)))
                }
            }
        }
        let usage = json["usage"] as? [String: Any] ?? [:]
        return LLMResponse(
            content: blocks,
            stopReason: StopReason(rawValue: json["stop_reason"] as? String ?? "") ?? .unknown,
            inputTokens: usage["input_tokens"] as? Int ?? 0,
            outputTokens: usage["output_tokens"] as? Int ?? 0,
            cacheReadTokens: usage["cache_read_input_tokens"] as? Int ?? 0,
            cacheWriteTokens: usage["cache_creation_input_tokens"] as? Int ?? 0
        )
    }

    // MARK: - OpenAI Response Parser

    private func parseOpenAIResponse(_ data: Data) throws -> LLMResponse {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let choice = choices.first,
              let msg = choice["message"] as? [String: Any] else {
            throw LLMError.invalidResponse
        }
        var blocks: [ContentBlock] = []
        if let content = msg["content"] as? String, !content.isEmpty {
            blocks.append(.text(content))
        }
        if let tcs = msg["tool_calls"] as? [[String: Any]] {
            for tc in tcs {
                let fn = tc["function"] as? [String: Any] ?? [:]
                let input: [String: JSONValue]
                if let args = fn["arguments"] as? String, let d = args.data(using: .utf8),
                   let p = try? JSONDecoder().decode([String: JSONValue].self, from: d) {
                    input = p
                } else { input = [:] }
                blocks.append(.toolUse(ToolUse(
                    id: tc["id"] as? String ?? "", name: fn["name"] as? String ?? "",
                    input: input)))
            }
        }
        let reason = choice["finish_reason"] as? String ?? ""
        let usage = json["usage"] as? [String: Any] ?? [:]
        return LLMResponse(
            content: blocks,
            stopReason: reason == "tool_calls" ? .toolUse : (reason == "stop" ? .endTurn : .unknown),
            inputTokens: usage["prompt_tokens"] as? Int ?? 0,
            outputTokens: usage["completion_tokens"] as? Int ?? 0,
            cacheReadTokens: 0, cacheWriteTokens: 0
        )
    }

    // MARK: - Anthropic Message Encoding

    private func encodeAnthropicMessages(_ messages: [Message]) -> [[String: Any]] {
        messages.map { msg in
            var dict: [String: Any] = ["role": msg.role.rawValue]
            var content: [[String: Any]] = []
            for block in msg.content {
                switch block {
                case .text(let text):
                    content.append(["type": "text", "text": text])
                case .toolUse(let tool):
                    var inputDict: [String: Any] = [:]
                    for (k, v) in tool.input { inputDict[k] = jsonValueToAny(v) }
                    content.append(["type": "tool_use", "id": tool.id,
                                    "name": tool.name, "input": inputDict])
                case .toolResult(let result):
                    content.append(["type": "tool_result",
                                    "tool_use_id": result.toolUseId,
                                    "content": result.content,
                                    "is_error": result.isError])
                }
            }
            if content.count == 1, case .text(let t) = msg.content[0] {
                dict["content"] = t
            } else { dict["content"] = content }
            return dict
        }
    }

    // MARK: - OpenAI Message Encoding

    private func encodeOpenAIMessages(_ messages: [Message]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for msg in messages {
            // Tool results in OpenAI format
            let toolResults = msg.content.compactMap { block -> ToolResultBlock? in
                if case .toolResult(let tr) = block { return tr }
                return nil
            }
            if !toolResults.isEmpty {
                for tr in toolResults {
                    result.append(["role": "tool", "content": tr.content,
                                   "tool_call_id": tr.toolUseId])
                }
                continue
            }

            var dict: [String: Any] = ["role": msg.role.rawValue]

            // Tool calls from assistant
            let toolUses = msg.content.compactMap { block -> ToolUse? in
                if case .toolUse(let tu) = block { return tu }
                return nil
            }
            if !toolUses.isEmpty {
                dict["content"] = msg.textContent.isEmpty ? NSNull() : msg.textContent
                dict["tool_calls"] = toolUses.map { tu -> [String: Any] in
                    var args: [String: Any] = [:]
                    for (k, v) in tu.input { args[k] = jsonValueToAny(v) }
                    let argsStr = (try? JSONSerialization.data(withJSONObject: args))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    return ["id": tu.id, "type": "function",
                            "function": ["name": tu.name, "arguments": argsStr]]
                }
            } else {
                dict["content"] = msg.textContent
            }
            result.append(dict)
        }
        return result
    }
}

// MARK: - Helper

private func jsonValueToAny(_ value: JSONValue) -> Any {
    switch value {
    case .string(let s): return s
    case .number(let n): return n
    case .bool(let b): return b
    case .null: return NSNull()
    case .array(let a): return a.map { jsonValueToAny($0) }
    case .object(let o): return o.mapValues { jsonValueToAny($0) }
    }
}

// MARK: - Tool Definition Extensions

extension ToolDefinition {
    func toAnthropicDict() -> [String: Any] {
        var schema: [String: Any] = [:]
        for (k, v) in inputSchema { schema[k] = jsonValueToAny(v) }
        return ["name": name, "description": description, "input_schema": schema]
    }

    func toOpenAIDict() -> [String: Any] {
        var schema: [String: Any] = [:]
        for (k, v) in inputSchema { schema[k] = jsonValueToAny(v) }
        return ["type": "function",
                "function": ["name": name, "description": description, "parameters": schema]]
    }
}

// MARK: - Tool Definition

public struct ToolDefinition: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: [String: JSONValue]

    public init(name: String, description: String, inputSchema: [String: JSONValue]) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

// MARK: - Errors

public enum LLMError: Error, LocalizedError {
    case invalidResponse
    case apiError(status: Int, body: String)
    case noAPIKey

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from API"
        case .apiError(let status, let body): return "API error \(status): \(body)"
        case .noAPIKey: return "No API key configured"
        }
    }
}
