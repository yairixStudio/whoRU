import Foundation
import Testing
@testable import WhoRUCore

/// Stdout of `claude -p … --output-format json --model claude-fable-5-1` on an
/// account whose Fable limit was used up (Claude Code 2.1.285): exit 1,
/// nothing useful on stderr, the reason in `result`.
private let fableLimitStdout = #"{"type":"result","subtype":"success","is_error":true,"api_error_status":429,"result":"You've reached your Fable limit. Switch to another model, or manage usage credits at claude.ai/settings/usage?from=cc_cli_limit_message, to continue.","session_id":"ac26c5e2","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0}}"#

private func output(stdout: String, stderr: String = "", status: Int32 = 1) -> CommandOutput {
    CommandOutput(stdout: stdout, stderr: stderr, status: status, durationMs: 1, timedOut: false)
}

@Suite struct ClaudeCodeFailureTests {
    @Test func usageLimitComesFromStdoutInTheCLIsWords() {
        let error = ClaudeCodeAnalyst.failure(from: output(stdout: fableLimitStdout))
        guard case .usageLimit(let message) = error else { Issue.record("expected a usage limit, got \(error)"); return }
        #expect(message.hasPrefix("You've reached your Fable limit."))
        #expect(error.userMessage == message)
        #expect(error.allowsFallback)
    }

