import Foundation
import WhoRUCore
#if os(macOS)
import WhoRUMac
#endif

/// The scan pipeline without a window. Used for development, for tests, and
/// by people who prefer a terminal.
@main
struct CLI {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else { usage(); exit(2) }
        args.removeFirst()
        do {
            switch command {
            case "scan": try await scan(args)
            case "parse": parse(args)
            case "resolve": try await resolve(args)
            case "doctor": await doctor()
            case "history": try await history(args)
            case "-h", "--help", "help": usage()
            default:
                Output.error("unknown command: \(command)")
                usage()
                exit(2)
            }
        } catch {
            Output.error(String(describing: error))
            exit(1)
        }
    }

    static func usage() {
        print("""
        whoru-cli – who is really asking?

        usage:
          whoru-cli scan <path | requester name> [--service <name>] [--json] [--no-ai] [--no-store] [--engine auto|claudeCode|claudeAPI|codex|gemini|local] [--model <name>] [--depth fast|balanced|deep] [--locale <tag>] [--slow]
          whoru-cli parse "<dialog title>" ["<dialog body>"]
          whoru-cli resolve "<requester name>"
          whoru-cli history [--limit N]
          whoru-cli doctor

        services: \(PermissionService.allCases.map(\.shortName).joined(separator: ", "))
        """)
    }

    // MARK: scan

    static func scan(_ args: [String]) async throws {
        var options = Options(args)
        guard let target = options.positional.first else { usage(); exit(2) }
        let json = options.flag("--json")
        let noAI = options.flag("--no-ai")
        let noStore = options.flag("--no-store")
        let slow = options.flag("--slow")
        let serviceName = options.value("--service") ?? "other"
        guard let service = PermissionService(shortName: serviceName) else {
            Output.error("unknown service \(serviceName)"); exit(2)
        }
        let locale = options.value("--locale") ?? Locale.preferredLanguages.first ?? "en"

        #if os(macOS)
        let paths = DefaultPaths()
        var settings = loadSettings(paths: paths)
        AppLog.shared.configure(directory: FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!.appendingPathComponent("Logs/whoRU", isDirectory: true))
        AppLog.shared.echoToStderr = options.flag("--verbose")
        if noAI { settings.engine = .none }
        // A scan typed at the command line is itself a request; the app's
        // "ask automatically" switch is about dialogs.
        settings.askModelAutomatically = true
        if let engine = options.value("--engine").flatMap(EngineChoice.init(rawValue:)) { settings.engine = engine }
        if let modelName = options.value("--model") { settings.engineModels[settings.engine.rawValue] = modelName }
        if let depth = options.value("--depth").flatMap(AnalysisDepth.init(rawValue:)) { settings.depth = depth }
        let store: (any ScanStore)? = noStore ? nil : JSONFileScanStore(paths: paths)
        let environment = await MacEnvironment.environment(settings: settings, store: store, locale: locale)

        let expanded = (target as NSString).expandingTildeInPath
        var presetSubject: Subject?
        let requesterName: String
        if FileManager.default.fileExists(atPath: expanded) {
            let path = URL(fileURLWithPath: expanded).standardizedFileURL.path
            let bundle = BundleInfo.read(bundlePath: path) ?? BundleInfo.read(containing: path)
            let running = (try? await MacProcessInspector().runningProcesses()) ?? []
            let executable = bundle.flatMap { b in b.executable.map { "\(b.bundlePath)/Contents/MacOS/\($0)" } } ?? path
            let pid = running.first { $0.path == executable || $0.path == path }?.pid
            presetSubject = Subject(path: path, pid: pid, bundleID: bundle?.identifier, displayName: bundle?.displayName ?? (path as NSString).lastPathComponent,
                                    version: bundle?.shortVersion, bundlePath: bundle?.bundlePath, resolver: ResolverOutcome(strategy: "manual_path", confidence: .high))
            requesterName = presetSubject!.displayName
        } else {
            requesterName = target
        }
        let phrase = PromptParser.serviceKeywords.first { $0.0 == service }?.1.first.map { "access \($0)" } ?? "access \(service.shortName)"
        let prompt = PermissionPrompt(title: "“\(requesterName)” would like to \(phrase).", requesterName: requesterName, service: service, requestPhrase: phrase, locale: locale)

        let started = Date()
        let progress = json ? Output.stderr : Output.stdout
        let pipeline = ScanPipeline(environment: environment)
        var record = await pipeline.run(prompt: prompt, presetSubject: presetSubject) { event in
            Self.report(event, since: started, to: progress)
        }
        if slow {
            record = await pipeline.runSlowChecks(record: record) { event in Self.report(event, since: started, to: progress) }
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            print(String(decoding: try encoder.encode(record), as: UTF8.self))
        }
        #else
        Output.error("scan needs a platform module; only parse is available on this OS")
        exit(1)
        #endif
    }

    static func report(_ event: ScanEvent, since started: Date, to out: Output) {
        let t = String(format: "%6.2fs", Date().timeIntervalSince(started))
        switch event {
        case .resolved(let subject, let candidates):
            if let subject {
                out.line("\(t)  \(Output.dim("subject"))  \(subject.displayName) · \(subject.path)  [\(subject.resolver.strategy), \(subject.resolver.confidence.rawValue)]")
            } else {
                out.line("\(t)  \(Output.dim("subject"))  not identified")
            }
            if candidates.count > 1 { out.line("        \(candidates.count) candidates: \(candidates.map(\.path).joined(separator: ", "))") }
        case .evidence(let item):
            out.line("\(t)  \(Output.mark(item.status)) \(item.key.rawValue.padding(toLength: 18, withPad: " ", startingAt: 0)) \(item.summary)")
        case .hardScore(let hard, let headline):
            out.line("\(t)  \(Output.score(hard.score)) \(Output.bold(headline.title)) — \(headline.sentence)")
        case .cached(let record):
            out.line("\(t)  \(Output.dim("cache"))    verdict from \(record.startedAt.formatted(date: .abbreviated, time: .shortened))")
        case .analysis(let a):
            switch a {
            case .started(let model): out.line("\(t)  \(Output.dim("model"))    \(model)")
            case .partialHeadline(let h): out.line("\(t)  \(Output.dim("headline")) \(h)")
            case .toolCall(let name, _): out.line("\(t)  \(Output.dim("tool"))     \(name)…")
            case .toolResult(let name, let summary): out.line("\(t)  \(Output.dim("tool"))     \(name): \(summary)")
            case .text, .usage: break
            }
        case .verdict(let v):
            out.line("")
            out.line("\(t)  \(Output.bold(VerdictPresentation.forVerdict(v.verdict, locale: "en").title)) · \(v.confidence)% · \(v.recommendation.rawValue) · fit: \(v.fit.rawValue)")
            out.line("        \(v.headline)")
            out.line("        \(Output.dim("what:"))  \(v.whatItIs)")
            out.line("        \(Output.dim("why:"))   \(v.whyItAsks)")
            out.line("        \(Output.dim("deny:"))  \(v.ifDenied)")
            for r in v.reasons { out.line("        \(r.kind == .evidence ? "•" : "∘") \(r.text)\(r.ref.map { " [\($0)]" } ?? "")") }
            for q in v.suggestedQuestions { out.line("        ? \(q)") }
        case .verdictRejected(let reason):
            out.line("\(t)  \(Output.red("rejected")) the model contradicted hard evidence: \(reason)")
        case .analysisSkipped(let reason):
            out.line("\(t)  \(Output.dim("model"))    skipped: \(reason)")
        case .analysisFailed(let error):
            out.line("\(t)  \(Output.red("model"))    failed: \(error)")
        case .finished(let record):
            if record.costUSD > 0 { out.line("\(t)  \(Output.dim("cost"))     $\(String(format: "%.4f", record.costUSD)) · \(record.inputTokens) in / \(record.outputTokens) out · \(record.model ?? "")") }
            out.line("\(t)  \(Output.dim("done"))     \(record.id.uuidString.lowercased())")
        }
    }

    #if os(macOS)
    /// The app's settings, checked against the app's signature when the key
    /// can be read. The key is never created here: the tool is signed
    /// differently from the app, so the Keychain may ask or refuse, and a
    /// terminal command must not depend on that. Without the key the file is
    /// used unverified.
    static func loadSettings(paths: DefaultPaths) -> Settings {
        let key = IntegrityKey.load(from: MacEnvironment.secrets(), createIfMissing: false)
        let store = JSONFileSettingsStore(paths: paths, integrity: FileIntegrity(key: key))
        guard let loaded = try? store.loadChecked() else { return Settings() }
        if loaded.state == .tampered {
            Output.stderr.line("warning: settings.json was changed outside whoRU; using defaults")
        }
        return loaded.settings
    }
    #endif

    // MARK: parse / resolve / history / doctor

    static func parse(_ args: [String]) {
        guard let title = args.first else { usage(); exit(2) }
        let body = args.dropFirst().first
        if let parsed = PromptParser().parse(title: title, body: body) {
            print("requester: \(parsed.requester)")
            print("service:   \(parsed.service.shortName) (\(parsed.service.rawValue))")
            print("phrase:    \(parsed.phrase)")
            if let target = parsed.target { print("target:    \(target)") }
            print("pattern:   #\(parsed.patternIndex) (\(parsed.locale))")
        } else {
            print("no pattern matched. Contribute this text as a fixture: see CONTRIBUTING.md")
            exit(1)
        }
    }

    static func resolve(_ args: [String]) async throws {
        guard let name = args.first else { usage(); exit(2) }
        #if os(macOS)
        let resolver = RequesterResolver(processes: MacProcessInspector(), finder: MacApplicationFinder())
        let prompt = PermissionPrompt(title: "“\(name)” would like to access something.", requesterName: name, service: .other, requestPhrase: "access something")
        let result = await resolver.resolve(prompt)
        if let s = result.subject {
            print("\(s.displayName)\n  path:     \(s.path)\n  bundle:   \(s.bundlePath ?? "-")\n  id:       \(s.bundleID ?? "-")\n  pid:      \(s.pid.map(String.init) ?? "-")\n  strategy: \(s.resolver.strategy) (\(s.resolver.confidence.rawValue))")
        } else {
            print("not identified")
        }
        for c in result.candidates { print("  candidate: \(c.path) [\(c.strategy), \(c.confidence.rawValue)]") }
        #endif
    }

    static func history(_ args: [String]) async throws {
        var options = Options(args)
        let limit = Int(options.value("--limit") ?? "20") ?? 20
        let store = JSONFileScanStore(paths: DefaultPaths())
        let records = try await store.all().prefix(limit)
        if records.isEmpty { print("no scans yet"); return }
        for r in records {
            let title = r.bestHeadline?.title ?? "—"
            print("\(r.startedAt.formatted(date: .abbreviated, time: .shortened))  \(Output.score(r.hardScore?.score ?? .amber)) \(title.padding(toLength: 16, withPad: " ", startingAt: 0)) \(r.subject?.displayName ?? r.prompt.requesterName) · \(r.prompt.service.shortName)\(r.fromCache ? " (cache)" : "")\(r.costUSD > 0 ? String(format: " $%.4f", r.costUSD) : "")")
        }
    }

    static func doctor() async {
        #if os(macOS)
        let paths = DefaultPaths()
        let settings = loadSettings(paths: paths)
        let secrets = MacEnvironment.secrets()
        print("data:            \(paths.applicationSupport.path)")
        print("log:             ~/Library/Logs/whoRU/whoru.log")
        print("engine setting:  \(settings.engine.rawValue), depth \(settings.depth.rawValue) → \(settings.depth.modelID)")
        if let path = settings.claudeCodePath ?? ClaudeCodeAnalyst.locate() {
            let trusted = await ClaudeCodeVerifier.isTrusted(path)
            let version = await ClaudeCodeAnalyst.version(of: path) ?? "?"
            print("claude code:     \(path) · \(version) · \(trusted ? "signature verified (Anthropic)" : "NOT verified")")
        } else {
            print("claude code:     not found")
        }
        if let path = settings.codexPath ?? CodexAnalyst.locate() {
            print("codex cli:       \(path) · \(await CodexAnalyst.version(of: path) ?? "?")")
        } else {
            print("codex cli:       not found")
        }
        if let path = settings.geminiPath ?? GeminiAnalyst.locate() {
            print("gemini cli:      \(path) · \(await GeminiAnalyst.version(of: path) ?? "?")")
        } else {
            print("gemini cli:      not found")
        }
        print("apple intel.:    \(AppleFoundationAnalyst.unavailabilityReason() ?? "available (on-device)")")
        print("api key:         \(secrets.secret(.anthropicAPIKey) != nil ? "present" : "none")")
        print("virustotal key:  \(secrets.secret(.virusTotalAPIKey) != nil ? "present" : "none")")
        let analyst = await MacEnvironment.analyst(settings: settings, secrets: secrets)
        print("active engine:   \(analyst?.id ?? "none (evidence only)")")
        print("accessibility:   \(AccessibilityPermission.isGranted ? "granted" : "not granted (the app cannot watch dialogs)")")
        if let store = Optional(JSONFileScanStore(paths: paths)), let count = try? await store.all().count {
            print("scans stored:    \(count)")
        }
        #endif
    }
}

