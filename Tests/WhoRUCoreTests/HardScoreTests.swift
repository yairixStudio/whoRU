import Foundation
import Testing
@testable import WhoRUCore

private func item(_ key: EvidenceKey, _ facts: [String: String], status: EvidenceStatus = .pass) -> EvidenceItem {
    EvidenceItem(key: key, status: status, weight: .high, summary: key.rawValue, facts: facts)
}

private let prompt = PermissionPrompt(title: "t", requesterName: "Thing", service: .downloadsFolder, requestPhrase: "access files in your Downloads folder")
private let subject = Subject(path: "/Applications/Thing.app/Contents/MacOS/Thing", resolver: ResolverOutcome(strategy: "test", confidence: .high))

@Suite struct HardScoreTests {
    let engine = HardScoreEngine()

    @Test func brokenSignatureIsHardRed() {
        let result = engine.score([
            item(.signerIdentity, [Fact.signerKind: "developerID", Fact.signerTeamID: "Q6L2SF6YDW"]),
            item(.signatureIntegrity, [Fact.signatureValid: "false"], status: .fail),
            item(.officialManifest, [Fact.manifestMatch: "true"]),
        ], subject: subject, prompt: prompt)
        #expect(result.score == .red)
        #expect(result.reasons.first?.code == "signature.broken")
    }

    @Test func impersonationIsHardRed() {
        let result = engine.score([
            item(.signerIdentity, [Fact.signerKind: "developerID", Fact.signerTeamID: "ZZZZZZZZZZ", Fact.signatureValid: "true"]),
            item(.impersonation, [Fact.impersonation: "true", Fact.impersonatedName: "Finder"], status: .fail),
        ], subject: subject, prompt: prompt)
        #expect(result.score == .red)
        #expect(result.reasons.first?.params["name"] == "Finder")
    }

    @Test func virusTotalThresholdIsThree() {
        let two = engine.score([item(.signerIdentity, [Fact.signerKind: "developerID", Fact.signatureValid: "true"]), item(.virusTotal, [Fact.virusTotalDetections: "2"])], subject: subject, prompt: prompt)
        let three = engine.score([item(.signerIdentity, [Fact.signerKind: "developerID", Fact.signatureValid: "true"]), item(.virusTotal, [Fact.virusTotalDetections: "3"])], subject: subject, prompt: prompt)
        #expect(two.score != .red)
        #expect(three.score == .red)
    }

    @Test func officialManifestMatchIsGreen() {
        let result = engine.score([
            item(.signerIdentity, [Fact.signerKind: "developerID", Fact.signerTeamID: "Q6L2SF6YDW", Fact.signatureValid: "true"]),
            item(.officialManifest, [Fact.manifestMatch: "true", Fact.manifestSource: "downloads.claude.ai"]),
            item(.publisher, [Fact.publisherName: "Anthropic PBC", Fact.publisherTrust: "normal"]),
        ], subject: subject, prompt: prompt)
        #expect(result.score == .green)
        #expect(result.matchesOfficialSource)
        #expect(!result.isSystemComponent)
        #expect(result.reasons.first?.code == "manifest.match")
    }

    @Test func appleSignedIsSystemComponent() {
        let result = engine.score([item(.signerIdentity, [Fact.signerKind: "apple", Fact.signatureValid: "true"])], subject: subject, prompt: prompt)
        #expect(result.score == .green)
        #expect(result.isSystemComponent)
        #expect(result.canSkipModel)
    }

    @Test func notarizedDeveloperIDIsGreen() {
        let result = engine.score([
            item(.signerIdentity, [Fact.signerKind: "developerID", Fact.signerTeamID: "ABC", Fact.signatureValid: "true"]),
            item(.gatekeeper, [Fact.notarized: "true"]),
        ], subject: subject, prompt: prompt)
        #expect(result.score == .green)
        #expect(result.reasons.first?.code == "signed.notarized")
    }

