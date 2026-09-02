import Foundation

/// Looks the signer's Team ID up in the publisher directory and records the
/// trust level. Runs after the signature check.
public struct PublisherDerivation: EvidenceDerivation {
    public init() {}

    public func derive(from evidence: [EvidenceItem], subject: Subject, context: CheckContext) -> EvidenceItem? {
        let facts = HardScoreEngine.mergedFacts(evidence)
        let kind = facts[Fact.signerKind].flatMap(SignerKind.init(rawValue:)) ?? .unknown
        if kind == .apple {
            return EvidenceItem(key: .publisher, status: .pass, weight: .high, summary: "Apple (platform)", method: "publisher directory",
                                facts: [Fact.publisherName: "Apple", Fact.publisherTrust: PublisherTrust.normal.rawValue])
        }
        guard let teamID = facts[Fact.signerTeamID], !teamID.isEmpty else { return nil }
        guard let publisher = context.publishers.lookup(teamID: teamID) else {
            return EvidenceItem(key: .publisher, status: .info, weight: .medium,
                                summary: "Team ID \(teamID) is not in the known publisher list", method: "publisher directory",
                                facts: [Fact.publisherTrust: PublisherTrust.normal.rawValue])
        }
        let status: EvidenceStatus = switch publisher.trust {
        case .blocked: .fail
        case .trusted: .pass
        case .normal: .pass
        }
        let trustNote = switch publisher.trust {
        case .blocked: " (blocked by you)"
        case .trusted: " (trusted by you)"
        case .normal: ""
        }
        return EvidenceItem(key: .publisher, status: status, weight: .high,
                            summary: "\(publisher.name) · \(teamID)\(trustNote)", method: "publisher directory",
                            facts: [Fact.publisherName: publisher.name, Fact.publisherTrust: publisher.trust.rawValue])
    }
}

/// A requester that borrows the name of a system app or a known publisher's
/// product but is not signed by that publisher.
public struct ImpersonationDerivation: EvidenceDerivation {
    public init() {}

    public func derive(from evidence: [EvidenceItem], subject: Subject, context: CheckContext) -> EvidenceItem? {
        let facts = HardScoreEngine.mergedFacts(evidence)
        let kind = facts[Fact.signerKind].flatMap(SignerKind.init(rawValue:)) ?? .unknown
        let teamID = facts[Fact.signerTeamID]
        let names = [context.prompt.requesterName, subject.displayName]
        for name in names {
            guard let expected = context.publishers.expectedPublisher(forProductName: name) else { continue }
            let matches: Bool
            if expected.teamID == Publisher.appleTeamID {
                matches = kind == .apple
            } else {
                matches = teamID == expected.teamID
            }
            if !matches {
                return EvidenceItem(key: .impersonation, status: .fail, weight: .critical,
                                    summary: "Named “\(name)” but not signed by \(expected.name)", method: "name vs. signer",
                                    facts: [Fact.impersonation: "true", Fact.impersonatedName: name])
            }
            return EvidenceItem(key: .impersonation, status: .pass, weight: .critical,
                                summary: "Name “\(name)” matches its publisher \(expected.name)", method: "name vs. signer",
                                facts: [Fact.impersonation: "false"])
        }
        return nil
    }
}

/// What the store remembers about this publisher or file.
public struct HistoryDerivation: EvidenceDerivation {
    public init() {}

    public func derive(from evidence: [EvidenceItem], subject: Subject, context: CheckContext) -> EvidenceItem? {
        guard let history = context.history, history.timesSeen > 0 else {
            return EvidenceItem(key: .history, status: .info, weight: .medium, summary: "First time seen", method: "history")
        }
        var parts = ["seen \(history.timesSeen)×"]
        if history.timesAllowed > 0 { parts.append("allowed \(history.timesAllowed)×") }
        if history.timesDenied > 0 { parts.append("denied \(history.timesDenied)×") }
        if let verdict = history.lastVerdict { parts.append("last verdict \(verdict.rawValue)") }
        return EvidenceItem(key: .history, status: history.timesDenied > history.timesAllowed ? .warn : .info, weight: .medium,
                            summary: parts.joined(separator: ", "), method: "history")
    }
}