struct Options {
    var positional: [String] = []
    private var flags: Set<String> = []
    private var values: [String: String] = [:]

    init(_ args: [String]) {
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            if arg.hasPrefix("--") {
                if ["--json", "--no-ai", "--no-store", "--slow", "--verbose"].contains(arg) {
                    flags.insert(arg)
                } else if let value = iterator.next() {
                    values[arg] = value
                }
            } else {
                positional.append(arg)
            }
        }
    }

    mutating func flag(_ name: String) -> Bool { flags.contains(name) }
    mutating func value(_ name: String) -> String? { values[name] }
}

struct Output: Sendable {
    static let stdout = Output(handle: .standardOutput)
    static let stderr = Output(handle: .standardError)
    static let color = isatty(1) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil

    let handle: FileHandle

    func line(_ text: String) {
        handle.write(Data((text + "\n").utf8))
    }

    static func error(_ text: String) { stderr.line("error: \(text)") }

    static func mark(_ status: EvidenceStatus) -> String {
        switch status {
        case .pass: green("✔")
        case .warn: yellow("▲")
        case .fail: red("✘")
        case .info: dim("·")
        case .neutral: dim("○")
        case .skipped: dim("–")
        case .error: red("!")
        }
    }

    static func score(_ score: HardScore) -> String {
        switch score {
        case .green: green("GREEN")
        case .amber: yellow("AMBER")
        case .red: red("RED  ")
        }
    }

    static func bold(_ s: String) -> String { color ? "\u{1B}[1m\(s)\u{1B}[0m" : s }
    static func dim(_ s: String) -> String { color ? "\u{1B}[2m\(s)\u{1B}[0m" : s }
    static func green(_ s: String) -> String { color ? "\u{1B}[32m\(s)\u{1B}[0m" : s }
    static func yellow(_ s: String) -> String { color ? "\u{1B}[33m\(s)\u{1B}[0m" : s }
    static func red(_ s: String) -> String { color ? "\u{1B}[31m\(s)\u{1B}[0m" : s }
}
