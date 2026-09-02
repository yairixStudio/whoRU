import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Talks to the Claude API directly over HTTPS with streaming and tool use.
/// No SDK: the surface used here is small and this keeps the core dependency-free.
public struct ClaudeAPIAnalyst: Analyst {
    public let id = "claude-api"
    public let apiKey: String
    public let baseURL: URL
    public let hardTimeout: Duration

    public init(apiKey: String, baseURL: URL = URL(string: "https://api.anthropic.com")!, hardTimeout: Duration = .seconds(45)) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.hardTimeout = hardTimeout
    }

    // MARK: Analyst

    public func analyze(_ request: AnalysisRequest, tools: any AnalystToolRunner, onEvent: @escaping @Sendable (AnalysisEvent) -> Void) async throws -> AnalysisResult {
        let messages: [JSONValue] = [["role": "user", "content": .string(AnalystPrompt.userMessage(for: request.bundle))]]
        let outcome = try await withTimeout(hardTimeout) {
            try await converse(messages: messages, request: request, tools: tools, structured: true, onEvent: onEvent)
        }
        guard let object = PartialJSON.firstObject(in: outcome.text) else {
            throw AnalystError.invalidResponse("no JSON object in answer")
        }
        let verdict: Verdict
        do {
            verdict = try JSONDecoder().decode(Verdict.self, from: Data(object.utf8))
        } catch {
            throw AnalystError.invalidResponse("verdict did not match schema: \(error)")
        }
        let session = AnalystSession(engine: id, model: request.model, payload: .array(outcome.messages))
        return AnalysisResult(
            verdict: verdict, model: outcome.model, inputTokens: outcome.inputTokens, outputTokens: outcome.outputTokens,
            costUSD: Pricing.cost(model: outcome.model, inputTokens: outcome.inputTokens, outputTokens: outcome.outputTokens),
            session: session, toolCalls: outcome.toolCalls
        )
    }

    public func reply(to question: String, session: AnalystSession, request: AnalysisRequest, tools: any AnalystToolRunner, onEvent: @escaping @Sendable (AnalysisEvent) -> Void) async throws -> ChatReply {
        let messages = (session.payload.arrayValue ?? []) + [["role": "user", "content": .string(question)]]
        var chatRequestCopy = request
        chatRequestCopy.maxToolCalls = min(request.maxToolCalls, 4)
        let chatRequest = chatRequestCopy
        let outcome = try await withTimeout(hardTimeout) {
            try await converse(messages: messages, request: chatRequest, tools: tools, structured: false, onEvent: onEvent)
        }
        return ChatReply(
            text: outcome.text,
            session: AnalystSession(engine: id, model: request.model, payload: .array(outcome.messages)),
            inputTokens: outcome.inputTokens, outputTokens: outcome.outputTokens,
            costUSD: Pricing.cost(model: outcome.model, inputTokens: outcome.inputTokens, outputTokens: outcome.outputTokens),
            toolCalls: outcome.toolCalls
        )
    }

    // MARK: Conversation loop

    struct Outcome: Sendable {
        var text: String
        var messages: [JSONValue]
        var model: String
        var inputTokens: Int
        var outputTokens: Int
        var toolCalls: [String]
    }

    private func converse(messages initial: [JSONValue], request: AnalysisRequest, tools: any AnalystToolRunner, structured: Bool, onEvent: @escaping @Sendable (AnalysisEvent) -> Void) async throws -> Outcome {
        var messages = initial
        var inputTokens = 0
        var outputTokens = 0
        var toolCalls: [String] = []
        var servedBy = request.model
        var toolBudget = request.maxToolCalls

        onEvent(.started(model: request.model))

        while true {
            let body = requestBody(messages: messages, request: request, tools: tools, structured: structured)
            let turn = try await streamTurn(body: body, model: request.model, onText: { text in
                if structured, let headline = PartialJSON.headline(in: text) {
                    onEvent(.partialHeadline(headline))
                } else if !structured {
                    onEvent(.text(text))
                }
            })
            inputTokens += turn.inputTokens
            outputTokens += turn.outputTokens
            servedBy = turn.model ?? servedBy
            onEvent(.usage(inputTokens: inputTokens, outputTokens: outputTokens))

            messages.append(["role": "assistant", "content": .array(turn.content)])

            switch turn.stopReason {
            case "tool_use":
                let uses = turn.content.filter { $0["type"]?.stringValue == "tool_use" }
                guard !uses.isEmpty, toolBudget > 0 else {
                    return Outcome(text: turn.text, messages: messages, model: servedBy, inputTokens: inputTokens, outputTokens: outputTokens, toolCalls: toolCalls)
                }
                var results: [JSONValue] = []
                for use in uses {
                    let name = use["name"]?.stringValue ?? ""
                    let input = use["input"] ?? [:]
                    let useID = use["id"]?.stringValue ?? ""
                    onEvent(.toolCall(name: name, input: input))
                    let result: JSONValue
                    if toolBudget > 0 {
                        toolBudget -= 1
                        toolCalls.append(name)
                        result = await tools.run(name: name, input: input)
                    } else {
                        result = ["error": "tool budget exhausted; answer with what you have"]
                    }
                    onEvent(.toolResult(name: name, summary: tools.summary(forResult: result, of: name)))
                    results.append(["type": "tool_result", "tool_use_id": .string(useID), "content": .string(result.string())])
                }
                messages.append(["role": "user", "content": .array(results)])
            case "refusal":
                throw AnalystError.refusal(turn.refusalCategory)
            case "max_tokens":
                throw AnalystError.invalidResponse("answer was cut off")
            default:
                return Outcome(text: turn.text, messages: messages, model: servedBy, inputTokens: inputTokens, outputTokens: outputTokens, toolCalls: toolCalls)
            }
        }
    }

    func requestBody(messages: [JSONValue], request: AnalysisRequest, tools: any AnalystToolRunner, structured: Bool) -> JSONValue {
        var system: [JSONValue] = [
            ["type": "text", "text": .string(AnalystPrompt.systemPrompt), "cache_control": ["type": "ephemeral"]],
        ]
        if !structured {
            system.append(["type": "text", "text": .string(AnalystPrompt.chatSystemAddendum())])
        }
        var toolDefs: [JSONValue] = tools.tools.map {
            ["name": .string($0.name), "description": .string($0.description), "input_schema": $0.inputSchema]
        }
        if request.allowWebSearch {
            toolDefs.append(["type": "web_search_20260209", "name": "web_search", "max_uses": 3])
        }
        var outputConfig: [String: JSONValue] = ["effort": .string(request.effort)]
        if structured {
            outputConfig["format"] = ["type": "json_schema", "schema": AnalystPrompt.verdictSchema]
        }
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "max_tokens": 16000,
            "stream": true,
            "thinking": ["type": "adaptive"],
            "output_config": .object(outputConfig),
            "system": .array(system),
            "messages": .array(messages),
        ]
        if !toolDefs.isEmpty { body["tools"] = .array(toolDefs) }
        if Self.supportsFallbacks(request.model) { body["fallbacks"] = "default" }
        return .object(body)
    }

    static func supportsFallbacks(_ model: String) -> Bool {
        model.hasPrefix("claude-fable-5") || model.hasPrefix("claude-opus-5")
    }

    // MARK: Streaming

    struct Turn: Sendable {
        var content: [JSONValue]
        var text: String
        var stopReason: String?
        var refusalCategory: String?
        var model: String?
        var inputTokens: Int
        var outputTokens: Int
    }

    private func streamTurn(body: JSONValue, model: String, onText: @escaping @Sendable (String) -> Void) async throws -> Turn {
        var urlRequest = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if Self.supportsFallbacks(model) {
            urlRequest.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        urlRequest.httpBody = try body.data()
        urlRequest.timeoutInterval = 60

        var attempt = 0
        while true {
            attempt += 1
            do {
                return try await performStream(urlRequest, onText: onText)
            } catch let error as AnalystError where error.isRetryable && attempt <= 2 {
                try await Task.sleep(for: .milliseconds(500 * attempt * attempt))
                continue
            }
        }
    }

    private func performStream(_ urlRequest: URLRequest, onText: @escaping @Sendable (String) -> Void) async throws -> Turn {
        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw AnalystError.invalidResponse("no HTTP response") }
        if http.statusCode != 200 {
            var body = ""
            for try await line in bytes.lines { body += line + "\n" }
            throw AnalystError.http(status: http.statusCode, body: body)
        }

        var blocks: [Int: SSEBlock] = [:]
        var turn = Turn(content: [], text: "", inputTokens: 0, outputTokens: 0)
        var eventName = ""
        var dataLines: [String] = []

        func dispatch() throws {
            defer { eventName = ""; dataLines = [] }
            guard !dataLines.isEmpty else { return }
            let payload = try JSONValue.parse(dataLines.joined(separator: "\n"))
            let type = payload["type"]?.stringValue ?? eventName
            switch type {
            case "message_start":
                let message = payload["message"]
                turn.model = message?["model"]?.stringValue
                let usage = message?["usage"]
                turn.inputTokens += (usage?["input_tokens"]?.intValue ?? 0)
                    + (usage?["cache_read_input_tokens"]?.intValue ?? 0)
                    + (usage?["cache_creation_input_tokens"]?.intValue ?? 0)
            case "content_block_start":
                guard let index = payload["index"]?.intValue, let start = payload["content_block"]?.objectValue else { return }
                blocks[index] = SSEBlock(object: start)
            case "content_block_delta":
                guard let index = payload["index"]?.intValue, var block = blocks[index], let delta = payload["delta"] else { return }
                switch delta["type"]?.stringValue {
                case "text_delta":
                    let piece = delta["text"]?.stringValue ?? ""
                    block.append("text", piece)
                    turn.text += piece
                    onText(turn.text)
                case "input_json_delta":
                    block.partialJSON += delta["partial_json"]?.stringValue ?? ""
                case "thinking_delta":
                    block.append("thinking", delta["thinking"]?.stringValue ?? "")
                case "signature_delta":
                    block.object["signature"] = delta["signature"] ?? .null
                default:
                    break
                }
                blocks[index] = block
            case "content_block_stop":
                guard let index = payload["index"]?.intValue, var block = blocks[index] else { return }
                if !block.partialJSON.isEmpty {
                    block.object["input"] = (try? JSONValue.parse(block.partialJSON)) ?? [:]
                } else if block.object["type"]?.stringValue == "tool_use", block.object["input"] == nil {
                    block.object["input"] = [:]
                }
                blocks[index] = block
            case "message_delta":
                turn.stopReason = payload["delta"]?["stop_reason"]?.stringValue ?? turn.stopReason
                turn.refusalCategory = payload["delta"]?["stop_details"]?["category"]?.stringValue
                turn.outputTokens += payload["usage"]?["output_tokens"]?.intValue ?? 0
            case "error":
                let message = payload["error"]?["message"]?.stringValue ?? "stream error"
                throw AnalystError.invalidResponse(message)
            default:
                break
            }
        }

        for try await line in bytes.lines {
            if line.isEmpty {
                try dispatch()
            } else if line.hasPrefix("event:") {
                eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataLines.append(String(line.dropFirst(5).trimmingCharacters(in: .whitespaces)))
            }
        }
        try dispatch()

        turn.content = blocks.keys.sorted().compactMap { blocks[$0] }.map { .object($0.object) }
        // Text is what the model said outside tool calls; recompute from blocks in order.
        turn.text = turn.content.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }.joined()
        return turn
    }

    // MARK: Models

    /// Lists model ids the key can use. Doubles as key validation.
    public static func listModels(apiKey: String, baseURL: URL = URL(string: "https://api.anthropic.com")!) async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/models"))
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AnalystError.invalidResponse("no HTTP response") }
        guard http.statusCode == 200 else { throw AnalystError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self)) }
        let json = try JSONValue.parse(data)
        return (json["data"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue }
    }
}

struct SSEBlock: Sendable {
    var object: [String: JSONValue]
    var partialJSON = ""

    init(object: [String: JSONValue]) { self.object = object }

    mutating func append(_ key: String, _ piece: String) {
        object[key] = .string((object[key]?.stringValue ?? "") + piece)
    }
}
