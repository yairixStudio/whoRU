import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A model served locally through an Ollama-compatible `/api/chat` endpoint.
/// Zero network egress. No tools: local models are not reliable enough with
/// them yet, so the bundle has to be complete before the call.
public struct LocalModelAnalyst: Analyst {
    public let id = "local"
    public let baseURL: URL
    public let model: String
    public let hardTimeout: Duration

    public init(baseURL: URL, model: String, hardTimeout: Duration = .seconds(90)) {
        self.baseURL = baseURL
        self.model = model
        self.hardTimeout = hardTimeout
    }

    /// True when something answers on the configured port.
    public static func isReachable(baseURL: URL) async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    public func analyze(_ request: AnalysisRequest, tools: any AnalystToolRunner, onEvent: @escaping @Sendable (AnalysisEvent) -> Void) async throws -> AnalysisResult {
        onEvent(.started(model: model))
        let messages: [JSONValue] = [
            ["role": "system", "content": .string(AnalystPrompt.systemPrompt + "\n\n" + AnalystPrompt.schemaInstruction())],
            ["role": "user", "content": .string(AnalystPrompt.userMessage(for: request.bundle))],
        ]
        let (text, all) = try await chat(messages: messages, json: true)
        guard let object = PartialJSON.firstObject(in: text) else { throw AnalystError.invalidResponse("no JSON object in answer") }
        let verdict: Verdict
        do {
            verdict = try JSONDecoder().decode(Verdict.self, from: Data(object.utf8))
        } catch {
            throw AnalystError.invalidResponse("verdict did not match schema: \(error)")
        }
        return AnalysisResult(verdict: verdict, model: model, inputTokens: 0, outputTokens: 0, costUSD: 0,
                              session: AnalystSession(engine: id, model: model, payload: .array(all)), toolCalls: [])
    }

    public func reply(to question: String, session: AnalystSession, request: AnalysisRequest, tools: any AnalystToolRunner, onEvent: @escaping @Sendable (AnalysisEvent) -> Void) async throws -> ChatReply {
        var messages = session.payload.arrayValue ?? []
        messages.append(["role": "user", "content": .string(question)])
        let (text, all) = try await chat(messages: messages, json: false)
        onEvent(.text(text))
        return ChatReply(text: text, session: AnalystSession(engine: id, model: model, payload: .array(all)), inputTokens: 0, outputTokens: 0, costUSD: 0, toolCalls: [])
    }

    private func chat(messages: [JSONValue], json: Bool) async throws -> (String, [JSONValue]) {
        var body: [String: JSONValue] = ["model": .string(model), "messages": .array(messages), "stream": false]
        if json { body["format"] = "json" }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONValue.object(body).data()
        request.timeoutInterval = Double(hardTimeout.components.seconds)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AnalystError.http(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: String(decoding: data, as: UTF8.self))
        }
        let reply = try JSONValue.parse(data)
        let text = reply["message"]?["content"]?.stringValue ?? ""
        return (text, messages + [["role": "assistant", "content": .string(text)]])
    }
}
