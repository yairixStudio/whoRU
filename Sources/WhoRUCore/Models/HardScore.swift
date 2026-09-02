import Foundation

/// The deterministic floor and ceiling that the evidence sets before any model
/// sees anything.
public enum HardScore: String, Codable, Sendable, Hashable {
    case red, amber, green
}

/// Why the score is what it is. `code` is stable and localizable; `ref` points
/// at the evidence row that caused it.
public struct ScoreReason: Codable, Sendable, Hashable {
    public var code: String
    public var ref: EvidenceKey?
    /// Values interpolated into the localized sentence, e.g. the publisher name.
    public var params: [String: String]

    public init(code: String, ref: EvidenceKey? = nil, params: [String: String] = [:]) {
        self.code = code
        self.ref = ref
        self.params = params
    }
}

public struct HardScoreResult: Codable, Sendable, Hashable {
    public var score: HardScore
    /// Ordered by importance; the first one drives the deterministic headline.
    public var reasons: [ScoreReason]
    /// True when the subject is a system component signed by the platform vendor.
    public var isSystemComponent: Bool
    /// True when the publisher is on the user's trusted list.
    public var isTrustedPublisher: Bool
    /// True when the hash matched an official release.
    public var matchesOfficialSource: Bool

    public init(
        score: HardScore,
        reasons: [ScoreReason],
        isSystemComponent: Bool = false,
        isTrustedPublisher: Bool = false,
        matchesOfficialSource: Bool = false
    ) {
        self.score = score
        self.reasons = reasons
        self.isSystemComponent = isSystemComponent
        self.isTrustedPublisher = isTrustedPublisher
        self.matchesOfficialSource = matchesOfficialSource
    }

    /// The model may be skipped entirely for these: the deterministic answer is final enough.
    public var canSkipModel: Bool { isSystemComponent || isTrustedPublisher }
}
