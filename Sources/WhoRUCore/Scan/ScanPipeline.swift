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
        let started = Date()
        let log = AppLog.shared
        let scanID = String(record.id.uuidString.prefix(8)).lowercased()
        log.info("scan", "\(scanID) start: “\(prompt.requesterName)” · \(prompt.service.shortName) · engine \(env.analyst?.id ?? "none") · strictness \(env.settings.strictness.rawValue)")

        // 1. Resolve.
        let resolved: ResolveResult
        if let presetSubject {
            resolved = ResolveResult(subject: presetSubject)
        } else {
            resolved = await env.resolver.resolve(prompt)
        }
        record.subject = resolved.subject
        record.candidates = resolved.candidates
        if let subject = resolved.subject {
            log.info("scan", "\(scanID) resolved in \(elapsedMs(since: started)) ms: \(subject.path) [\(subject.resolver.strategy), \(subject.resolver.confidence.rawValue)]\(resolved.candidates.count > 1 ? " · \(resolved.candidates.count) candidates" : "")")
        } else {
            log.warn("scan", "\(scanID) not resolved in \(elapsedMs(since: started)) ms")
        }
        onEvent(.resolved(resolved.subject, candidates: resolved.candidates))

        // 2. Collect fast evidence and derivations.
        var evidence: [EvidenceItem] = []
        var history: HistorySummary?
        if let subject = resolved.subject {
            var context = CheckContext(prompt: prompt, settings: env.settings, publishers: env.publishers, secrets: env.secrets, history: nil)
            context.timeout = .seconds(4)
            evidence = await env.collector.collect(subject: subject, context: context, includeSlow: false, onItem: { item in
                if item.status == .error || item.status == .fail {
                    log.warn("evidence", "\(scanID) \(item.key.rawValue) \(item.status.rawValue) in \(item.durationMs) ms: \(item.summary)")
                } else {
                    log.debug("evidence", "\(scanID) \(item.key.rawValue) \(item.status.rawValue) in \(item.durationMs) ms")
                }
                onEvent(.evidence(item))
            })
            let slowest = evidence.max { $0.durationMs < $1.durationMs }
            log.info("scan", "\(scanID) \(evidence.count) fast checks in \(elapsedMs(since: started)) ms\(slowest.map { " · slowest \($0.key.rawValue) \($0.durationMs) ms" } ?? "")")
            // History needs the Team ID and hash, which only exist after the checks ran.
            if let store = env.store {
                let facts = HardScoreEngine.mergedFacts(evidence)
                if let summary = try? await store.history(teamID: facts[Fact.signerTeamID], sha256: facts[Fact.sha256]) {
                    history = summary
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

        // 3. Score and headline, both aware of what happened last time.
        let hard = HardScoreEngine(strictness: env.settings.strictness).score(evidence, subject: resolved.subject, prompt: prompt, history: history, candidates: resolved.candidates)
        let headline = HeadlineComposer().headline(for: hard, subject: resolved.subject, prompt: prompt, locale: env.locale, history: history)
        record.hardScore = hard
        record.deterministicHeadline = headline
        log.info("scan", "\(scanID) \(hard.score.rawValue.uppercased()) in \(elapsedMs(since: started)) ms: \(headline.title) — \(hard.reasons.map(\.code).joined(separator: ", "))")
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
            log.info("scan", "\(scanID) verdict from cache (\(cached.startedAt.formatted(.iso8601)))")
            onEvent(.cached(cached))
            onEvent(.verdict(verdict))
            return await finish(record, onEvent: onEvent)
        }

        // 5. Decide whether to ask the model.
        func skip(_ reason: String) async -> ScanRecord {
            log.info("scan", "\(scanID) model skipped: \(reason)")
            onEvent(.analysisSkipped(reason: reason))
            return await finish(record, onEvent: onEvent)
        }
        guard let analyst = env.analyst else { return await skip(env.settings.engine == .none ? "AI off · evidence only" : "no AI agent found") }
        if let reason = Self.standingReasonToSkip(analyst, env: env) { return await skip(reason) }
        if !env.settings.askModelAutomatically { return await skip("AI on request only") }
        if hard.canSkipModel { return await skip(hard.isSystemComponent ? "system component signed by Apple" : "trusted publisher") }
        if let reason = await budgetReasonToSkip(analyst) { return await skip(reason) }

        // 6. Analyze.
        await analyze(&record, with: analyst, history: history, scanID: scanID, onEvent: onEvent)
        return await finish(record, onEvent: onEvent)
    }

    /// Runs the model on a scan that was scored without it, because the user
    /// asked for it after the fact: the agent is off, automatic asking is off,
    /// the publisher was trusted, or an earlier attempt failed. Only those
    /// automatic gates are skipped; local-only mode and the budget still hold.
    public func analyze(record: ScanRecord, onEvent: @escaping @Sendable (ScanEvent) -> Void) async -> ScanRecord {
        let env = environment
        var record = record
        let log = AppLog.shared
        let scanID = String(record.id.uuidString.prefix(8)).lowercased()
        guard record.hardScore != nil else {
            onEvent(.analysisFailed("the scan has not finished"))
            return record
        }
        guard let analyst = env.analyst else {
            onEvent(.analysisFailed("no AI agent available"))
            return record
        }
        var reasonToSkip = Self.standingReasonToSkip(analyst, env: env)
        if reasonToSkip == nil { reasonToSkip = await budgetReasonToSkip(analyst) }
        if let reason = reasonToSkip {
            log.info("scan", "\(scanID) model skipped on request: \(reason)")
            onEvent(.analysisSkipped(reason: reason))
            return record
        }
        log.info("scan", "\(scanID) model requested by the user · engine \(analyst.id)")
        let history = await historySummary(for: record.evidence)
        await analyze(&record, with: analyst, history: history, scanID: scanID, onEvent: onEvent)
        return await finish(record, onEvent: onEvent)
    }

    /// Reasons that hold whether the request is automatic or by hand.
    private static func standingReasonToSkip(_ analyst: any Analyst, env: ScanEnvironment) -> String? {
        if env.settings.localOnly, analyst.id != "local", analyst.id != "apple" { return "local-only mode" }
        return nil
    }

    private func budgetReasonToSkip(_ analyst: any Analyst) async -> String? {
        let env = environment
        guard analyst.id == "claude-api", let store = env.store, let spend = try? await store.monthlySpend() else { return nil }
        return spend >= env.settings.monthlyBudgetUSD ? "monthly budget reached" : nil
    }

    private func historySummary(for evidence: [EvidenceItem]) async -> HistorySummary? {
        guard let store = environment.store else { return nil }
        let facts = HardScoreEngine.mergedFacts(evidence)
        return try? await store.history(teamID: facts[Fact.signerTeamID], sha256: facts[Fact.sha256])
    }

    /// The model call itself, with validation. Fills in the record's verdict,
    /// engine, cost and conversation state.
    private func analyze(_ record: inout ScanRecord, with analyst: any Analyst, history: HistorySummary?, scanID: String, onEvent: @escaping @Sendable (ScanEvent) -> Void) async {
        let env = environment
        let log = AppLog.shared
        guard let hard = record.hardScore else { return }
        let bundle = EvidenceBundle(
            prompt: record.prompt, subject: record.subject, candidates: record.candidates, evidence: record.evidence,
            hardScore: hard, history: history, answerLanguage: env.locale
        ).redactedForModel(homeDirectory: env.paths.homeDirectory)
        let request = AnalysisRequest(
            bundle: bundle, model: env.settings.depth.modelID, effort: env.settings.depth.effort,
            maxToolCalls: env.settings.maxToolCalls, allowWebSearch: env.settings.allowWebSearch, locale: env.locale
        )
        let tools = ToolRegistry(subject: record.subject, handlers: env.toolHandlers(record.subject, record.evidence))
        let analysisStarted = Date()
        log.info("analyst", "\(scanID) \(analyst.id) start · model \(request.model) · \(tools.tools.count) tools")
        record.verdictRejected = nil
        do {
            let result = try await analyst.analyze(request, tools: tools, onEvent: { event in
                if case .toolCall(let name, _) = event { log.info("analyst", "\(scanID) tool \(name)") }
                onEvent(.analysis(event))
            })
            record.engine = analyst.id
            record.model = result.model
            record.inputTokens += result.inputTokens
            record.outputTokens += result.outputTokens
            record.costUSD += result.costUSD
            record.analystSession = result.session
            record.fromCache = false
            // Validate against the record's current hard score, not the one
            // captured when analysis began: identity confirmation may have
            // turned it red in the meantime, and red is a floor the model
            // cannot lift, whenever the answer arrives.
            switch VerdictValidator().validate(result.verdict, against: record.hardScore ?? hard, evidenceKeys: Set(record.evidence.map(\.key.rawValue))) {
            case .accepted(let verdict):
                record.verdict = verdict
                log.info("analyst", "\(scanID) \(analyst.id) verdict in \(elapsedMs(since: analysisStarted)) ms: \(verdict.verdict.rawValue) \(verdict.confidence)% \(verdict.recommendation.rawValue) · \(result.inputTokens) in / \(result.outputTokens) out · $\(String(format: "%.4f", result.costUSD))")
                onEvent(.verdict(verdict))
            case .rejected(let reason):
                record.verdictRejected = reason
                log.error("analyst", "\(scanID) \(analyst.id) verdict REJECTED after \(elapsedMs(since: analysisStarted)) ms: \(reason)")
                onEvent(.verdictRejected(reason: reason))
            }
        } catch {
            log.error("analyst", "\(scanID) \(analyst.id) failed after \(elapsedMs(since: analysisStarted)) ms: \(error)")
            onEvent(.analysisFailed(String(describing: error)))
        }
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
        let started = Date()
        AppLog.shared.info("chat", "\(String(record.id.uuidString.prefix(8)).lowercased()) question via \(analyst.id)")
        let reply: ChatReply
        do {
            reply = try await analyst.reply(to: question, session: session, request: request, tools: tools, onEvent: onEvent)
        } catch {
            AppLog.shared.error("chat", "\(String(record.id.uuidString.prefix(8)).lowercased()) failed after \(elapsedMs(since: started)) ms: \(error)")
            throw error
        }
        AppLog.shared.info("chat", "\(String(record.id.uuidString.prefix(8)).lowercased()) answered in \(elapsedMs(since: started)) ms")
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
