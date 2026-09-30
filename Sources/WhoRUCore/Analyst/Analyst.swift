import Foundation

/// What the analyst is asked to do. The bundle is already redacted.
public struct AnalysisRequest: Sendable {
    public var bundle: EvidenceBundle
    public var model: String
    public var effort: String
    public var maxToolCalls: Int
    public var allowWebSearch: Bool
    /// BCP-47 tag the answer should be written in.
    public var locale: String

    public init(bundle: EvidenceBundle, model: String, effort: String = "medium", maxToolCalls: Int = 8, allowWebSearch: Bool = false, locale: String = "en") {
        self.bundle = bundle
        self.model = model
        self.effort = effort
        self.maxToolCalls = maxToolCalls
        self.allowWebSearch = allowWebSearch
        self.locale = locale
    }
}

public enum AnalysisEvent: Sendable {
    case started(model: String)
    /// The headline field arrived while the rest of the answer is still streaming.
    case partialHeadline(String)
    /// Free text streamed during chat.
    case text(String)
    case toolCall(name: String, input: JSONValue)
    case toolResult(name: String, summary: String)
    case usage(inputTokens: Int, outputTokens: Int)
}

public struct AnalysisResult: Sendable {
    public var verdict: Verdict
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var costUSD: Double
    public var session: AnalystSession
    public var toolCalls: [String]

    public init(verdict: Verdict, model: String, inputTokens: Int, outputTokens: Int, costUSD: Double, session: AnalystSession, toolCalls: [String]) {
        self.verdict = verdict
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
        self.session = session
        self.toolCalls = toolCalls
    }
}

public struct ChatReply: Sendable {
    public var text: String
    public var session: AnalystSession
    public var inputTokens: Int
    public var outputTokens: Int
    public var costUSD: Double
    public var toolCalls: [String]

    public init(text: String, session: AnalystSession, inputTokens: Int, outputTokens: Int, costUSD: Double, toolCalls: [String]) {
        self.text = text
        self.session = session
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
        self.toolCalls = toolCalls
    }
}

/// A tool the model may call. The schema is a JSON Schema object.
public struct AnalystTool: Sendable, Hashable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue = ["type": "object", "properties": [:], "required": []]) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// Executes tool calls on behalf of an analyst. The set is closed and every
/// input is validated by the implementation; the model never gets a shell.
public protocol AnalystToolRunner: Sendable {
    var tools: [AnalystTool] { get }
    /// Returns the result as JSON. Errors are returned as `{"error": "..."}`
    /// so the model can recover; never thrown.
    func run(name: String, input: JSONValue) async -> JSONValue
    /// One line for the panel, e.g. "checking network connections…".
    func summary(forResult result: JSONValue, of name: String) -> String
}

public struct NoTools: AnalystToolRunner {
    public init() {}
    public var tools: [AnalystTool] { [] }
    public func run(name: String, input: JSONValue) async -> JSONValue { ["error": "no tools available"] }
    public func summary(forResult result: JSONValue, of name: String) -> String { name }
}

public enum AnalystError: Error, Sendable, CustomStringConvertible {
    case notConfigured(String)
    case http(status: Int, body: String)
    case refusal(String?)
    case invalidResponse(String)
    /// The account hit a usage or rate limit, for this model or overall. The
    /// text is the agent's own sentence, which says which limit it was.
    case usageLimit(String)
    /// The agent reported a failure in words meant for a person; shown as is.
    case agentMessage(String)
    case timeout
    case cancelled

    public var description: String {
        switch self {
        case .notConfigured(let s): "analyst not configured: \(s)"
        case .http(let status, let body): "HTTP \(status): \(body.prefix(300))"
        case .refusal(let why): "the model declined to analyze" + (why.map { " (\($0))" } ?? "")
        case .invalidResponse(let s): "invalid response: \(s)"
        case .usageLimit(let s): "usage limit: \(s)"
        case .agentMessage(let s): "agent error: \(s)"
        case .timeout: "the model did not answer in time"
        case .cancelled: "cancelled"
        }
    }

