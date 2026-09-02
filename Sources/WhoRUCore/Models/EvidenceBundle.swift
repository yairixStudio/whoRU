import Foundation

/// A short record of earlier scans of the same publisher or file, given to the
/// model as context. Summaries only, never full conversations.
public struct HistorySummary: Codable, Sendable, Hashable {
    /// Scans of the same publisher or the same file.
    public var timesSeen: Int
    public var timesAllowed: Int
    public var timesDenied: Int
    public var lastSeen: Date?
    public var lastVerdict: VerdictKind?
    /// Scans of this exact file (same hash).
    public var sameFileTimes: Int
    /// The most recent scan of this exact file, if any.
    public var sameFileLastSeen: Date?
    public var sameFileLastVerdict: VerdictKind?
    public var sameFileLastDecision: UserDecision?
    /// Name of the publisher the wider history belongs to.
    public var publisherName: String?

    public init(timesSeen: Int = 0, timesAllowed: Int = 0, timesDenied: Int = 0, lastSeen: Date? = nil, lastVerdict: VerdictKind? = nil,
                sameFileTimes: Int = 0, sameFileLastSeen: Date? = nil, sameFileLastVerdict: VerdictKind? = nil, sameFileLastDecision: UserDecision? = nil, publisherName: String? = nil) {
        self.timesSeen = timesSeen
        self.timesAllowed = timesAllowed
        self.timesDenied = timesDenied
        self.lastSeen = lastSeen
        self.lastVerdict = lastVerdict
        self.sameFileTimes = sameFileTimes
        self.sameFileLastSeen = sameFileLastSeen
        self.sameFileLastVerdict = sameFileLastVerdict
        self.sameFileLastDecision = sameFileLastDecision
        self.publisherName = publisherName
    }

    public var isEmpty: Bool { timesSeen == 0 && sameFileTimes == 0 }
}

/// Everything the analyst receives. This is also exactly what “What was sent?”
/// shows the user, after path redaction.
public struct EvidenceBundle: Codable, Sendable, Hashable {
    public var prompt: PermissionPrompt
    public var subject: Subject?
    public var candidates: [SubjectCandidate]
    public var evidence: [EvidenceItem]
    public var hardScore: HardScoreResult
    /// Dotted paths of fields written by the program under review.
    public var hostileFields: [String]
    public var history: HistorySummary?
    /// BCP-47 tag of the language the model should answer in.
    public var answerLanguage: String

    public init(
        prompt: PermissionPrompt,
        subject: Subject?,
        candidates: [SubjectCandidate] = [],
        evidence: [EvidenceItem],
        hardScore: HardScoreResult,
        hostileFields: [String] = ["prompt.body", "evidence.info_plist.raw"],
        history: HistorySummary? = nil,
        answerLanguage: String = "en"
    ) {
        self.prompt = prompt
        self.subject = subject
        self.candidates = candidates
        self.evidence = evidence
        self.hardScore = hardScore
        self.hostileFields = hostileFields
        self.history = history
        self.answerLanguage = answerLanguage
    }

    /// The bundle as sent to the model: raw command output dropped (it is bulky
    /// and mostly redundant with `facts`), home directory replaced with `~`.
    public func redactedForModel(homeDirectory: String) -> EvidenceBundle {
        var copy = self
        func redact(_ s: String) -> String {
            guard !homeDirectory.isEmpty else { return s }
            return s.replacingOccurrences(of: homeDirectory, with: "~")
        }
        copy.prompt.title = redact(copy.prompt.title)
        copy.prompt.body = copy.prompt.body.map(redact)
        if var subject = copy.subject {
            subject.path = redact(subject.path)
            subject.bundlePath = subject.bundlePath.map(redact)
            copy.subject = subject
        }
        copy.candidates = copy.candidates.map { c in
            var c = c
            c.path = redact(c.path)
            return c
        }
        copy.evidence = copy.evidence.map { item in
            var item = item
            item.summary = redact(item.summary)
            item.raw = nil
            item.facts = item.facts.mapValues(redact)
            return item
        }
        return copy
    }
}
