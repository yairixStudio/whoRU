import Foundation

/// Uses an installed Claude Code CLI in headless mode. Zero setup for people
/// who already have it. The CLI runs as its own responsible process (no
/// permission of whoRU's reaches it), with no user settings, hooks, MCP
/// servers or slash commands, and the only Bash command it may run is the
/// `whoru-inspect` shim, which inspects the program under review and nothing else.
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

    /// The shim's subcommands, repeated here so the system prompt can list them.
    public static let inspectSubcommands = ["signature", "gatekeeper", "libraries", "headers", "plist", "attributes", "process", "network", "files", "help"]

    /// The one Bash command the model may run. Earlier versions allowed the
    /// system tools themselves (codesign, otool, plutil, ps, lsof, ...) and
    /// that was too much: otool dumps any binary's strings, plutil reads any
    /// plist, ps and lsof see every process. The shim takes a subcommand and
    /// nothing else; the subject comes from environment variables we set.
    /// Nil when the shim is not installed next to us, in which case the model
    /// gets no commands at all.
    public static func allowedTools(inspectShim: String?) -> [String] {
        inspectShim.map { ["Bash(\($0):*)"] } ?? []
    }

    /// Where the shim must be: next to the running executable. That is
    /// `Contents/MacOS` inside the app, or `.build/<config>` for a package build.
    public static func locateInspectShim(near directory: URL? = Bundle.main.executableURL?.deletingLastPathComponent()) -> String? {
        guard let directory else { return nil }
        let candidate = directory.appendingPathComponent("whoru-inspect").path
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

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
        guard let output = try? await Command.run(executable, ["--version"], timeout: .seconds(10), disclaimResponsibility: true), output.succeeded else { return nil }
        return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Flags that keep the CLI to what we hand it: no user, project or local
    /// settings (so no hooks), no MCP servers, no slash commands. Tested with
    /// 2.1.259; sign-in survives them.
    static let isolationArguments = ["--setting-sources", "", "--strict-mcp-config", "--disable-slash-commands"]

    /// Environment that names the subject for the shim. Only paths and a pid;
    /// the shim checks that the path exists before it runs anything. The
    /// request's bundle was redacted for the model (home became `~`), so the
    /// paths are expanded again here: the shim needs real ones.
    static func subjectEnvironment(for subject: Subject?, homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String: String] {
        guard var subject else { return [:] }
        func expand(_ path: String) -> String {
            path == "~" ? homeDirectory : path.hasPrefix("~/") ? homeDirectory + path.dropFirst() : path
        }
        subject.path = expand(subject.path)
        subject.bundlePath = subject.bundlePath.map(expand)
        var env = ["WHORU_SUBJECT_PATH": subject.verificationPath, "WHORU_SUBJECT_EXECUTABLE": Sha256Check.executablePath(for: subject)]
        if let pid = subject.pid { env["WHORU_SUBJECT_PID"] = String(pid) }
        return env
    }

    /// What the model is told about its one command.
    static func toolInstruction(inspectShim: String?) -> String {
        guard let inspectShim else {
            return "You have no commands available in this session. Answer from the evidence bundle."
        }
        return "The only command available to you is \(inspectShim), which inspects the program under review and takes exactly one argument, a subcommand: \(inspectSubcommands.joined(separator: ", ")). It accepts no paths; the subject is fixed. Do not read file contents and do not look at the user's other files or folders."
    }

    public func analyze(_ request: AnalysisRequest, tools: any AnalystToolRunner, onEvent: @escaping @Sendable (AnalysisEvent) -> Void) async throws -> AnalysisResult {
        let modelArgument = model.isEmpty || model == "custom" ? request.model : model
        onEvent(.started(model: modelArgument))
        let prompt = AnalystPrompt.userMessage(for: request.bundle) + "\n\n" + AnalystPrompt.schemaInstruction()
        let shim = Self.locateInspectShim()
        let output = try await run([
            "-p", prompt,
            "--output-format", "json",
            "--model", modelArgument,
            "--append-system-prompt", AnalystPrompt.systemPrompt + "\n\n" + Self.toolInstruction(inspectShim: shim),
            "--allowedTools", Self.allowedTools(inspectShim: shim).joined(separator: ","),
            "--disallowedTools", Self.disallowedTools.joined(separator: ","),
            "--permission-mode", "default",
        ] + Self.isolationArguments, subject: request.bundle.subject, inspectShim: shim)
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
        let shim = Self.locateInspectShim()
        let output = try await run([
            "-p", question,
            "--resume", sessionID,
            "--output-format", "json",
            "--append-system-prompt", AnalystPrompt.systemPrompt + "\n\n" + AnalystPrompt.chatSystemAddendum() + "\n\n" + Self.toolInstruction(inspectShim: shim),
            "--allowedTools", Self.allowedTools(inspectShim: shim).joined(separator: ","),
            "--disallowedTools", Self.disallowedTools.joined(separator: ","),
            "--permission-mode", "default",
        ] + Self.isolationArguments, subject: request.bundle.subject, inspectShim: shim)
        let (text, newSessionID, usage) = try Self.parse(output)
        onEvent(.text(text))
        return ChatReply(
            text: text,
            session: AnalystSession(engine: id, model: request.model, payload: ["session_id": .string(newSessionID)]),
            inputTokens: usage.input, outputTokens: usage.output, costUSD: usage.cost, toolCalls: []
        )
    }

    private func run(_ arguments: [String], subject: Subject?, inspectShim: String?) async throws -> CommandOutput {
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        // Allow running from inside another Claude Code session (development, CI).
        environment["CLAUDECODE"] = nil
        environment["CLAUDE_CODE_ENTRYPOINT"] = nil
        environment.merge(Self.subjectEnvironment(for: subject)) { _, subject in subject }
        if inspectShim == nil {
            AppLog.shared.warn("claude-code", "whoru-inspect not found next to \(Bundle.main.executableURL?.path ?? "the executable"); the agent runs without commands")
        }
        // Disclaimed: the CLI lives in a user-writable directory and loads
        // nothing of ours, so it must not inherit our permissions either.
        let output = try await Command.run(executable, arguments, timeout: hardTimeout, environment: environment, workingDirectory: Self.scratchDirectory, disclaimResponsibility: true)
        if output.timedOut { throw AnalystError.timeout }
        guard output.status == 0 else {
            let text = (output.stdout + output.stderr).lowercased()
            if text.contains("not logged in") || text.contains("login") || text.contains("authenticat") || text.contains("api key") {
                throw AnalystError.notConfigured("Claude Code is not signed in. Sign in from Settings → AI.")
            }
            throw AnalystError.invalidResponse("claude exited \(output.status): \(output.stderr.prefix(300))")
        }
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
