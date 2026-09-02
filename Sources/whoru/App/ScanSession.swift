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
    var decision: UserDecision = .unknown
    var startedAt = Date()
    var isManual = false

    enum DecisionLookup: Equatable { case idle, running, found, notFound }
    /// Whether the system's own record of the answer has been looked up yet.
    var decisionLookup: DecisionLookup = .idle
    /// `user` or `system-log`; see `ScanRecord.decisionSource`.
    var decisionSource: String?

    init(id: String, dialog: DialogInstance?, prompt: PermissionPrompt, rawTitle: String) {
        self.id = id
        self.dialog = dialog
        self.prompt = prompt
        self.rawTitle = rawTitle
    }

    var isScanning: Bool { hardScore == nil }
    var chatActive: Bool { !messages.isEmpty || !draft.isEmpty || isReplying }

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
        mirrorTask?.cancel()
        mirrorTask = Task { [weak self, weak other] in
            while !Task.isCancelled, let self, let other {
                if self.verdict != other.verdict || self.evidence.count != other.evidence.count || self.analysis != other.analysis || self.record?.id != other.record?.id {
                    self.subject = other.subject
                    self.evidence = other.evidence
                    self.hardScore = other.hardScore
                    self.headline = other.headline
                    self.partialHeadline = other.partialHeadline
                    self.verdict = other.verdict
                    self.analysis = other.analysis
                    self.record = other.record
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
            case .toolCall(let name, _): toolActivity = name
            case .toolResult(_, let summary): toolActivity = summary
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
