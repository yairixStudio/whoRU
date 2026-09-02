import Foundation

/// Uses an installed Claude Code CLI in headless mode. Zero setup for people
/// who already have it; the CLI gets a read-only Bash allowlist so the model
/// can run checks nobody anticipated, and nothing else.
public struct ClaudeCodeAnalyst: Analyst {
    public let id = "claude-code"
    public let executable: String
    /// Model alias or id passed to the CLI; empty means the request's model.
    public let model: String
    public let hardTimeout: Duration

    public init(executable: String, model: String = "", hardTimeout: Duration = .seconds(90)) {
        self.executable = executable
        self.model = model
        self.hardTimeout = hardTimeout
    }

    /// Metadata-only commands. No rm, no curl, no writes, and no file reading:
    /// the model may inspect signatures and attributes, never contents. The
    /// first live run showed the model reaching for the Desktop folder, which
    /// macOS attributes to whoRU; that must not happen.
    public static let allowedTools = [
        "Bash(codesign:*)", "Bash(spctl:*)", "Bash(shasum:*)", "Bash(mdls:*)", "Bash(xattr:*)",
        "Bash(ps:*)", "Bash(lsof:*)", "Bash(plutil:*)", "Bash(stat:*)", "Bash(file:*)", "Bash(otool:*)",
    ]

    /// Explicitly denied even if a future default would allow them.
    public static let disallowedTools = [
        "Read", "Write", "Edit", "MultiEdit", "NotebookEdit", "WebFetch", "WebSearch", "Task", "Glob", "Grep",
        "Bash(cat:*)", "Bash(head:*)", "Bash(tail:*)", "Bash(less:*)", "Bash(cp:*)", "Bash(mv:*)", "Bash(rm:*)", "Bash(curl:*)", "Bash(open:*)", "Bash(find:*)", "Bash(ls:*)",
    ]

    /// An empty scratch directory so relative paths never touch user data.
    static var scratchDirectory: String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whoru-claude-code", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    /// Well-known install locations, checked in order.
    public static let searchPaths = [
        "~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "~/.claude/local/claude",
    ]

    /// Finds the CLI without spawning a shell.
    public static func locate(extraPaths: [String] = []) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for raw in extraPaths + searchPaths {
            let path = raw.replacingOccurrences(of: "~", with: home)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        if let pathVar = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathVar.split(separator: ":") {
                let candidate = "\(dir)/claude"
                if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        return nil
    }

    public static func version(of executable: String) async -> String? {
        guard let output = try? await Command.run(executable, ["--version"], timeout: .seconds(10)), output.succeeded else { return nil }
        return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func analyze(_ request: AnalysisRequest, tools: any AnalystToolRunner, onEvent: @escaping @Sendable (AnalysisEvent) -> Void) async throws -> AnalysisResult {
        let modelArgument = model.isEmpty ? request.model : model
        onEvent(.started(model: modelArgument))
        let prompt = AnalystPrompt.userMessage(for: request.bundle) + "\n\n" + AnalystPrompt.schemaInstruction()
        let output = try await run([
            "-p", prompt,
            "--output-format", "json",
            "--model", modelArgument,
            "--append-system-prompt", AnalystPrompt.systemPrompt + "\n\nYou may only run the metadata commands you were given, on the paths named in the evidence bundle. Do not read file contents and do not look at the user's other files or folders.",
            "--allowedTools", Self.allowedTools.joined(separator: ","),
            "--disallowedTools", Self.disallowedTools.joined(separator: ","),
            "--permission-mode", "default",
        ])
        let (text, sessionID, usage) = try Self.parse(output)
        guard let object = PartialJSON.firstObject(in: text) else { throw AnalystError.invalidResponse("no JSON object in answer") }
        let verdict: Verdict
        do {
            verdict = try JSONDecoder().decode(Verdict.self, from: Data(object.utf8))
        } catch {
            throw AnalystError.invalidResponse("verdict did not match schema: \(error)")
        }
        onEvent(.usage(inputTokens: usage.input, outputTokens: usage.output))
        return AnalysisResult(
            verdict: verdict, model: modelArgument, inputTokens: usage.input, outputTokens: usage.output, costUSD: usage.cost,
            session: AnalystSession(engine: id, model: modelArgument, payload: ["session_id": .string(sessionID)]),
            toolCalls: []
        )
    }

    public func reply(to question: String, session: AnalystSession, request: AnalysisRequest, tools: any AnalystToolRunner, onEvent: @escaping @Sendable (AnalysisEvent) -> Void) async throws -> ChatReply {
        guard let sessionID = session.payload["session_id"]?.stringValue else { throw AnalystError.notConfigured("no Claude Code session to resume") }
        onEvent(.started(model: request.model))
        // The system prompt is not part of the resumed session; without it the
        // CLI falls back to its coding-assistant persona.
        let output = try await run([
            "-p", question,
            "--resume", sessionID,
            "--output-format", "json",
            "--append-system-prompt", AnalystPrompt.systemPrompt + "\n\n" + AnalystPrompt.chatSystemAddendum(),
            "--allowedTools", Self.allowedTools.joined(separator: ","),
            "--disallowedTools", Self.disallowedTools.joined(separator: ","),
            "--permission-mode", "default",
        ])
        let (text, newSessionID, usage) = try Self.parse(output)
        onEvent(.text(text))
        return ChatReply(
            text: text,
            session: AnalystSession(engine: id, model: request.model, payload: ["session_id": .string(newSessionID)]),
            inputTokens: usage.input, outputTokens: usage.output, costUSD: usage.cost, toolCalls: []
        )
    }

    private func run(_ arguments: [String]) async throws -> CommandOutput {
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        // Allow running from inside another Claude Code session (development, CI).
        environment["CLAUDECODE"] = nil
        environment["CLAUDE_CODE_ENTRYPOINT"] = nil
        let output = try await Command.run(executable, arguments, timeout: hardTimeout, environment: environment, workingDirectory: Self.scratchDirectory)
        if output.timedOut { throw AnalystError.timeout }
        guard output.status == 0 else { throw AnalystError.invalidResponse("claude exited \(output.status): \(output.stderr.prefix(300))") }
        return output
    }

    struct Usage { var input: Int; var output: Int; var cost: Double }

    static func parse(_ output: CommandOutput) throws -> (String, String, Usage) {
        let json = try JSONValue.parse(output.stdout)
        if json["is_error"]?.boolValue == true {
            throw AnalystError.invalidResponse(json["result"]?.stringValue ?? "claude reported an error")
        }
        let text = json["result"]?.stringValue ?? ""
        let sessionID = json["session_id"]?.stringValue ?? ""
        let usage = Usage(
            input: json["usage"]?["input_tokens"]?.intValue ?? 0,
            output: json["usage"]?["output_tokens"]?.intValue ?? 0,
            cost: json["total_cost_usd"]?.doubleValue ?? 0
        )
        return (text, sessionID, usage)
    }
}