    /// One sentence for the panel. `description` stays technical for the log.
    public var userMessage: String {
        switch self {
        case .notConfigured(let s), .usageLimit(let s), .agentMessage(let s): s
        case .http(let status, let body):
            switch status {
            case 401, 403: "The API key was rejected (HTTP \(status))."
            case 429: "Rate limit reached (HTTP 429). Try again later or pick another model."
            case 500...: "The service is unavailable right now (HTTP \(status))."
            default: "The request failed (HTTP \(status))" + (Self.apiErrorMessage(in: body).map { ": \($0)" } ?? ".")
            }
        case .refusal: "The model declined to analyze this request."
        case .invalidResponse(let s): "The answer could not be read (\(s.prefix(160)))."
        case .timeout: "The agent did not answer in time."
        case .cancelled: "Cancelled."
        }
    }

    /// Whether another agent could still answer. Only a cancellation stops
    /// the fallback; a limit, a timeout or an unreadable answer is exactly
    /// what it is for.
    public var allowsFallback: Bool {
        if case .cancelled = self { return false }
        return true
    }

    public var isRetryable: Bool {
        if case .http(let status, _) = self { return status == 429 || status >= 500 }
        return false
    }

    /// `error.message` from an API error body, when there is one.
    static func apiErrorMessage(in body: String) -> String? {
        guard let json = try? JSONValue.parse(body), let message = json["error"]?["message"]?.stringValue, !message.isEmpty else { return nil }
        return String(message.prefix(200))
    }
}

/// One AI engine. Implementations: Claude API, Claude Code, local model.
public protocol Analyst: Sendable {
    var id: String { get }

    /// The model this analyst will actually run for `request`: its own
    /// setting when it has one, else the request's.
    func modelName(for request: AnalysisRequest) -> String

    /// Produces a structured verdict for the bundle.
    func analyze(
        _ request: AnalysisRequest,
        tools: any AnalystToolRunner,
        onEvent: @escaping @Sendable (AnalysisEvent) -> Void
    ) async throws -> AnalysisResult

    /// Continues the conversation that produced `session`.
    func reply(
        to question: String,
        session: AnalystSession,
        request: AnalysisRequest,
        tools: any AnalystToolRunner,
        onEvent: @escaping @Sendable (AnalysisEvent) -> Void
    ) async throws -> ChatReply
}

extension Analyst {
    public func modelName(for request: AnalysisRequest) -> String { request.model }
}

/// Extracts the `headline` string from a partially streamed JSON document.
/// Good enough for a progress indicator; the final document is parsed properly.
public enum PartialJSON {
    public static func headline(in text: String) -> String? {
        stringField("headline", in: text)
    }

    public static func stringField(_ field: String, in text: String) -> String? {
        guard let keyRange = text.range(of: "\"\(field)\"") else { return nil }
        var index = keyRange.upperBound
        // Skip whitespace and the colon.
        while index < text.endIndex, text[index] == " " || text[index] == ":" || text[index] == "\n" { index = text.index(after: index) }
        guard index < text.endIndex, text[index] == "\"" else { return nil }
        index = text.index(after: index)
        var value = ""
        var escaped = false
        while index < text.endIndex {
            let c = text[index]
            if escaped {
                switch c {
                case "n": value.append("\n")
                case "t": value.append("\t")
                case "u":
                    let hexStart = text.index(after: index)
                    guard let hexEnd = text.index(hexStart, offsetBy: 4, limitedBy: text.endIndex),
                          let code = UInt32(text[hexStart..<hexEnd], radix: 16),
                          let scalar = Unicode.Scalar(code) else { return nil }
                    value.append(Character(scalar))
                    index = text.index(before: hexEnd)
                default: value.append(c)
                }
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "\"" {
                return value
            } else {
                value.append(c)
            }
            index = text.index(after: index)
        }
        return nil // string not closed yet
    }

    /// The first complete top-level JSON object in a text that may contain prose around it.
    public static func firstObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let c = text[index]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else {
                if c == "\"" { inString = true } else if c == "{" { depth += 1 } else if c == "}" {
                    depth -= 1
                    if depth == 0 { return String(text[start...index]) }
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
