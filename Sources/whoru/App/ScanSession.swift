import Foundation
import Observation
import WhoRUCore

/// The live state of one scan as the panel shows it. Fed by pipeline events
/// on the main actor.
@MainActor
@Observable
final class ScanSession: Identifiable {
    enum AnalysisState: Equatable {
        case idle
        case thinking
        case skipped(String)
        case done
        case rejected(String)
        case failed(String)

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    let id: String
    var dialog: DialogInstance?
    var prompt: PermissionPrompt
    var rawTitle: String
    var subject: Subject?
    var candidates: [SubjectCandidate] = []
    var evidence: [EvidenceItem] = []
    var hardScore: HardScoreResult?
    var headline: Headline?
    var partialHeadline: String?
    var verdict: Verdict?
    var analysis: AnalysisState = .idle
    var toolActivity: String?
    var record: ScanRecord?
    var fromCache = false
    var cachedAt: Date?
    var messages: [ChatMessage] = []
    var draft = ""
    var isReplying = false
    var streamingReply = ""
    var dialogClosed = false
    /// When set, the panel is not auto-dismissed once the dialog closes; only the close button does.
    var pinned = false
    var decision: UserDecision = .unknown
    var startedAt = Date()
    var isManual = false

    enum DecisionLookup: Equatable { case idle, running, found, notFound }
    /// Whether the system's own record of the answer has been looked up yet.
    var decisionLookup: DecisionLookup = .idle
    /// `user` or `system-log`; see `ScanRecord.decisionSource`.
    var decisionSource: String?

    /// Who drew the dialog. Anything but a system dialog process is an
    /// impostor, and the session is about the impostor, not about the
    /// program the window names.
    var dialogOrigin: DialogOrigin

    /// Whether the system's own record of the request has named the program
    /// yet, and whether it agreed with the resolver.
    enum IdentityState: Equatable {
        case pending
        case confirmed(pid: Int32, path: String)
        /// The system named another program; the scan was redone for it.
        case corrected(from: String)
        case unconfirmed
    }

    var identity: IdentityState = .pending
    /// Set once the scan has been redone for the program the system named.
    var identityCorrected = false
    /// The attribution that was applied, kept so the merged record after the
    /// slow checks can be reconciled the same way.
    var attribution: AttributedIdentity?
    var runningCode: RunningCodeFacts?
    /// Tool calls the model made while analyzing, with their results, in
    /// order, for “What was sent?”.
    var toolLog: [String] = []

    init(id: String, dialog: DialogInstance?, prompt: PermissionPrompt, rawTitle: String) {
        self.id = id
        self.dialog = dialog
        self.prompt = prompt
        self.rawTitle = rawTitle
        self.dialogOrigin = dialog?.origin ?? .system(bundleID: "")
    }

    var isScanning: Bool { hardScore == nil }
    var chatActive: Bool { !messages.isEmpty || !draft.isEmpty || isReplying }

    var isFakeDialog: Bool { !dialogOrigin.isSystem }

    /// Whether the system keeps a record of this request that can name the
    /// program: a real dialog, for a permission the system tracks.
    var identityApplies: Bool { dialog != nil && !isManual && !isFakeDialog && prompt.service.tccServiceName != nil }

    /// Paths of the resolver's other confident matches, so a collision is
    /// visible even when the score already settled.
    var otherCandidatePaths: [String] {
        let chosen = subject?.path
        var seen: Set<String> = []
        return candidates.filter { $0.path != chosen && seen.insert($0.path).inserted }.map(\.path)
    }

    /// Takes the record the identity confirmation produced: new evidence
    /// rows, a new score and headline, and possibly a verdict withdrawn.
    func adopt(confirmed: ScanRecord) {
        record = confirmed
        for item in confirmed.evidence where item.key == .identity || item.key == .runningCode {
            apply(.evidence(item))
        }
        if let hard = confirmed.hardScore { hardScore = hard }
        if let head = confirmed.deterministicHeadline { headline = head }
        if confirmed.verdict == nil, verdict != nil, let reason = confirmed.verdictRejected {
            verdict = nil
            partialHeadline = nil
            analysis = .rejected(reason)
        }
    }

