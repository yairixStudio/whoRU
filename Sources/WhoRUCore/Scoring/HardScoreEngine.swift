import Foundation

/// Computes the red / amber / green score from normalized evidence facts.
///
/// The rules are intentionally few and explainable in a sentence each. They are
/// the contract between the evidence and the model: red is a floor the model
/// cannot lift, green is a ceiling it may lower.
public struct HardScoreEngine: Sendable {
    public let strictness: Strictness

    public init(strictness: Strictness = .standard) {
        self.strictness = strictness
    }

    public func score(_ evidence: [EvidenceItem], subject: Subject?, prompt: PermissionPrompt, history: HistorySummary? = nil) -> HardScoreResult {
        let facts = Self.mergedFacts(evidence)
        func fact(_ key: String) -> String? { facts[key] }

        // Hard red: any one of these ends the discussion.
        var red: [ScoreReason] = []
        if fact(Fact.signatureValid) == "false" {
            red.append(ScoreReason(code: "signature.broken", ref: .signatureIntegrity))
        }
        if fact(Fact.impersonation) == "true" {
            red.append(ScoreReason(code: "impersonation", ref: .impersonation, params: ["name": fact(Fact.impersonatedName) ?? prompt.requesterName]))
        }
        if let detections = fact(Fact.virusTotalDetections).flatMap(Int.init), detections >= 3 {
            red.append(ScoreReason(code: "virustotal.flagged", ref: .virusTotal, params: ["count": String(detections)]))
        }
        if fact(Fact.publisherTrust) == "blocked" {
            red.append(ScoreReason(code: "publisher.blocked", ref: .publisher, params: ["publisher": fact(Fact.publisherName) ?? fact(Fact.signerTeamID) ?? ""]))
        }
        if !red.isEmpty {
            return HardScoreResult(score: .red, reasons: red)
        }

        let signerKind = fact(Fact.signerKind).flatMap(SignerKind.init(rawValue:)) ?? .unknown
        let publisherName = fact(Fact.publisherName) ?? fact(Fact.signerName) ?? fact(Fact.signerTeamID) ?? ""
        let signatureValid = fact(Fact.signatureValid) == "true"

        // Amber concerns are collected even when the result is green, so the
        // model sees them and the headline can mention the first one.
        var concerns: [ScoreReason] = []
        if subject == nil {
            concerns.append(ScoreReason(code: "unresolved"))
        } else if fact(Fact.resolverConfidence) == Confidence.low.rawValue {
            concerns.append(ScoreReason(code: "resolver.low"))
        }
        switch signerKind {
        case .unsigned: concerns.append(ScoreReason(code: "unsigned", ref: .signerIdentity))
        case .adhoc: concerns.append(ScoreReason(code: "adhoc", ref: .signerIdentity))
        case .unknown: concerns.append(ScoreReason(code: "signer.unknown", ref: .signerIdentity))
        case .developerID where fact(Fact.publisherName) == nil:
            concerns.append(ScoreReason(code: "publisher.unknown", ref: .signerIdentity, params: ["publisher": publisherName]))
        default: break
        }
        if fact(Fact.downloadSource) == "unknown" {
            concerns.append(ScoreReason(code: "download.unknown", ref: .downloadOrigin, params: ["source": fact(Fact.downloadURL) ?? ""]))
        }
        if fact(Fact.locationClass) == "suspicious" {
            concerns.append(ScoreReason(code: "location.suspicious", ref: .location, params: ["location": subject.map { ($0.path as NSString).deletingLastPathComponent } ?? ""]))
        }
        // What happened last time with this exact file is a concern the model
        // should weigh; it is not hard evidence, so it never makes red.
        if let history, history.sameFileTimes > 0 {
            if history.sameFileLastVerdict == .malicious || history.sameFileLastVerdict == .suspicious {
                concerns.insert(ScoreReason(code: "history.flagged", ref: .history), at: 0)
            } else if history.sameFileLastDecision == .denied {
                concerns.append(ScoreReason(code: "history.denied", ref: .history))
            }
        }

        // Green: exactly the conditions from the design, plus one curated
        // extension: a valid Developer ID signature from a publisher in the
        // built-in directory counts as green even when notarization is
        // unknown, which is the normal case for command-line tools.
        var green: [ScoreReason] = []
        var isSystem = false
        var isTrusted = false
        var matchesOfficial = false

        if signerKind == .apple, fact(Fact.signatureValid) != "false" {
            isSystem = true
            green.append(ScoreReason(code: "signed.apple", ref: .signerIdentity))
        }
        if fact(Fact.manifestMatch) == "true" {
            matchesOfficial = true
            green.append(ScoreReason(code: "manifest.match", ref: .officialManifest, params: ["publisher": publisherName, "source": fact(Fact.manifestSource) ?? ""]))
        }
        if fact(Fact.publisherTrust) == "trusted", signatureValid {
            isTrusted = true
            green.append(ScoreReason(code: "publisher.trusted", ref: .publisher, params: ["publisher": publisherName]))
        }
        if signerKind == .appStore, signatureValid {
            green.append(ScoreReason(code: "signed.appStore", ref: .signerIdentity, params: ["publisher": publisherName]))
        }
        if signerKind == .developerID, signatureValid {
            if fact(Fact.notarized) == "true" {
                green.append(ScoreReason(code: "signed.notarized", ref: .gatekeeper, params: ["publisher": publisherName]))
            } else if fact(Fact.publisherName) != nil, strictness == .standard {
                green.append(ScoreReason(code: "signed.knownPublisher", ref: .signerIdentity, params: ["publisher": publisherName]))
            }
        }

        // Strict: green must be earned; an unknown origin or a sensitive
        // permission from something Apple never checked stays amber.
        if strictness == .strict, !isSystem, !matchesOfficial, !isTrusted {
            if fact(Fact.downloadSource) == "unknown" { green.removeAll() }
            if prompt.service.isSensitive, fact(Fact.notarized) != "true", signerKind != .appStore { green.removeAll() }
        }

        if !green.isEmpty {
            return HardScoreResult(
                score: .green,
                reasons: green + concerns,
                isSystemComponent: isSystem,
                isTrustedPublisher: isTrusted,
                matchesOfficialSource: matchesOfficial
            )
        }

        if concerns.isEmpty {
            // Signed by a Developer ID we do not know, not notarized: amber by definition.
            concerns.append(ScoreReason(code: "notarized.unknown", ref: .gatekeeper, params: ["publisher": publisherName]))
        }
        return HardScoreResult(score: .amber, reasons: concerns)
    }

    /// Later items do not override earlier ones: checks are ordered by
    /// authority, and the signature check comes first.
    public static func mergedFacts(_ evidence: [EvidenceItem]) -> [String: String] {
        var merged: [String: String] = [:]
        for item in evidence {
            for (key, value) in item.facts where merged[key] == nil {
                merged[key] = value
            }
        }
        return merged
    }
}
