import Foundation

/// Progress of one scan, in the order the panel shows it.
public enum ScanEvent: Sendable {
    case resolved(Subject?, candidates: [SubjectCandidate])
    case evidence(EvidenceItem)
    case hardScore(HardScoreResult, Headline)
    /// A verdict from an earlier scan of the same file and permission.
    case cached(ScanRecord)
    case analysis(AnalysisEvent)
    case verdict(Verdict)
    case verdictRejected(reason: String)
    case analysisSkipped(reason: String)
    case analysisFailed(String)
    case finished(ScanRecord)
}

/// Everything a scan needs, injected so the pipeline can run in the app, the
/// command line and the tests with different implementations.
public struct ScanEnvironment: Sendable {
    public var resolver: RequesterResolver
    public var collector: Collector
    public var analyst: (any Analyst)?
    public var toolHandlers: @Sendable (Subject?, [EvidenceItem]) -> [ToolHandler]
    public var store: (any ScanStore)?
    public var settings: Settings
    public var publishers: PublisherDirectory
    public var secrets: any SecretStore
    public var paths: any Paths
    public var locale: String

    public init(
        resolver: RequesterResolver,
        collector: Collector,
        analyst: (any Analyst)?,
        toolHandlers: @escaping @Sendable (Subject?, [EvidenceItem]) -> [ToolHandler] = { _, _ in [] },
        store: (any ScanStore)?,
        settings: Settings,
        publishers: PublisherDirectory,
        secrets: any SecretStore,
        paths: any Paths,
        locale: String = "en"
    ) {
        self.resolver = resolver
        self.collector = collector
        self.analyst = analyst
        self.toolHandlers = toolHandlers
        self.store = store
        self.settings = settings
        self.publishers = publishers
        self.secrets = secrets
        self.paths = paths
        self.locale = locale
    }
}

/// Resolve → collect → score → headline → (cache | skip | analyze) → validate → store.
public struct ScanPipeline: Sendable {
    public let environment: ScanEnvironment

    public init(environment: ScanEnvironment) {
        self.environment = environment
    }

    public func run(prompt: PermissionPrompt, presetSubject: Subject? = nil, onEvent: @escaping @Sendable (ScanEvent) -> Void) async -> ScanRecord {
        let env = environment
        var record = ScanRecord(prompt: prompt)

        // 1. Resolve.
        let resolved: ResolveResult
        if let presetSubject {
            resolved = ResolveResult(subject: presetSubject)
        } else {
            resolved = await env.resolver.resolve(prompt)
        }
        record.subject = resolved.subject
        record.candidates = resolved.candidates
        onEvent(.resolved(resolved.subject, candidates: resolved.candidates))

        // 2. Collect fast evidence and derivations.
        var evidence: [EvidenceItem] = []
        if let subject = resolved.subject {
            let history = try? await env.store?.history(teamID: nil, sha256: nil)
            var context = CheckContext(prompt: prompt, settings: env.settings, publishers: env.publishers, secrets: env.secrets, history: history)
            context.timeout = .seconds(4)
            evidence = await env.collector.collect(subject: subject, context: context, includeSlow: false, onItem: { onEvent(.evidence($0)) })
            // History needs the Team ID and hash, which only exist after the checks ran.
            if let store = env.store {
                let facts = HardScoreEngine.mergedFacts(evidence)
                if let summary = try? await store.history(teamID: facts[Fact.signerTeamID], sha256: facts[Fact.sha256]) {
                    context.history = summary
                    if let index = evidence.firstIndex(where: { $0.key == .history }),
                       let item = HistoryDerivation().derive(from: evidence, subject: subject, context: context) {
                        evidence[index] = item
                        onEvent(.evidence(item))
                    }
                }
            }
        }
        record.evidence = evidence

        // 3. Score and headline.
        let hard = HardScoreEngine(strictness: env.settings.strictness).score(evidence, subject: resolved.subject, prompt: prompt)
        let headline = HeadlineComposer().headline(for: hard, subject: resolved.subject, prompt: prompt, locale: env.locale)
        record.hardScore = hard
        record.deterministicHeadline = headline
        onEvent(.hardScore(hard, headline))
        try? await env.store?.save(record)

        // 4. Cache.
        if let store = env.store, let sha = record.sha256,
           let cached = try? await store.cachedVerdict(sha256: sha, service: prompt.service, within: env.settings.verdictCacheDays),
           let verdict = cached.verdict {
            record.verdict = verdict
            record.engine = cached.engine
            record.model = cached.model
            record.fromCache = true
            record.analystSession = cached.analystSession
            onEvent(.cached(cached))
            onEvent(.verdict(verdict))
            return await finish(record, onEvent: onEvent)
        }

        // 5. Decide whether to ask the model.
        guard let analyst = env.analyst else {
            onEvent(.analysisSkipped(reason: "no AI engine configured"))
            return await finish(record, onEvent: onEvent)
        }
        if env.settings.localOnly, analyst.id != "local" {
            onEvent(.analysisSkipped(reason: "local-only mode"))
            return await finish(record, onEvent: onEvent)
        }
        if hard.canSkipModel {
            onEvent(.analysisSkipped(reason: hard.isSystemComponent ? "system component signed by Apple" : "trusted publisher"))
            return await finish(record, onEvent: onEvent)
        }
        if let store = env.store, let spend = try? await store.monthlySpend(), spend >= env.settings.monthlyBudgetUSD, analyst.id == "claude-api" {
            onEvent(.analysisSkipped(reason: "monthly budget reached"))
            return await finish(record, onEvent: onEvent)
        }

        // 6. Analyze.
        let history = try? await env.store?.history(teamID: record.teamID, sha256: record.sha256)
        let bundle = EvidenceBundle(
            prompt: prompt, subject: resolved.subject, candidates: resolved.candidates, evidence: evidence,
            hardScore: hard, history: history, answerLanguage: env.locale
        ).redactedForModel(homeDirectory: env.paths.homeDirectory)
        let request = AnalysisRequest(
            bundle: bundle, model: env.settings.depth.modelID, effort: env.settings.depth.effort,
            maxToolCalls: env.settings.maxToolCalls, allowWebSearch: env.settings.allowWebSearch, locale: env.locale
        )
        let tools = ToolRegistry(subject: resolved.subject, handlers: env.toolHandlers(resolved.subject, evidence))
        do {
            let result = try await analyst.analyze(request, tools: tools, onEvent: { onEvent(.analysis($0)) })
            record.engine = analyst.id
            record.model = result.model
            record.inputTokens = result.inputTokens
            record.outputTokens = result.outputTokens
            record.costUSD = result.costUSD
            record.analystSession = result.session
            switch VerdictValidator().validate(result.verdict, against: hard, evidenceKeys: Set(evidence.map(\.key.rawValue))) {
            case .accepted(let verdict):
                record.verdict = verdict
                onEvent(.verdict(verdict))
            case .rejected(let reason):
                record.verdictRejected = reason
                onEvent(.verdictRejected(reason: reason))
            }
        } catch {
            onEvent(.analysisFailed(String(describing: error)))
        }
        return await finish(record, onEvent: onEvent)
    }

