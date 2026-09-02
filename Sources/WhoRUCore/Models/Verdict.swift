import Foundation

public enum VerdictKind: String, Codable, Sendable, Hashable, CaseIterable {
    case legitimate
    case probablyLegitimate = "probably_legitimate"
    case suspicious
    case malicious
    case unknown
}

public enum Fit: String, Codable, Sendable, Hashable {
    case matches, unusual, mismatch
}

public enum Recommendation: String, Codable, Sendable, Hashable {
    case allow, deny, investigate
}

public enum ReasonKind: String, Codable, Sendable, Hashable {
    case evidence, inference
}

public struct VerdictReason: Codable, Sendable, Hashable {
    public var kind: ReasonKind
    /// Evidence key this reason cites. Required when `kind == .evidence`.
    public var ref: String?
    public var text: String

    public init(kind: ReasonKind, ref: String? = nil, text: String) {
        self.kind = kind
        self.ref = ref
        self.text = text
    }
}

/// The structured answer from the analyst. Field names match the JSON schema
/// the model is asked to fill, so this type decodes the response directly.
public struct Verdict: Codable, Sendable, Hashable {
    public var verdict: VerdictKind
    public var confidence: Int
    public var headline: String
    public var whatItIs: String
    public var whyItAsks: String
    public var fit: Fit
    public var recommendation: Recommendation
    public var reasons: [VerdictReason]
    public var ifDenied: String
    public var suggestedQuestions: [String]
    public var technicalNotes: String

    public init(
        verdict: VerdictKind,
        confidence: Int,
        headline: String,
        whatItIs: String,
        whyItAsks: String,
        fit: Fit,
        recommendation: Recommendation,
        reasons: [VerdictReason],
        ifDenied: String,
        suggestedQuestions: [String],
        technicalNotes: String
    ) {
        self.verdict = verdict
        self.confidence = confidence
        self.headline = headline
        self.whatItIs = whatItIs
        self.whyItAsks = whyItAsks
        self.fit = fit
        self.recommendation = recommendation
        self.reasons = reasons
        self.ifDenied = ifDenied
        self.suggestedQuestions = suggestedQuestions
        self.technicalNotes = technicalNotes
    }

    enum CodingKeys: String, CodingKey {
        case verdict, confidence, headline
        case whatItIs = "what_it_is"
        case whyItAsks = "why_it_asks"
        case fit, recommendation, reasons
        case ifDenied = "if_denied"
        case suggestedQuestions = "suggested_questions"
        case technicalNotes = "technical_notes"
    }
}

/// The two-to-four word title and one sentence shown in the panel's glance layer.
public struct Headline: Codable, Sendable, Hashable {
    public var title: String
    public var sentence: String
    /// Where the headline came from: `deterministic` or the analyst's id.
    public var source: String

    public init(title: String, sentence: String, source: String) {
        self.title = title
        self.sentence = sentence
        self.source = source
    }
}
