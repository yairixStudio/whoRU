import AppKit
import Foundation
import Observation
import ServiceManagement
import WhoRUCore
import WhoRUMac

/// Application-wide state: settings, store, the scan environment and the
/// sessions currently on screen.
@MainActor
@Observable
final class AppModel {
    let paths = DefaultPaths()
    let settingsStore: JSONFileSettingsStore
    let publisherStore: PublisherOverridesStore
    let store: JSONFileScanStore
    let secrets: any SecretStore = MacEnvironment.secrets()
    /// One plain sentence when a store file failed its signature at launch and
    /// was ignored; Settings shows it until the user dismisses it.
    var integrityWarning: String?

    var settings: Settings {
        didSet {
            try? settingsStore.save(settings)
            environmentTask = nil
            applyLaunchAtLogin()
            if oldValue.engine != settings.engine || oldValue.localOnly != settings.localOnly || oldValue.engineModels != settings.engineModels
                || oldValue.depth != settings.depth || oldValue.askModelAutomatically != settings.askModelAutomatically {
                Task { await refreshEngineDescription() }
            }
        }
    }

    /// The user's trust decisions and additions, merged over the built-in list.
    var publisherOverrides: [Publisher] = [] {
        didSet {
            try? publisherStore.save(publisherOverrides)
            environmentTask = nil
        }
    }

    var publisherDirectory: PublisherDirectory { PublisherDirectory(overrides: publisherOverrides) }

    func setTrust(_ trust: PublisherTrust, for publisher: Publisher) {
        var override = publisherOverrides.first { $0.teamID == publisher.teamID } ?? Publisher(teamID: publisher.teamID, name: publisher.name, source: .user)
        override.trust = trust
        publisherOverrides.removeAll { $0.teamID == publisher.teamID }
        if trust != .normal || publisher.source != .builtin { publisherOverrides.append(override) }
    }

    var sessions: [ScanSession] = []
    var lastSession: ScanSession?
    var pausedUntil: Date?
    var watcherRunning = false
    var accessibilityGranted = AccessibilityPermission.isGranted
    var engineDescription = "…"
    /// `Analyst.id` of the engine that runs automatically; `nil` when the
    /// agent is off or nothing usable is installed.
    var currentAnalystID: String?
    /// Agents that can answer a request made by hand, in order of preference:
    /// the chosen one, or, with the agent set to None, whatever is usable on
    /// this Mac so the user can pick one for a single scan.
    var onDemandAgents: [EngineChoice] = []
    var monthlySpend: Double = 0

    private var environmentTask: Task<ScanEnvironment, Never>?

    init() {
        // The app owns the signing key: created in the Keychain on first
        // launch, so files from an earlier version are trusted once, then signed.
        let integrity = FileIntegrity(key: IntegrityKey.load(from: MacEnvironment.secrets(), createIfMissing: true))
        settingsStore = JSONFileSettingsStore(paths: paths, integrity: integrity)
        publisherStore = PublisherOverridesStore(paths: paths, integrity: integrity)
        store = JSONFileScanStore(paths: paths)
        let loadedSettings = (try? settingsStore.loadChecked()) ?? (Settings(), .unverifiable)
        settings = loadedSettings.settings
        var warnings: [String] = []
        if loadedSettings.state == .tampered {
            warnings.append("Your settings file was changed outside whoRU and was ignored.")
            AppLog.shared.error("integrity", "settings.json failed its signature; defaults used")
        } else if loadedSettings.state == .missingSignature {
            // Sign it now rather than trusting it again at every launch.
            try? settingsStore.save(settings)
        }
        let loadedPublishers = (try? publisherStore.load()) ?? ([], .unverifiable)
        publisherOverrides = loadedPublishers.publishers
        if loadedPublishers.state == .tampered {
            warnings.append("Your publisher trust list was changed outside whoRU and was ignored.")
            AppLog.shared.error("integrity", "publishers.json failed its signature; overrides ignored")
        } else if loadedPublishers.state == .missingSignature {
            try? publisherStore.save(publisherOverrides)
        }
        integrityWarning = warnings.isEmpty ? nil : warnings.joined(separator: " ")
        Task { await refreshEngineDescription() }
        Task { monthlySpend = (try? await store.monthlySpend()) ?? 0 }
        // Retention 0 means forever.
        if settings.historyRetentionDays > 0 {
            let days = settings.historyRetentionDays
            Task { try? await store.purge(olderThan: days) }
        }
    }