    /// Clears the results of a scan about the wrong program before the same
    /// session is scanned again for the right one.
    func resetForRescan() {
        subject = nil
        candidates = []
        evidence = []
        hardScore = nil
        headline = nil
        partialHeadline = nil
        verdict = nil
        analysis = .idle
        toolActivity = nil
        record = nil
        fromCache = false
        cachedAt = nil
        messages = []
        toolLog = []
        runningCode = nil
    }

    /// The scan is scored, stored, and the AI has not spoken about it yet.
    var canAskAI: Bool { record != nil && hardScore != nil && verdict == nil && analysis != .thinking && !isReplying }

    /// The conversation on file can be continued by the analyst with this id.
    func canContinueConversation(with analystID: String?) -> Bool {
        guard let analystID, let session = record?.analystSession else { return false }
        return session.engine == analystID
    }

    /// Headline shown in the glance layer: the model's if accepted, else the deterministic one.
    var displayedHeadline: Headline? {
        if let verdict {
            return Headline(title: VerdictPresentation.forVerdict(verdict.verdict, locale: prompt.locale).title, sentence: verdict.headline, source: "model")
        }
        if let partialHeadline, let headline {
            return Headline(title: headline.title, sentence: partialHeadline, source: "model-partial")
        }
        return headline
    }

    var presentation: VerdictPresentation {
        if let verdict { return VerdictPresentation.forVerdict(verdict.verdict, locale: prompt.locale) }
        if let hardScore { return VerdictPresentation.forHardScore(hardScore, locale: prompt.locale) }
        return .scanning
    }

    /// Shows another session's results as they arrive, for a duplicate prompt.
    func mirror(_ other: ScanSession) {
        subject = other.subject
        candidates = other.candidates
        evidence = other.evidence
        hardScore = other.hardScore
        headline = other.headline
        verdict = other.verdict
        analysis = other.analysis
        record = other.record
        identity = other.identity
        mirrorTask?.cancel()
        mirrorTask = Task { [weak self, weak other] in
            while !Task.isCancelled, let self, let other {
                if self.verdict != other.verdict || self.evidence.count != other.evidence.count || self.analysis != other.analysis || self.record?.id != other.record?.id
                    || self.identity != other.identity || self.hardScore != other.hardScore {
                    self.subject = other.subject
                    self.candidates = other.candidates
                    self.evidence = other.evidence
                    self.hardScore = other.hardScore
                    self.headline = other.headline
                    self.partialHeadline = other.partialHeadline
                    self.verdict = other.verdict
                    self.analysis = other.analysis
                    self.record = other.record
                    self.identity = other.identity
                    self.identityCorrected = other.identityCorrected
                }
                if other.record?.finishedAt != nil, other.analysis != .thinking { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private var mirrorTask: Task<Void, Never>?

    func apply(_ event: ScanEvent) {
        switch event {
        case .resolved(let subject, let candidates):
            self.subject = subject
            self.candidates = candidates
        case .evidence(let item):
            if let index = evidence.firstIndex(where: { $0.key == item.key }) {
                evidence[index] = item
            } else {
                evidence.append(item)
            }
        case .hardScore(let hard, let headline):
            hardScore = hard
            self.headline = headline
        case .cached(let cached):
            fromCache = true
            cachedAt = cached.startedAt
            messages = cached.messages
        case .analysis(let a):
            switch a {
            case .started: analysis = .thinking
            case .partialHeadline(let h): partialHeadline = h
            case .toolCall(let name, let input):
                toolActivity = name
                toolLog.append("→ \(name) \(input.string())")
            case .toolResult(let name, let summary):
                toolActivity = summary
                toolLog.append("← \(name): \(summary)")
            case .text, .usage: break
            }
        case .verdict(let v):
            verdict = v
            analysis = .done
            toolActivity = nil
        case .verdictRejected(let reason):
            analysis = .rejected(reason)
            toolActivity = nil
        case .analysisSkipped(let reason):
            analysis = .skipped(reason)
        case .analysisFailed(let error):
            analysis = .failed(error)
            toolActivity = nil
        case .finished(let finished):
            // Steps run in parallel (slow checks, a verdict asked for by hand,
            // the decision); the one finishing last must not undo the others.
            record = record.map { finished.filled(from: $0) } ?? finished
        }
    }
}