    @Test func knownPublisherWithoutNotarizationIsGreen() {
        let result = engine.score([
            item(.signerIdentity, [Fact.signerKind: "developerID", Fact.signerTeamID: "Q6L2SF6YDW", Fact.signatureValid: "true"]),
            item(.gatekeeper, [Fact.notarized: "unknown"], status: .neutral),
            item(.publisher, [Fact.publisherName: "Anthropic PBC", Fact.publisherTrust: "normal"]),
        ], subject: subject, prompt: prompt)
        #expect(result.score == .green)
        #expect(result.reasons.first?.code == "signed.knownPublisher")
    }

    @Test func unknownPublisherWithoutNotarizationIsAmber() {
        let result = engine.score([
            item(.signerIdentity, [Fact.signerKind: "developerID", Fact.signerTeamID: "NOBODY1234", Fact.signatureValid: "true"]),
            item(.gatekeeper, [Fact.notarized: "unknown"], status: .neutral),
        ], subject: subject, prompt: prompt)
        #expect(result.score == .amber)
        #expect(result.reasons.first?.code == "publisher.unknown")
    }

    @Test func unsignedIsAmberWithUnsignedFirst() {
        let result = engine.score([
            item(.signerIdentity, [Fact.signerKind: "unsigned"], status: .warn),
            item(.downloadOrigin, [Fact.downloadSource: "unknown"], status: .warn),
        ], subject: subject, prompt: prompt)
        #expect(result.score == .amber)
        #expect(result.reasons.map(\.code) == ["unsigned", "download.unknown"])
    }

    @Test func greenKeepsConcernsForTheModel() {
        let result = engine.score([
            item(.signerIdentity, [Fact.signerKind: "developerID", Fact.signerTeamID: "ABC", Fact.signatureValid: "true"]),
            item(.gatekeeper, [Fact.notarized: "true"]),
            item(.location, [Fact.locationClass: "suspicious"], status: .warn),
        ], subject: subject, prompt: prompt)
        #expect(result.score == .green)
        #expect(result.reasons.map(\.code).contains("location.suspicious"))
    }

    @Test func unresolvedSubjectIsAmber() {
        let result = engine.score([], subject: nil, prompt: prompt)
        #expect(result.score == .amber)
        #expect(result.reasons.first?.code == "unresolved")
    }

    @Test func blockedPublisherIsRedEvenWhenNotarized() {
        let result = engine.score([
            item(.signerIdentity, [Fact.signerKind: "developerID", Fact.signerTeamID: "ABC", Fact.signatureValid: "true"]),
            item(.gatekeeper, [Fact.notarized: "true"]),
            item(.publisher, [Fact.publisherName: "Bad Co", Fact.publisherTrust: "blocked"], status: .fail),
        ], subject: subject, prompt: prompt)
        #expect(result.score == .red)
    }

    @Test func trustedPublisherSkipsModel() {
        let result = engine.score([
            item(.signerIdentity, [Fact.signerKind: "developerID", Fact.signerTeamID: "ABC", Fact.signatureValid: "true"]),
            item(.publisher, [Fact.publisherName: "Good Co", Fact.publisherTrust: "trusted"]),
        ], subject: subject, prompt: prompt)
        #expect(result.score == .green)
        #expect(result.canSkipModel)
    }

    @Test func firstFactWinsOnMerge() {
        let merged = HardScoreEngine.mergedFacts([
            item(.signerIdentity, [Fact.signerKind: "apple"]),
            item(.publisher, [Fact.signerKind: "unsigned"]),
        ])
        #expect(merged[Fact.signerKind] == "apple")
    }
}

@Suite struct HeadlineTests {
    let composer = HeadlineComposer()

    @Test func englishAndHebrewHeadlines() {
        let result = HardScoreResult(score: .green, reasons: [ScoreReason(code: "manifest.match", params: ["publisher": "Anthropic PBC"])], matchesOfficialSource: true)
        let en = composer.headline(for: result, subject: subject, prompt: prompt, locale: "en")
        #expect(en.title == "Safe to allow")
        #expect(en.sentence.contains("Anthropic PBC"))
        let he = composer.headline(for: result, subject: subject, prompt: prompt, locale: "he-IL")
        #expect(he.title == "בטוח לאשר")
        #expect(he.sentence.contains("Anthropic PBC"))
        #expect(en.source == "deterministic")
    }