    var isPaused: Bool { pausedUntil.map { $0 > Date() } ?? false }

    static var logDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/whoRU", isDirectory: true)
    }

    /// Everything a bug report needs, without secrets: versions, engine,
    /// settings, permission state and the last few hundred log lines.
    func diagnosticsReport() async -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        var lines = [
            "whoRU \(version) (\(build)) · \(Bundle.main.bundlePath)",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Accessibility: \(AccessibilityPermission.isGranted ? "granted" : "not granted") · watcher \(watcherRunning ? "running" : "stopped")",
            "Engine: \(engineDescription) (setting: \(settings.engine.rawValue), depth \(settings.depth.rawValue), strictness \(settings.strictness.rawValue))",
            "Claude Code: \(ClaudeCodeAnalyst.locate() ?? "not found") · Codex: \(CodexAnalyst.locate() ?? "not found") · Gemini: \(GeminiAnalyst.locate() ?? "not found")",
            "API key: \(secrets.secret(.anthropicAPIKey) != nil ? "saved" : "none") · VirusTotal key: \(secrets.secret(.virusTotalAPIKey) != nil ? "saved" : "none")",
            "Sessions on screen: \(sessions.count) · scans stored: \((try? await store.all().count) ?? 0) · spend this month: $\(String(format: "%.2f", monthlySpend))",
            "",
            "--- settings.json ---",
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        lines.append((try? String(decoding: encoder.encode(settings), as: UTF8.self)) ?? "(unavailable)")
        lines.append("")
        lines.append("--- last \(min(300, AppLog.shared.recentLines().count)) log lines ---")
        lines += AppLog.shared.recentLines(300)
        return lines.joined(separator: "\n")
    }

    /// The environment scans run in. With `engine`, one built for a request
    /// the user makes by hand with that agent; not cached.
    func environment(engine: EngineChoice? = nil) async -> ScanEnvironment {
        let settings = settings
        let store = store
        let publishers = publisherDirectory
        let locale = Locale.preferredLanguages.first ?? "en"
        if let engine {
            return await MacEnvironment.environment(settings: settings, store: store, publishers: publishers, locale: locale, engine: engine)
        }
        if let task = environmentTask { return await task.value }
        let task = Task { await MacEnvironment.environment(settings: settings, store: store, publishers: publishers, locale: locale) }
        environmentTask = task
        return await task.value
    }

    /// The environment that can continue a session's conversation: the
    /// automatic one, or the agent that answered when the user asked by hand.
    private func environment(for session: ScanSession) async -> ScanEnvironment {
        if let id = session.record?.analystSession?.engine, id != currentAnalystID, let engine = EngineChoice(analystID: id) {
            return await environment(engine: engine)
        }
        return await environment()
    }

    func refreshEngineDescription() async {
        let env = await environment()
        currentAnalystID = env.analyst?.id
        AppLog.shared.info("app", "engine: \(env.analyst?.id ?? "none") (setting \(settings.engine.rawValue))")
        if let analyst = env.analyst {
            engineDescription = describe(analyst.id)
        } else if settings.localOnly {
            engineDescription = "Evidence only · local-only mode"
        } else {
            engineDescription = settings.engine == .none ? "Evidence only · AI on request" : "Evidence only · no AI agent found"
        }
        onDemandAgents = await detectOnDemandAgents()
        if env.analyst == nil, settings.engine == .none, onDemandAgents.isEmpty {
            engineDescription = "Evidence only, no AI"
        }
        monthlySpend = (try? await store.monthlySpend()) ?? 0
    }

    /// "Claude Code · Claude Opus 5", for the menu and the Ask AI button.
    func describe(_ analystID: String) -> String {
        func chosen(_ engine: EngineChoice) -> String { engine.modelDisplayName(settings.model(for: engine)) }
        switch analystID {
        case "claude-code": return "Claude Code · \(chosen(.claudeCode))"
        case "claude-api": return "Claude API · \(settings.depth.modelID)"
        case "codex": return "Codex CLI · \(chosen(.codex))"
        case "gemini": return "Gemini CLI · \(chosen(.gemini))"
        case "apple": return "Apple Intelligence · on-device"
        case "local": return "Local model · \(settings.localModelName)"
        default: return analystID
        }
    }

    func describe(_ engine: EngineChoice) -> String {
        engine.analystID.map(describe) ?? engine.displayName
    }

    private func detectOnDemandAgents() async -> [EngineChoice] {
        if settings.engine != .none {
            // The chosen agent; if it is unusable the environment falls back by itself.
            return [settings.engine == .auto ? (currentAnalystID.flatMap(EngineChoice.init(analystID:)) ?? .auto) : settings.engine]
        }
        var usable = await AgentStatus.detectAll(settings: settings).filter(\.isUsable).map(\.engine)
        if secrets.secret(.anthropicAPIKey) != nil { usable.append(.claudeAPI) }
        if settings.localOnly { usable = usable.filter(\.isOnDevice) }
        return usable
    }

    // MARK: Scans

    @discardableResult
    func startScan(for dialog: DialogInstance) -> ScanSession {
        let parser = PromptParser()
        let prompt = parser.makePrompt(title: dialog.title, body: dialog.body)
            ?? PermissionPrompt(title: dialog.title, body: dialog.body, requesterName: dialog.title.isEmpty ? "Unreadable dialog" : dialog.title, service: .other, requestPhrase: "", locale: "und")
        let session = ScanSession(id: dialog.id, dialog: dialog, prompt: prompt, rawTitle: dialog.title)
        sessions.append(session)
        lastSession = session
        // A window that reads like a prompt but was not drawn by a system
        // dialog process is an impostor. The pipeline is not run: scanning the
        // program the window names would put a green badge next to a fake.
        if case .unverified(let owner, let path, let signer) = dialog.origin {
            markFakeDialog(session, owner: owner, path: path, signer: signer)
            return session
        }
        // The same program asking for the same thing again within a minute
        // (a cascade of prompts, or a re-shown dialog) reuses the scan in flight
        // instead of starting another model run. A fake dialog is never a twin:
        // a genuine prompt must not inherit an impostor's verdict, nor the other
        // way round, so an attacker cannot poison a real scan by drawing a fake
        // one with the same name first.
        if let twin = sessions.first(where: { $0 !== session && !$0.isFakeDialog && $0.prompt.requesterName == prompt.requesterName && $0.prompt.service == prompt.service && Date().timeIntervalSince($0.startedAt) < 60 }) {
            session.mirror(twin)
            return session
        }
        if parser.parse(title: dialog.title) != nil {
            run(session, presetSubject: nil)
        } else {
            // Unknown wording: show the raw text and let the user pick a file.
            session.hardScore = HardScoreResult(score: .amber, reasons: [ScoreReason(code: "unresolved")])
            session.headline = HeadlineComposer().headline(for: session.hardScore!, subject: nil, prompt: prompt, locale: prompt.locale)
            session.analysis = .skipped("dialog text not recognized")
        }
        return session
    }

    @discardableResult
    func startManualScan(path: String, service: PermissionService) -> ScanSession {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        let bundle = BundleInfo.read(bundlePath: standardized) ?? BundleInfo.read(containing: standardized)
        let name = bundle?.displayName ?? (standardized as NSString).lastPathComponent
        let phrase = PromptParser.serviceKeywords.first { $0.0 == service }?.1.first.map { "access \($0)" } ?? "access \(service.shortName)"
        let prompt = PermissionPrompt(title: "“\(name)” would like to \(phrase).", requesterName: name, service: service, requestPhrase: phrase, locale: Locale.preferredLanguages.first ?? "en")
        let subject = Subject(path: standardized, bundleID: bundle?.identifier, displayName: name, version: bundle?.shortVersion, bundlePath: bundle?.bundlePath,
                              resolver: ResolverOutcome(strategy: "manual_path", confidence: .high))
        let session = ScanSession(id: UUID().uuidString, dialog: nil, prompt: prompt, rawTitle: prompt.title)
        session.isManual = true
        sessions.append(session)
        lastSession = session
        run(session, presetSubject: subject)
        return session
    }

    /// Scores a window that only pretends to be a permission dialog: red, no
    /// pipeline, no model. The panel names the program that drew it.
    private func markFakeDialog(_ session: ScanSession, owner: String, path: String?, signer: String?) {
        let prompt = session.prompt
        let signerClause = signer.map { L10n.text("reason.dialog.fake.signer", locale: prompt.locale, ["signer": $0]) } ?? ""
        let hard = HardScoreResult(score: .red, reasons: [ScoreReason(code: "dialog.fake", params: ["owner": owner, "signer": signerClause])])
        session.hardScore = hard
        session.headline = HeadlineComposer().headline(for: hard, subject: nil, prompt: prompt, locale: prompt.locale)
        session.evidence = [
            EvidenceItem(key: "window.owner", status: .fail, weight: .decisive, summary: path ?? owner,
                         raw: "owner: \(owner)\npid: \(session.dialog?.pid ?? 0)\nexecutable: \(path ?? "unknown")", method: "CGWindowListCopyWindowInfo, proc_pidpath"),
            EvidenceItem(key: "window.signer", status: signer == nil ? .warn : .info, weight: .high, summary: signer ?? "unknown",
                         raw: signer, method: "SecStaticCodeCheckValidity, SecCodeCopySigningInformation"),
        ]
        session.analysis = .skipped("not a system dialog")
        session.identity = .unconfirmed
        AppLog.shared.warn("app", "fake dialog: “\(prompt.requesterName)” \(prompt.service.shortName) drawn by \(owner) (\(path ?? "no path"), \(signer ?? "unknown signer")); no scan run")
    }

    private func run(_ session: ScanSession, presetSubject: Subject?, attribution known: AttributedIdentity? = nil) {
        // The system's own record of the request is read alongside the
        // pipeline, once per dialog; a rescan after a correction reuses it.
        var lookup: Task<AttributedIdentity?, Never>?
        if known == nil, presetSubject == nil, session.identityApplies {
            let service = session.prompt.service
            let since = session.startedAt
            lookup = Task.detached(priority: .utility) { await IdentityLookup.attribution(service: service, since: since)?.responsible?.identity }
        }
        Task {
            let env = await environment()
            let pipeline = ScanPipeline(environment: env)
            let prompt = session.prompt
            let record = await pipeline.run(prompt: prompt, presetSubject: presetSubject) { event in
                Task { @MainActor in session.apply(event) }
            }
            async let slow = pipeline.runSlowChecks(record: record) { event in
                Task { @MainActor in session.apply(event) }
            }
            // Identity is reconciled as soon as the record exists, while the
            // slow checks are still out, so the panel does not wait for them.
            var attributed = known
            if attributed == nil, let lookup { attributed = await lookup.value }
            let outcome = await reconcileIdentity(attributed, record: session.record ?? record, for: session, strictness: env.settings.strictness, locale: env.locale)
            if case .corrected(let subject) = outcome, known == nil {
                _ = await slow
                let old = session.subject?.displayName ?? prompt.requesterName
                AppLog.shared.info("identity", "“\(prompt.requesterName)” \(prompt.service.shortName): the system attributes the request to \(subject.path) (pid \(attributed?.pid ?? -1)), not to \(session.subject?.path ?? "nothing"); scanning again for it")
                session.resetForRescan()
                session.identity = .corrected(from: old)
                session.identityCorrected = true
                run(session, presetSubject: subject, attribution: attributed)
                return
            }
            let withSlowChecks = await slow
            // The session may have moved on meanwhile (a verdict asked for by
            // hand, the decision): add the slow checks to it, do not replace it.
            var live = withSlowChecks.filled(from: session.record ?? withSlowChecks)
            if let attributed = session.attribution {
                let history = await historySummary(for: live)
                if case .confirmed(let confirmed) = IdentityConfirmation.apply(to: live, attributed: attributed, running: session.runningCode, strictness: env.settings.strictness, locale: env.locale, history: history) {
                    live = confirmed
                }
            } else if session.identity == .unconfirmed, session.identityApplies {
                // No attribution arrived: keep the unconfirmed concern on the
                // record the slow checks produced, so it is not scored away.
                let history = await historySummary(for: live)
                live = IdentityConfirmation.applyUnconfirmed(to: live, strictness: env.settings.strictness, locale: env.locale, history: history)
            }
            session.record = live
            if live != withSlowChecks { try? await store.save(live) }
            monthlySpend = (try? await store.monthlySpend()) ?? 0
        }
    }

    /// Applies the system's attribution of the request to a finished record:
    /// confirms the identity (with a check of the running process), or says
    /// the scan was about the wrong program, or leaves it unconfirmed. Never
    /// waits: a missing attribution is a normal outcome.
    /// The store's summary of earlier scans of this file and publisher, so a
    /// re-score after identity confirmation keeps the history concerns the
    /// pipeline's own score had.
    private func historySummary(for record: ScanRecord) async -> HistorySummary? {
        let facts = HardScoreEngine.mergedFacts(record.evidence)
        return try? await store.history(teamID: facts[Fact.signerTeamID], sha256: facts[Fact.sha256])
    }

    private func reconcileIdentity(_ attributed: AttributedIdentity?, record: ScanRecord, for session: ScanSession, strictness: Strictness, locale: String) async -> IdentityConfirmation.Outcome {
        guard session.identityApplies else { return .unconfirmed }
        // History was part of the pipeline's score; keep it so re-scoring after
        // confirmation does not forget "you denied this before".
        let history = await historySummary(for: record)
        guard let attributed else {
            // The system had no record of the request. For a permission dialog
            // that is itself a concern: the window could have been drawn by any
            // program. Re-score with the unconfirmed identity so the panel and
            // the badge say so instead of vouching for the dialog.
            let updated = IdentityConfirmation.applyUnconfirmed(to: record, strictness: strictness, locale: locale, history: history)
            if updated != record { session.adopt(confirmed: updated); try? await store.save(updated) }
            if session.identity == .pending { session.identity = .unconfirmed }
            return .unconfirmed
        }
        if let subject = record.subject, IdentityConfirmation.names(subject, attributed: attributed), session.runningCode == nil {
            // The file that runs is what the process is compared with; the
            // bundle around it is what the evidence checks sealed.
            let pid = attributed.pid
            let diskPath = attributed.binaryPath ?? subject.path
            let info = await Task.detached(priority: .userInitiated) { RunningCode.validate(pid: pid, diskPath: diskPath) }.value
            session.runningCode = info.facts
            AppLog.shared.info("identity", "running code of pid \(pid): valid \(info.valid), matches disk \(info.matchesDisk.map(String.init) ?? "n/a")\(info.error.map { " (\($0))" } ?? "") · \(info.path ?? diskPath)")
        }
        let outcome = IdentityConfirmation.apply(to: record, attributed: attributed, running: session.runningCode, strictness: strictness, locale: locale, history: history)
        switch outcome {
        case .confirmed(let confirmed):
            session.attribution = attributed
            session.adopt(confirmed: confirmed)
            let path = attributed.path ?? confirmed.subject?.path ?? "?"
            if !session.identityCorrected { session.identity = .confirmed(pid: attributed.pid, path: path) }
            try? await store.save(confirmed)
            AppLog.shared.info("identity", "identity confirmed: “\(session.prompt.requesterName)” is \(path) (pid \(attributed.pid)) · score \(confirmed.hardScore?.score.rawValue ?? "?")\(confirmed.verdictRejected == IdentityConfirmation.verdictDroppedReason ? " · verdict withdrawn" : "")")
        case .corrected(let subject):
            if session.identityCorrected {
                // Already rescanned for the program the system named and it
                // still does not match: say so rather than loop.
                AppLog.shared.warn("identity", "attribution names \(subject.path) but the rescan resolved \(record.subject?.path ?? "nothing"); leaving identity unconfirmed")
                session.identity = .unconfirmed
                return .unconfirmed
            }
        case .unconfirmed:
            session.identity = .unconfirmed
        }
        return outcome
    }

    /// Runs the AI on a scan that was scored without it, because the user
    /// asked: the agent is off, automatic asking is off, the publisher was
    /// trusted, or the last attempt failed. `engine` picks the agent for this
    /// one scan when the setting is None.
    func askAI(_ session: ScanSession, engine: EngineChoice? = nil) {
        guard let record = session.record, session.canAskAI else { return }
        let choice = engine ?? onDemandAgents.first
        guard let choice, choice != .none else { return }
        session.analysis = .thinking
        session.toolActivity = nil
        AppLog.shared.info("app", "AI asked by hand for “\(session.prompt.requesterName)” via \(choice.rawValue)")
        Task {
            let env = await environment(engine: choice)
            let pipeline = ScanPipeline(environment: env)
            let updated = await pipeline.analyze(record: record) { event in
                Task { @MainActor in session.apply(event) }
            }
            let live = updated.filled(from: session.record ?? updated)
            session.record = live
            if live != updated { try? await store.save(live) }
            if session.analysis == .thinking { session.analysis = .idle }
            monthlySpend = (try? await store.monthlySpend()) ?? 0
        }
    }

    func send(_ question: String, in session: ScanSession) {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !session.isReplying, let record = session.record else { return }
        session.draft = ""
        session.isReplying = true
        session.streamingReply = ""
        session.messages.append(ChatMessage(role: .user, text: text))
        Task {
            let env = await environment(for: session)
            let pipeline = ScanPipeline(environment: env)
            do {
                let updated = try await pipeline.chat(record: record, question: text) { event in
                    Task { @MainActor in
                        if case .text(let t) = event { session.streamingReply = t }
                        if case .toolCall(let name, _) = event { session.toolActivity = name }
                        if case .toolResult(_, let summary) = event { session.toolActivity = summary }
                    }
                }
                session.record = updated
                session.messages = updated.messages
            } catch {
                session.messages.append(ChatMessage(role: .assistant, text: "Could not get an answer: \(error)"))
            }
            session.isReplying = false
            session.streamingReply = ""
            session.toolActivity = nil
            monthlySpend = (try? await store.monthlySpend()) ?? 0
        }
    }

    func recordDecision(_ decision: UserDecision, for session: ScanSession, source: String = "user") {
        session.decision = decision
        session.decisionSource = decision == .unknown ? nil : source
        guard var record = session.record else { return }
        record.userDecision = decision
        record.decisionSource = session.decisionSource
        session.record = record
        Task { try? await store.save(record) }
    }

    /// Reads the answer from the system's own log once the dialog is gone,
    /// so the user is not asked what they just clicked. The panel falls back
    /// to its buttons only when nothing is found.
    func detectDecision(for session: ScanSession) {
        guard session.decisionLookup == .idle else { return }
        guard session.dialog != nil, !session.isManual, !session.isFakeDialog, session.decision == .unknown, session.prompt.service.tccServiceName != nil else {
            session.decisionLookup = .notFound
            return
        }
        session.decisionLookup = .running
        let service = session.prompt.service
        let subject = session.subject
        let name = session.prompt.requesterName
        let since = session.startedAt
        Task {
            let match = await TCCDecisionLookup.decision(service: service, subject: subject ?? session.subject, requesterName: name, since: since)
            guard session.decision == .unknown else {
                session.decisionLookup = .found
                return
            }
            if let match {
                recordDecision(match.decision, for: session, source: "system-log")
                session.decisionLookup = .found
            } else {
                session.decisionLookup = .notFound
            }
        }
    }

    /// Whether the panel can keep talking to the AI about this scan: the
    /// automatic agent made the verdict, or the user picked an agent for it.
    func canChat(_ session: ScanSession) -> Bool {
        guard let engineID = session.record?.analystSession?.engine else { return false }
        if engineID == currentAnalystID { return true }
        guard settings.engine == .none, let engine = EngineChoice(analystID: engineID) else { return false }
        return onDemandAgents.contains(engine)
    }

    func dismiss(_ session: ScanSession) {
        sessions.removeAll { $0.id == session.id }
        // The last scan stays reachable from the menu even after its panel is gone.
    }

    // MARK: Login item

    /// Registered only once onboarding is done, so a build run from a scratch
    /// folder does not become a login item.
    func applyLaunchAtLogin() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let service = SMAppService.mainApp
        let wanted = settings.launchAtLogin && settings.onboardingCompleted
        if wanted {
            if service.status != .enabled { try? service.register() }
        } else if service.status == .enabled {
            try? service.unregister()
        }
    }
}