    /// Runs the slow checks after the verdict is on screen and returns the
    /// updated record. Callers decide whether to re-score.
    public func runSlowChecks(record: ScanRecord, onEvent: @escaping @Sendable (ScanEvent) -> Void) async -> ScanRecord {
        let env = environment
        guard let subject = record.subject else { return record }
        let slow = Collector(checks: env.collector.checks.filter(\.isSlow), derivations: [])
        guard !slow.checks.isEmpty else { return record }
        let context = CheckContext(prompt: record.prompt, settings: env.settings, publishers: env.publishers, secrets: env.secrets, timeout: .seconds(8))
        let items = await slow.collect(subject: subject, context: context, includeSlow: true, onItem: { onEvent(.evidence($0)) })
        var updated = record
        updated.evidence += items
        try? await env.store?.save(updated)
        return updated
    }

    /// Continues the conversation for a stored scan.
    public func chat(record: ScanRecord, question: String, onEvent: @escaping @Sendable (AnalysisEvent) -> Void) async throws -> ScanRecord {
        let env = environment
        guard let analyst = env.analyst, let session = record.analystSession, let hard = record.hardScore else {
            throw AnalystError.notConfigured("no conversation to continue")
        }
        let bundle = EvidenceBundle(prompt: record.prompt, subject: record.subject, candidates: record.candidates, evidence: record.evidence, hardScore: hard, answerLanguage: env.locale)
            .redactedForModel(homeDirectory: env.paths.homeDirectory)
        let request = AnalysisRequest(bundle: bundle, model: session.model, effort: env.settings.depth.effort, maxToolCalls: 4, allowWebSearch: env.settings.allowWebSearch, locale: env.locale)
        let tools = ToolRegistry(subject: record.subject, handlers: env.toolHandlers(record.subject, record.evidence))
        var updated = record
        updated.messages.append(ChatMessage(role: .user, text: question))
        let reply = try await analyst.reply(to: question, session: session, request: request, tools: tools, onEvent: onEvent)
        updated.messages.append(ChatMessage(role: .assistant, text: reply.text, toolCalls: reply.toolCalls))
        updated.analystSession = reply.session
        updated.inputTokens += reply.inputTokens
        updated.outputTokens += reply.outputTokens
        updated.costUSD += reply.costUSD
        try? await env.store?.save(updated)
        return updated
    }

    private func finish(_ record: ScanRecord, onEvent: @escaping @Sendable (ScanEvent) -> Void) async -> ScanRecord {
        var record = record
        record.finishedAt = Date()
        try? await environment.store?.save(record)
        onEvent(.finished(record))
        return record
    }
}
