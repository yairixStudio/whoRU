import Foundation

public enum VerdictValidation: Sendable, Hashable {
    case accepted(Verdict)
    /// The answer contradicted hard evidence and is discarded.
    case rejected(reason: String)
}

/// Enforces in code what the prompt asks for: red stays red, amber caps at
/// “probably legitimate”, evidence references must exist.
public struct VerdictValidator: Sendable {
    public init() {}

    public func validate(_ input: Verdict, against hard: HardScoreResult, evidenceKeys: Set<String>) -> VerdictValidation {
        var verdict = input
        verdict.confidence = max(0, min(100, verdict.confidence))

        switch hard.score {
        case .red:
            if verdict.verdict == .legitimate || verdict.verdict == .probablyLegitimate {
                return .rejected(reason: "the model called a hard-red subject \(verdict.verdict.rawValue)")
            }
            if verdict.recommendation == .allow {
                return .rejected(reason: "the model recommended allowing a hard-red subject")
            }
        case .amber:
            if verdict.verdict == .legitimate {
                verdict.verdict = .probablyLegitimate
                verdict.confidence = min(verdict.confidence, 75)
            }
            if verdict.verdict == .probablyLegitimate {
                verdict.confidence = min(verdict.confidence, 75)
            }
        case .green:
            break
        }

        // A "legitimate" verdict with a "deny" recommendation is incoherent; soften rather than reject.
        if (verdict.verdict == .legitimate || verdict.verdict == .probablyLegitimate), verdict.recommendation == .deny {
            verdict.recommendation = .investigate
        }
        if verdict.verdict == .malicious, verdict.recommendation == .allow {
            return .rejected(reason: "the model called the subject malicious but recommended allowing it")
        }

        // Evidence citations must point at real evidence; otherwise they are inferences.
        verdict.reasons = verdict.reasons.map { reason in
            var r = reason
            if r.kind == .evidence, let ref = r.ref, !evidenceKeys.contains(ref) {
                r.kind = .inference
                r.ref = nil
            } else if r.kind == .evidence, r.ref == nil {
                r.kind = .inference
            }
            return r
        }
        verdict.suggestedQuestions = Array(verdict.suggestedQuestions.prefix(3))
        return .accepted(verdict)
    }
}
