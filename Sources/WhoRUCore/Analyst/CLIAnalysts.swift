import Foundation

/// Shared plumbing for command-line agents (Codex CLI, Gemini CLI): locate the
/// binary, run it in an empty scratch directory, extract the verdict JSON.
/// These engines keep no session; follow-up questions resend the transcript.
///
/// Neither can be verified the way Claude Code is: both are Node scripts in a
/// user-writable directory, with no signature to check. What protects the
/// user is that they run disclaimed (`Command.run(disclaimResponsibility:)`),
/// as their own responsible process, so whoRU's Accessibility grant and any
/// other permission never reach them, and that they get no tools from us.
enum CLIAgent {
    static func locate(names: [String], extraPaths: [String] = []) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.volta/bin"]
            + (ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? [])
        for raw in extraPaths {
            let path = raw.replacingOccurrences(of: "~", with: home)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        for dir in dirs {
            for name in names {
                let candidate = "\(dir)/\(name)"
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    static func version(of executable: String) async -> String? {
        guard let output = try? await Command.run(executable, ["--version"], timeout: .seconds(10), disclaimResponsibility: true), output.succeeded else { return nil }
        return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first.map(String.init)
    }

    static var scratchDirectory: String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whoru-cli-agents", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    /// Environment for a child agent: inherit PATH and HOME, drop anything that
    /// makes it think it is nested in another agent session.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["CLAUDECODE"] = nil
        env["CLAUDE_CODE_ENTRYPOINT"] = nil
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        return env
    }

    /// Why a run failed, in the tool's words. Only the last lines of stderr
    /// are read: both tools echo the prompt, and the prompt carries text the
    /// program under review chose (its name, its descriptions) as well as
    /// evidence such as "login item", none of which may pass for an error.
    /// Bundle lines are indented JSON, so none of them starts with "ERROR:".
    static func failure(from output: CommandOutput, agent: String, name: String) -> AnalystError {
        let tail = output.stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.suffix(6)
        let limitMarkers = ["rate limit", "usage limit", "exceeded your current quota", "quota exceeded", "too many requests", "resource_exhausted"]
        let signInMarkers = ["not logged in", "not authenticated", "unauthorized", "please log in", "login required"]
        func classify(_ text: String, status: Int? = nil) -> AnalystError {
            let lower = text.lowercased()
            if status == 401 || signInMarkers.contains(where: lower.contains) {
                return .notConfigured("\(name) is not signed in. Sign in from Settings → AI.")
            }
            if status == 429 || limitMarkers.contains(where: lower.contains) { return .usageLimit(String(text.prefix(300))) }
            return .agentMessage(String(text.prefix(300)))
        }
        // Codex: `ERROR: {"type":"error","status":400,"error":{"message":"…"}}`.
        if let line = tail.last(where: { $0.lowercased().hasPrefix("error:") }) {
            let body = line.dropFirst("error:".count).trimmingCharacters(in: .whitespaces)
            if let json = try? JSONValue.parse(body), let message = json["error"]?["message"]?.stringValue ?? json["message"]?.stringValue {
                return classify(message, status: json["status"]?.intValue ?? json["error"]?["code"]?.intValue)
            }
            return classify(body)
        }
        if let line = tail.last(where: { line in (limitMarkers + signInMarkers).contains(where: line.lowercased().contains) }) {
            return classify(line)
        }
        return .invalidResponse("\(agent) exited \(output.status): \(tail.joined(separator: " ").suffix(300))")
    }

    static func decodeVerdict(from text: String) throws -> Verdict {
        guard let object = PartialJSON.firstObject(in: text) else { throw AnalystError.invalidResponse("no JSON object in answer") }
        do {
            return try JSONDecoder().decode(Verdict.self, from: Data(object.utf8))
        } catch {
            throw AnalystError.invalidResponse("verdict did not match schema: \(error)")
        }
    }

    static func transcript(from session: AnalystSession) -> [JSONValue] {
        session.payload["transcript"]?.arrayValue ?? []
    }

    static func chatPrompt(transcript: [JSONValue], bundle: EvidenceBundle, question: String) -> String {
        var lines = ["You previously analyzed this permission request. The evidence bundle and your verdict follow, then the conversation so far. Answer the last question briefly, in the same language, citing evidence keys when you rely on them. You cannot act on the system.", ""]
        lines.append(AnalystPrompt.userMessage(for: bundle))
        lines.append("")
        for turn in transcript {
            let role = turn["role"]?.stringValue ?? "user"
            let text = turn["text"]?.stringValue ?? ""
            lines.append("\(role == "user" ? "User" : "Assistant"): \(text)")
        }
        lines.append("User: \(question)")
        lines.append("Assistant:")
        return lines.joined(separator: "\n")
    }
}

/// OpenAI's Codex CLI in non-interactive mode. Read-only sandbox, no session
/// files, answer written to a temp file so no JSONL parsing is needed.
public struct CodexAnalyst: Analyst {
    public let id = "codex"
    public let executable: String
    /// Empty means the CLI's own default.
    public let model: String
    public let hardTimeout: Duration

    public init(executable: String, model: String = "", hardTimeout: Duration = .seconds(120)) {
        self.executable = executable
        self.model = model
        self.hardTimeout = hardTimeout
    }

    public static func locate(extraPaths: [String] = []) -> String? { CLIAgent.locate(names: ["codex"], extraPaths: extraPaths) }
    public static func version(of executable: String) async -> String? { await CLIAgent.version(of: executable) }

    public func modelName(for request: AnalysisRequest) -> String { model.isEmpty ? "codex default" : model }

    public func analyze(_ request: AnalysisRequest, tools: any AnalystToolRunner, onEvent: @escaping @Sendable (AnalysisEvent) -> Void) async throws -> AnalysisResult {
        onEvent(.started(model: modelName(for: request)))
        let prompt = AnalystPrompt.systemPrompt + "\n\n" + AnalystPrompt.userMessage(for: request.bundle) + "\n\n" + AnalystPrompt.schemaInstruction()
            + "\n\nAnswer from the evidence bundle only. Do not run commands and do not read files."
        let text = try await run(prompt: prompt)
        let verdict = try CLIAgent.decodeVerdict(from: text)
        let session = AnalystSession(engine: id, model: model, payload: ["transcript": .array([["role": "assistant", "text": .string(verdict.headline)]])])
        return AnalysisResult(verdict: verdict, model: model.isEmpty ? "codex" : model, inputTokens: 0, outputTokens: 0, costUSD: 0, session: session, toolCalls: [])
    }

    public func reply(to question: String, session: AnalystSession, request: AnalysisRequest, tools: any AnalystToolRunner, onEvent: @escaping @Sendable (AnalysisEvent) -> Void) async throws -> ChatReply {
        // The conversation stays on the model that answered, which after a
        // fallback to another model of the same agent is not this one's.
        let continuing = session.model.isEmpty || session.model == model ? self : CodexAnalyst(executable: executable, model: session.model, hardTimeout: hardTimeout)
        onEvent(.started(model: continuing.modelName(for: request)))
        var transcript = CLIAgent.transcript(from: session)
        let text = try await continuing.run(prompt: CLIAgent.chatPrompt(transcript: transcript, bundle: request.bundle, question: question))
        onEvent(.text(text))
        transcript.append(["role": "user", "text": .string(question)])
        transcript.append(["role": "assistant", "text": .string(text)])
        return ChatReply(text: text, session: AnalystSession(engine: id, model: continuing.model, payload: ["transcript": .array(transcript)]), inputTokens: 0, outputTokens: 0, costUSD: 0, toolCalls: [])
    }

    private func run(prompt: String) async throws -> String {
        let answerFile = URL(fileURLWithPath: CLIAgent.scratchDirectory).appendingPathComponent("codex-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: answerFile) }
        var arguments = ["exec", "--sandbox", "read-only", "--skip-git-repo-check", "--ephemeral", "--color", "never", "-C", CLIAgent.scratchDirectory, "-o", answerFile.path]
        if !model.isEmpty { arguments += ["-m", model] }
        arguments.append(prompt)
        let output = try await Command.run(executable, arguments, timeout: hardTimeout, environment: CLIAgent.environment, workingDirectory: CLIAgent.scratchDirectory, disclaimResponsibility: true)
        if output.timedOut { throw AnalystError.timeout }
        guard output.status == 0 else {
            throw CLIAgent.failure(from: output, agent: "codex", name: "Codex")
        }
        if let answer = try? String(contentsOf: answerFile, encoding: .utf8), !answer.isEmpty { return answer }
        return output.stdout
    }
}

/// Google's Gemini CLI in non-interactive mode (`-p`). Untested on a live
/// machine at the time of writing; the prompt asks for a plain JSON answer so
/// the output format flag is optional.
public struct GeminiAnalyst: Analyst {
    public let id = "gemini"
    public let executable: String
    public let model: String
    public let hardTimeout: Duration

    public init(executable: String, model: String = "", hardTimeout: Duration = .seconds(120)) {
        self.executable = executable
        self.model = model
        self.hardTimeout = hardTimeout
    }

    public static func locate(extraPaths: [String] = []) -> String? { CLIAgent.locate(names: ["gemini"], extraPaths: extraPaths) }
    public static func version(of executable: String) async -> String? { await CLIAgent.version(of: executable) }

    public func modelName(for request: AnalysisRequest) -> String { model.isEmpty ? "gemini default" : model }

    public func analyze(_ request: AnalysisRequest, tools: any AnalystToolRunner, onEvent: @escaping @Sendable (AnalysisEvent) -> Void) async throws -> AnalysisResult {
        onEvent(.started(model: modelName(for: request)))
        let prompt = AnalystPrompt.systemPrompt + "\n\n" + AnalystPrompt.userMessage(for: request.bundle) + "\n\n" + AnalystPrompt.schemaInstruction()
            + "\n\nAnswer from the evidence bundle only. Do not run commands and do not read files."
        let text = try await run(prompt: prompt)
        let verdict = try CLIAgent.decodeVerdict(from: text)
        let session = AnalystSession(engine: id, model: model, payload: ["transcript": .array([["role": "assistant", "text": .string(verdict.headline)]])])
        return AnalysisResult(verdict: verdict, model: model.isEmpty ? "gemini" : model, inputTokens: 0, outputTokens: 0, costUSD: 0, session: session, toolCalls: [])
    }

    public func reply(to question: String, session: AnalystSession, request: AnalysisRequest, tools: any AnalystToolRunner, onEvent: @escaping @Sendable (AnalysisEvent) -> Void) async throws -> ChatReply {
        // The conversation stays on the model that answered, which after a
        // fallback to another model of the same agent is not this one's.
        let continuing = session.model.isEmpty || session.model == model ? self : GeminiAnalyst(executable: executable, model: session.model, hardTimeout: hardTimeout)
        onEvent(.started(model: continuing.modelName(for: request)))
        var transcript = CLIAgent.transcript(from: session)
        let text = try await continuing.run(prompt: CLIAgent.chatPrompt(transcript: transcript, bundle: request.bundle, question: question))
        onEvent(.text(text))
        transcript.append(["role": "user", "text": .string(question)])
        transcript.append(["role": "assistant", "text": .string(text)])
        return ChatReply(text: text, session: AnalystSession(engine: id, model: continuing.model, payload: ["transcript": .array(transcript)]), inputTokens: 0, outputTokens: 0, costUSD: 0, toolCalls: [])
    }

    private func run(prompt: String) async throws -> String {
        var arguments = ["-p", prompt]
        if !model.isEmpty { arguments += ["-m", model] }
        let output = try await Command.run(executable, arguments, timeout: hardTimeout, environment: CLIAgent.environment, workingDirectory: CLIAgent.scratchDirectory, disclaimResponsibility: true)
        if output.timedOut { throw AnalystError.timeout }
        guard output.status == 0 else {
            throw CLIAgent.failure(from: output, agent: "gemini", name: "Gemini CLI")
        }
        // Newer versions can wrap the answer as {"response": "..."}; older ones print it directly.
        if let json = try? JSONValue.parse(output.stdout), let response = json["response"]?.stringValue { return response }
        return output.stdout
    }
}
