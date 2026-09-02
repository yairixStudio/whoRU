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
    let store: JSONFileScanStore
    let secrets: any SecretStore = MacEnvironment.secrets()

    var settings: Settings {
        didSet {
            try? settingsStore.save(settings)
            environmentTask = nil
            applyLaunchAtLogin()
        }
    }

    /// The user's trust decisions and additions, merged over the built-in list.
    var publisherOverrides: [Publisher] = [] {
        didSet {
            let url = paths.applicationSupport.appendingPathComponent("publishers.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? FileManager.default.createDirectory(at: paths.applicationSupport, withIntermediateDirectories: true)
            try? encoder.encode(publisherOverrides).write(to: url, options: .atomic)
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
    var monthlySpend: Double = 0

    private var environmentTask: Task<ScanEnvironment, Never>?

    init() {
        settingsStore = JSONFileSettingsStore(paths: paths)
        store = JSONFileScanStore(paths: paths)
        settings = (try? settingsStore.load()) ?? Settings()
        let overridesURL = paths.applicationSupport.appendingPathComponent("publishers.json")
        if let data = try? Data(contentsOf: overridesURL), let saved = try? JSONDecoder().decode([Publisher].self, from: data) {
            publisherOverrides = saved
        }
        Task { await refreshEngineDescription() }
        Task { monthlySpend = (try? await store.monthlySpend()) ?? 0 }
        Task { try? await store.purge(olderThan: settings.historyRetentionDays) }
    }

    var isPaused: Bool { pausedUntil.map { $0 > Date() } ?? false }

    func environment() async -> ScanEnvironment {
        if let task = environmentTask { return await task.value }
        let settings = settings
        let store = store
        let publishers = publisherDirectory
        let locale = Locale.preferredLanguages.first ?? "en"
        let task = Task { await MacEnvironment.environment(settings: settings, store: store, publishers: publishers, locale: locale) }
        environmentTask = task
        return await task.value
    }

    func refreshEngineDescription() async {
        let env = await environment()
        if let analyst = env.analyst {
            switch analyst.id {
            case "claude-code": engineDescription = "Claude Code · \(settings.depth.modelID)"
            case "claude-api": engineDescription = "Claude API · \(settings.depth.modelID)"
            case "local": engineDescription = "Local model · \(settings.localModelName)"
            default: engineDescription = analyst.id
            }
        } else {
            engineDescription = "Evidence only (no AI engine)"
        }
        monthlySpend = (try? await store.monthlySpend()) ?? 0
    }

    // MARK: Scans

    @discardableResult
    func startScan(for dialog: DialogInstance) -> ScanSession {
        let parser = PromptParser()
        let prompt = parser.makePrompt(title: dialog.title, body: dialog.body)
            ?? PermissionPrompt(title: dialog.title, body: dialog.body, requesterName: dialog.title, service: .other, requestPhrase: "", locale: "und")
        let session = ScanSession(id: dialog.id, dialog: dialog, prompt: prompt, rawTitle: dialog.title)
        sessions.append(session)
        lastSession = session
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

    private func run(_ session: ScanSession, presetSubject: Subject?) {
        Task {
            let env = await environment()
            let pipeline = ScanPipeline(environment: env)
            let prompt = session.prompt
            var record = await pipeline.run(prompt: prompt, presetSubject: presetSubject) { event in
                Task { @MainActor in session.apply(event) }
            }
            record = await pipeline.runSlowChecks(record: record) { event in
                Task { @MainActor in session.apply(event) }
            }
            session.record = record
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
            let env = await environment()
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

    func recordDecision(_ decision: UserDecision, for session: ScanSession) {
        session.decision = decision
        guard var record = session.record else { return }
        record.userDecision = decision
        session.record = record
        Task { try? await store.save(record) }
    }

    func dismiss(_ session: ScanSession) {
        sessions.removeAll { $0.id == session.id }
    }

    // MARK: Login item

    func applyLaunchAtLogin() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let service = SMAppService.mainApp
        if settings.launchAtLogin {
            if service.status != .enabled { try? service.register() }
        } else if service.status == .enabled {
            try? service.unregister()
        }
    }
}