    @Test func errorFlaggedResultWithExitZeroIsClassifiedTheSameWay() {
        do {
            _ = try ClaudeCodeAnalyst.parse(output(stdout: fableLimitStdout, status: 0))
            Issue.record("expected an error")
        } catch let error as AnalystError {
            guard case .usageLimit = error else { Issue.record("expected a usage limit, got \(error)"); return }
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func unauthorizedMeansSignIn() {
        let error = ClaudeCodeAnalyst.failure(from: output(stdout: #"{"is_error":true,"api_error_status":401,"result":"Invalid API key · Please run /login"}"#))
        guard case .notConfigured = error else { Issue.record("expected sign-in, got \(error)"); return }
    }

    @Test func otherMessagesAreShownAsTheCLIWroteThem() {
        let error = ClaudeCodeAnalyst.failure(from: output(stdout: #"{"is_error":true,"api_error_status":null,"result":"There's an issue with the selected model (claude-opus-9). It may not exist or you may not have access to it."}"#))
        guard case .agentMessage(let message) = error else { Issue.record("expected the CLI's message, got \(error)"); return }
        #expect(message.contains("claude-opus-9"))
    }

    @Test func withoutJSONStderrStillCounts() {
        let signedOut = ClaudeCodeAnalyst.failure(from: output(stdout: "", stderr: "Error: not logged in"))
        guard case .notConfigured = signedOut else { Issue.record("expected sign-in, got \(signedOut)"); return }
        let crash = ClaudeCodeAnalyst.failure(from: output(stdout: "", stderr: "Segmentation fault"))
        guard case .invalidResponse(let detail) = crash else { Issue.record("expected invalid response, got \(crash)"); return }
        #expect(detail.contains("Segmentation fault"))
    }

    @Test func commandLineAgentsNameTheirLimit() {
        let limit = CLIAgent.usageLimit(in: output(stdout: "", stderr: "working…\nERROR: You exceeded your current quota, please check your plan.\n"))
        guard case .usageLimit(let line) = limit else { Issue.record("expected a usage limit"); return }
        #expect(line == "ERROR: You exceeded your current quota, please check your plan.")
        #expect(CLIAgent.usageLimit(in: output(stdout: "", stderr: "syntax error")) == nil)
    }

    @Test func userMessagesAreSentences() {
        #expect(AnalystError.http(status: 429, body: "").userMessage.contains("Rate limit"))
        #expect(AnalystError.http(status: 400, body: #"{"error":{"type":"invalid_request_error","message":"model: not found"}}"#).userMessage.contains("model: not found"))
        #expect(!AnalystError.cancelled.allowsFallback)
    }
}

// MARK: - Fallback in the pipeline

fileprivate struct ScriptedAnalyst: Analyst {
    let id: String
    let model: String
    let outcome: Result<Verdict, AnalystError>

    func modelName(for request: AnalysisRequest) -> String { model }

    func analyze(_ request: AnalysisRequest, tools: any AnalystToolRunner, onEvent: @escaping @Sendable (AnalysisEvent) -> Void) async throws -> AnalysisResult {
        onEvent(.started(model: model))
        let verdict = try outcome.get()
        return AnalysisResult(verdict: verdict, model: model, inputTokens: 1, outputTokens: 1, costUSD: 0, session: AnalystSession(engine: id, model: model, payload: [:]), toolCalls: [])
    }

    func reply(to question: String, session: AnalystSession, request: AnalysisRequest, tools: any AnalystToolRunner, onEvent: @escaping @Sendable (AnalysisEvent) -> Void) async throws -> ChatReply {
        throw AnalystError.notConfigured("no chat")
    }
}

private final class EventLog: @unchecked Sendable {
    private var items: [ScanEvent] = []
    private let lock = NSLock()
    func append(_ event: ScanEvent) { lock.lock(); items.append(event); lock.unlock() }
    var all: [ScanEvent] { lock.lock(); defer { lock.unlock() }; return items }
}

private let greenVerdict = Verdict(verdict: .legitimate, confidence: 90, headline: "h", whatItIs: "w", whyItAsks: "y", fit: .matches, recommendation: .allow, reasons: [], ifDenied: "d", suggestedQuestions: ["a", "b", "c", "d"], technicalNotes: "")

private func scoredRecord() -> ScanRecord {
    let prompt = PermissionPrompt(title: "“Thing” would like to access files in your Downloads folder.", requesterName: "Thing", service: .downloadsFolder, requestPhrase: "access files in your Downloads folder")
    return ScanRecord(prompt: prompt, hardScore: HardScoreResult(score: .green, reasons: []))
}

private func pipeline(analyst: any Analyst, fallback: (any Analyst)?, settings: Settings = Settings()) -> ScanPipeline {
    ScanPipeline(environment: ScanEnvironment(
        resolver: RequesterResolver(processes: FakeProcesses(list: [])),
        collector: Collector(checks: []),
        analyst: analyst,
        fallbackAnalyst: fallback,
        store: nil,
        settings: settings,
        publishers: PublisherDirectory(),
        secrets: InMemorySecretStore(),
        paths: DefaultPaths(applicationSupport: FileManager.default.temporaryDirectory, homeDirectory: "/Users/me")
    ))
}

@Suite fileprivate struct FallbackTests {
    let limited = ScriptedAnalyst(id: "claude-code", model: "claude-fable-5-1", outcome: .failure(.usageLimit("You've reached your Fable limit.")))
    let opus = ScriptedAnalyst(id: "claude-code", model: "claude-opus-5", outcome: .success(greenVerdict))

    @Test func fallbackAnswersWhenTheAgentHitsItsLimit() async {
        let events = EventLog()
        let record = await pipeline(analyst: limited, fallback: opus).analyze(record: scoredRecord(), onEvent: { events.append($0) })
        #expect(record.verdict?.verdict == .legitimate)
        #expect(record.engine == "claude-code")
        #expect(record.model == "claude-opus-5")
        #expect(record.analystSession?.model == "claude-opus-5")
        let fallbacks = events.all.compactMap { event -> (String, String, String)? in
            if case .fallback(let from, let reason, let to) = event { return (from, reason, to) }
            return nil
        }
        #expect(fallbacks.count == 1)
        #expect(fallbacks.first?.0 == "Claude Code · Claude Fable 5.1")
        #expect(fallbacks.first?.1 == "You've reached your Fable limit.")
        #expect(fallbacks.first?.2 == "Claude Code · Claude Opus 5")
        #expect(!events.all.contains { if case .analysisFailed = $0 { true } else { false } })
    }

    @Test func bothFailingReportsBoth() async {
        let broken = ScriptedAnalyst(id: "codex", model: "gpt-5", outcome: .failure(.timeout))
        let events = EventLog()
        let record = await pipeline(analyst: limited, fallback: broken).analyze(record: scoredRecord(), onEvent: { events.append($0) })
        #expect(record.verdict == nil)
        let failure = events.all.compactMap { if case .analysisFailed(let text) = $0 { text } else { nil } }.first ?? ""
        #expect(failure.contains("Claude Code · Claude Fable 5.1: You've reached your Fable limit."))
        #expect(failure.contains("Codex CLI · GPT-5: The agent did not answer in time."))
    }

    @Test func noFallbackMeansTheRealReason() async {
        let events = EventLog()
        _ = await pipeline(analyst: limited, fallback: nil).analyze(record: scoredRecord(), onEvent: { events.append($0) })
        let failure = events.all.compactMap { if case .analysisFailed(let text) = $0 { text } else { nil } }.first
        #expect(failure == "Claude Code · Claude Fable 5.1: You've reached your Fable limit.")
    }

    @Test func cancellationDoesNotFallBack() async {
        let cancelled = ScriptedAnalyst(id: "claude-code", model: "claude-fable-5-1", outcome: .failure(.cancelled))
        let record = await pipeline(analyst: cancelled, fallback: opus).analyze(record: scoredRecord(), onEvent: { _ in })
        #expect(record.verdict == nil)
    }

    @Test func theSameAgentAndModelIsNotAskedTwice() async {
        let events = EventLog()
        _ = await pipeline(analyst: limited, fallback: limited).analyze(record: scoredRecord(), onEvent: { events.append($0) })
        #expect(!events.all.contains { if case .fallback = $0 { true } else { false } })
    }

    @Test func localOnlyBlocksACloudFallback() async {
        var settings = Settings()
        settings.localOnly = true
        let local = ScriptedAnalyst(id: "local", model: "llama3", outcome: .failure(.timeout))
        let record = await pipeline(analyst: local, fallback: opus, settings: settings).analyze(record: scoredRecord(), onEvent: { _ in })
        #expect(record.verdict == nil)
    }
}

@Suite struct FallbackSettingsTests {
    @Test func fallbackSurvivesASaveAndLoad() throws {
        var settings = Settings()
        settings.engine = .claudeCode
        settings.engineModels["claudeCode"] = "claude-fable-5-1"
        settings.fallbackEngine = .claudeCode
        settings.fallbackModel = "claude-opus-5"
        let data = try JSONEncoder().encode(settings)
        let loaded = try JSONDecoder().decode(Settings.self, from: data)
        #expect(loaded.fallbackEngine == .claudeCode)
        #expect(loaded.fallbackModel == "claude-opus-5")
    }

    @Test func olderFilesHaveNoFallback() throws {
        let loaded = try JSONDecoder().decode(Settings.self, from: Data(#"{"engine":"claudeCode"}"#.utf8))
        #expect(loaded.fallbackEngine == .none)
        #expect(loaded.resolvedFallbackModel == "")
    }

    @Test func promotingTheFallbackUsesItsModel() {
        var settings = Settings()
        settings.engine = .claudeCode
        settings.engineModels["claudeCode"] = "claude-fable-5-1"
        settings.fallbackEngine = .claudeCode
        settings.fallbackModel = "claude-sonnet-5"
        let promoted = settings.promotingFallback
        #expect(promoted.engine == .claudeCode)
        #expect(promoted.model(for: .claudeCode) == "claude-sonnet-5")
        settings.fallbackModel = ""
        #expect(settings.resolvedFallbackModel == "claude-opus-5")
        #expect(EngineChoice.label(analystID: "claude-code", model: "claude-fable-5-1") == "Claude Code · Claude Fable 5.1")
        // Backing up Opus with Fable would pick the model with its own, often spent, limit.
        #expect(EngineChoice.claudeCode.fallbackModel(whenPrimaryRuns: "claude-opus-5") == "claude-sonnet-5")
        #expect(EngineChoice.claudeCode.fallbackModel(whenPrimaryRuns: "claude-sonnet-5") == "claude-opus-5")
        #expect(Set(EngineChoice.claudeCode.fallbackModelPreference) == Set(EngineChoice.claudeCode.suggestedModels))
    }
}