    @Test func redHeadlineUsesFirstReason() {
        let result = HardScoreResult(score: .red, reasons: [ScoreReason(code: "impersonation", params: ["name": "Finder"])])
        let h = composer.headline(for: result, subject: subject, prompt: prompt, locale: "en")
        #expect(h.title == "Do not allow")
        #expect(h.sentence.contains("Finder"))
    }

    @Test func unknownLocaleFallsBackToEnglish() {
        let result = HardScoreResult(score: .amber, reasons: [ScoreReason(code: "unsigned")])
        let h = composer.headline(for: result, subject: subject, prompt: prompt, locale: "xx")
        #expect(h.title == "Worth a look")
    }

    @Test func headlineMentionsEarlierScansOfTheSameFile() {
        let result = HardScoreResult(score: .green, reasons: [ScoreReason(code: "signed.notarized", params: ["publisher": "Google LLC"])])
        let now = Date()
        let history = HistorySummary(timesSeen: 3, timesAllowed: 2, lastSeen: now.addingTimeInterval(-86400 * 2), lastVerdict: .legitimate,
                                     sameFileTimes: 2, sameFileLastSeen: now.addingTimeInterval(-86400 * 2), sameFileLastVerdict: .legitimate, sameFileLastDecision: .allowed, publisherName: "Google LLC")
        let en = composer.headline(for: result, subject: subject, prompt: prompt, locale: "en", history: history, now: now)
        #expect(en.sentence.contains("Checked 2 times before"))
        #expect(en.sentence.contains("2 days ago"))
        #expect(en.sentence.contains("fine"))
        #expect(en.sentence.hasSuffix("You allowed it then."))
        let he = composer.headline(for: result, subject: subject, prompt: prompt, locale: "he", history: history, now: now)
        #expect(he.sentence.contains("נבדק 2 פעמים בעבר"))
        #expect(he.sentence.hasSuffix("אישרת אותו אז."))
    }

    @Test func headlineFallsBackToPublisherHistory() {
        let result = HardScoreResult(score: .amber, reasons: [ScoreReason(code: "unsigned")])
        let history = HistorySummary(timesSeen: 1, lastSeen: Date().addingTimeInterval(-3600 * 5), lastVerdict: .legitimate, publisherName: "Anthropic PBC")
        let h = composer.headline(for: result, subject: subject, prompt: prompt, locale: "en", history: history)
        #expect(h.sentence.contains("Another program from Anthropic PBC was checked 5 hours ago."))
        #expect(HeadlineComposer.historyClause(HistorySummary(), locale: "en") == nil)
    }

    @Test func flaggedHistoryIsAnAmberConcernNotRed() {
        let engine = HardScoreEngine()
        let evidence = [item(.signerIdentity, [Fact.signerKind: "developerID", Fact.signerTeamID: "ABC", Fact.signatureValid: "true"]), item(.gatekeeper, [Fact.notarized: "true"])]
        let history = HistorySummary(sameFileTimes: 1, sameFileLastVerdict: .suspicious)
        let result = engine.score(evidence, subject: subject, prompt: prompt, history: history)
        #expect(result.score == .green)
        #expect(result.reasons.map(\.code).contains("history.flagged"))
        let denied = engine.score([item(.signerIdentity, [Fact.signerKind: "unsigned"], status: .warn)], subject: subject, prompt: prompt, history: HistorySummary(sameFileTimes: 1, sameFileLastDecision: .denied))
        #expect(denied.score == .amber)
        #expect(denied.reasons.map(\.code) == ["unsigned", "history.denied"])
    }

    @Test func presentationMapsHardScore() {
        let system = HardScoreResult(score: .green, reasons: [], isSystemComponent: true)
        #expect(VerdictPresentation.forHardScore(system, locale: "en").symbol == "apple.logo")
        let unresolved = HardScoreResult(score: .amber, reasons: [ScoreReason(code: "unresolved")])
        #expect(VerdictPresentation.forHardScore(unresolved, locale: "en").symbol == "questionmark.app.dashed")
        #expect(VerdictPresentation.forVerdict(.malicious, locale: "en").color == "red")
    }
}
