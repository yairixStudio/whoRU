import Foundation
import Testing
@testable import WhoRUCore

private let prompt = PermissionPrompt(title: "“Google Chrome” would like to access files in your Downloads folder.", requesterName: "Google Chrome", service: .downloadsFolder, requestPhrase: "access files in your Downloads folder")

private let chrome = Subject(
    path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", pid: 10, bundleID: "com.google.Chrome", displayName: "Google Chrome",
    bundlePath: "/Applications/Google Chrome.app", resolver: ResolverOutcome(strategy: "running_process_basename", confidence: .high)
)

private let notarized: [EvidenceItem] = [
    EvidenceItem(key: .signerIdentity, status: .pass, weight: .critical, summary: "Developer ID", facts: [Fact.signerKind: "developerID", Fact.signerTeamID: "EQHXZ8M8AV", Fact.signatureValid: "true"]),
    EvidenceItem(key: .gatekeeper, status: .pass, weight: .high, summary: "notarized", facts: [Fact.notarized: "true"]),
    EvidenceItem(key: .publisher, status: .pass, weight: .high, summary: "Google LLC", facts: [Fact.publisherName: "Google LLC", Fact.publisherTrust: "normal"]),
]

private func record(candidates: [SubjectCandidate] = [], verdict: Verdict? = nil) -> ScanRecord {
    var record = ScanRecord(prompt: prompt, subject: chrome, candidates: candidates, evidence: notarized)
    record.hardScore = HardScoreEngine().score(notarized, subject: chrome, prompt: prompt, candidates: candidates)
    record.deterministicHeadline = HeadlineComposer().headline(for: record.hardScore!, subject: chrome, prompt: prompt, locale: "en")
    record.verdict = verdict
    return record
}

private func verdict(_ kind: VerdictKind, recommendation: Recommendation) -> Verdict {
    Verdict(verdict: kind, confidence: 90, headline: "h", whatItIs: "w", whyItAsks: "y", fit: .matches, recommendation: recommendation, reasons: [], ifDenied: "d", suggestedQuestions: [], technicalNotes: "")
}

private let attributedChrome = AttributedIdentity(pid: 10, binaryPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", identifier: "com.google.Chrome")

@Suite struct IdentityConfirmationTests {
    @Test func attributionNamingTheSubjectConfirmsIt() throws {
        let outcome = IdentityConfirmation.apply(to: record(), attributed: attributedChrome, running: nil, strictness: .standard, locale: "en")
        guard case .confirmed(let updated) = outcome else { Issue.record("expected confirmed"); return }
        let identity = try #require(updated.evidence.first { $0.key == .identity })
        #expect(identity.status == .pass)
        #expect(identity.facts[Fact.identityConfirmed] == "true")
        #expect(identity.facts[Fact.identityPID] == "10")
        #expect(identity.summary.contains("pid 10"))
        #expect(updated.hardScore?.score == .green)
        #expect(updated.evidence.contains { $0.key == .runningCode } == false)
    }

    @Test func confirmationSettlesACollision() {
        let candidates = [
            SubjectCandidate(path: chrome.path, pid: 10, strategy: "running_process_basename", confidence: .high),
            SubjectCandidate(path: "/Users/me/Library/Caches/x/Google Chrome", pid: 20, strategy: "running_process_basename", confidence: .high),
        ]
        let before = record(candidates: candidates)
        #expect(before.hardScore?.score == .amber)
        #expect(before.hardScore?.reasons.first?.code == "resolver.collision")
        guard case .confirmed(let updated) = IdentityConfirmation.apply(to: before, attributed: attributedChrome, running: nil, strictness: .standard, locale: "en") else {
            Issue.record("expected confirmed"); return
        }
        #expect(updated.hardScore?.score == .green)
        #expect(updated.deterministicHeadline?.title == "Probably fine")
    }

    @Test func attributionNamingAnotherProgramAsksForARescan() {
        let other = AttributedIdentity(pid: 20, binaryPath: "/Users/me/Library/Caches/x/Google Chrome", identifier: "/Users/me/Library/Caches/x/Google Chrome")
        guard case .corrected(let subject) = IdentityConfirmation.apply(to: record(), attributed: other, running: nil, strictness: .standard, locale: "en") else {
            Issue.record("expected corrected"); return
        }
        #expect(subject.path == "/Users/me/Library/Caches/x/Google Chrome")
        #expect(subject.pid == 20)
        #expect(subject.bundleID == nil)
        #expect(subject.displayName == "Google Chrome")
        #expect(subject.resolver.strategy == "system_attribution")
        #expect(subject.resolver.confidence == .high)
    }

    @Test func noAttributionLeavesTheRecordAlone() {
        guard case .unconfirmed = IdentityConfirmation.apply(to: record(), attributed: nil, running: nil, strictness: .standard, locale: "en") else {
            Issue.record("expected unconfirmed"); return
        }
        var noSubject = record()
        noSubject.subject = nil
        guard case .corrected = IdentityConfirmation.apply(to: noSubject, attributed: attributedChrome, running: nil, strictness: .standard, locale: "en") else {
            Issue.record("an unresolved scan with an attribution is rescanned for the attributed program"); return
        }
    }

    @Test func namesMatchesByBundleIdentifierPathOrBundleContents() {
        #expect(IdentityConfirmation.names(chrome, attributed: AttributedIdentity(pid: 1, identifier: "COM.GOOGLE.CHROME")))
        #expect(IdentityConfirmation.names(chrome, attributed: AttributedIdentity(pid: 1, binaryPath: "/Applications/Google Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper")))
        #expect(IdentityConfirmation.names(chrome, attributed: AttributedIdentity(pid: 1, responsiblePath: chrome.path)))
        #expect(!IdentityConfirmation.names(chrome, attributed: AttributedIdentity(pid: 1, binaryPath: "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary")))
        #expect(!IdentityConfirmation.names(chrome, attributed: AttributedIdentity(pid: 1, identifier: "com.google.Chrome.canary")))
    }

    @Test func runningCodeMismatchTurnsRedAndDropsAReassuringVerdict() throws {
        let before = record(verdict: verdict(.legitimate, recommendation: .allow))
        let running = RunningCodeFacts(valid: true, matchesDisk: false, cdhash: "aa", diskCdhash: "bb", path: chrome.path)
        guard case .confirmed(let updated) = IdentityConfirmation.apply(to: before, attributed: attributedChrome, running: running, strictness: .standard, locale: "en") else {
            Issue.record("expected confirmed"); return
        }
        let item = try #require(updated.evidence.first { $0.key == .runningCode })
        #expect(item.status == .fail)
        #expect(item.facts[Fact.runningValid] == "true")
        #expect(item.facts[Fact.runningMatchesDisk] == "false")
        #expect(updated.hardScore?.score == .red)
        #expect(updated.hardScore?.reasons.first?.code == "running.mismatch")
        #expect(updated.deterministicHeadline?.title == "Do not allow")
        #expect(updated.verdict == nil)
        #expect(updated.verdictRejected == IdentityConfirmation.verdictDroppedReason)
    }

    @Test func aVerdictThatAlreadyWarnedStays() {
        // The running code is the file on disk but fails validation in memory
        // (a tampered process): a real red, and a verdict that already warned
        // is not dropped because it did not contradict the new evidence.
        let before = record(verdict: verdict(.suspicious, recommendation: .deny))
        let running = RunningCodeFacts(valid: false, matchesDisk: true, cdhash: "aa", diskCdhash: "aa")
        guard case .confirmed(let updated) = IdentityConfirmation.apply(to: before, attributed: attributedChrome, running: running, strictness: .standard, locale: "en") else {
            Issue.record("expected confirmed"); return
        }
        #expect(updated.hardScore?.score == .red)
        #expect(updated.hardScore?.reasons.first?.code == "running.invalid")
        #expect(updated.verdict != nil)
        #expect(updated.verdictRejected == nil)
    }

    @Test func aProcessThatCannotBeComparedIsNotAFinding() {
        // The pid had exited, or its code could not be hashed: no comparison
        // was possible, so it must not turn the scan red or add evidence.
        let before = record(verdict: verdict(.legitimate, recommendation: .allow))
        let gone = RunningCodeFacts(valid: false, matchesDisk: nil, error: "process 42 has no code object (gone?)")
        guard case .confirmed(let updated) = IdentityConfirmation.apply(to: before, attributed: attributedChrome, running: gone, strictness: .standard, locale: "en") else {
            Issue.record("expected confirmed"); return
        }
        #expect(updated.evidence.first { $0.key == .runningCode } == nil)
        #expect(updated.hardScore?.score == .green)
        #expect(updated.verdict != nil)
        #expect(updated.verdictRejected == nil)
    }

    @Test func reusedPidNeverProducesAFalseMismatch() {
        // What RunningCode.validate returns when the pid now runs a different
        // program than the one that was scanned: inconclusive, never a mismatch.
        let reused = RunningCodeFacts(valid: true, matchesDisk: nil, cdhash: "aa", path: "/Applications/Other.app", error: "process 42 is now /Applications/Other.app, not the program that was scanned")
        #expect(!reused.isConclusive)
        guard case .confirmed(let updated) = IdentityConfirmation.apply(to: record(), attributed: attributedChrome, running: reused, strictness: .standard, locale: "en") else {
            Issue.record("expected confirmed"); return
        }
        #expect(updated.evidence.first { $0.key == .runningCode } == nil)
        #expect(updated.hardScore?.score == .green)
    }

    @Test func validRunningCodeIsAPassAndUnsignedIsNotAFinding() {
        let fine = RunningCodeFacts(valid: true, matchesDisk: true, cdhash: "aa", diskCdhash: "aa")
        guard case .confirmed(let passed) = IdentityConfirmation.apply(to: record(), attributed: attributedChrome, running: fine, strictness: .standard, locale: "en") else {
            Issue.record("expected confirmed"); return
        }
        #expect(passed.evidence.first { $0.key == .runningCode }?.status == .pass)
        #expect(passed.hardScore?.score == .green)

        let unsigned = RunningCodeFacts(valid: false, matchesDisk: nil, error: "unsigned")
        guard case .confirmed(let skipped) = IdentityConfirmation.apply(to: record(), attributed: attributedChrome, running: unsigned, strictness: .standard, locale: "en") else {
            Issue.record("expected confirmed"); return
        }
        #expect(skipped.evidence.contains { $0.key == .runningCode } == false)
        #expect(skipped.hardScore?.score == .green)
    }

    @Test func applyingTwiceGivesTheSameRecord() {
        guard case .confirmed(let once) = IdentityConfirmation.apply(to: record(), attributed: attributedChrome, running: RunningCodeFacts(valid: true, matchesDisk: true), strictness: .standard, locale: "en"),
              case .confirmed(let twice) = IdentityConfirmation.apply(to: once, attributed: attributedChrome, running: RunningCodeFacts(valid: true, matchesDisk: true), strictness: .standard, locale: "en") else {
            Issue.record("expected confirmed"); return
        }
        #expect(once.evidence.count == twice.evidence.count)
        #expect(once.hardScore == twice.hardScore)
    }
}

@Suite struct FakeDialogHeadlineTests {
    @Test func fakeDialogHasItsOwnRedTitle() {
        let result = HardScoreResult(score: .red, reasons: [ScoreReason(code: "dialog.fake", params: ["owner": "osascript", "signer": ", signed by Apple"])])
        let en = HeadlineComposer().headline(for: result, subject: nil, prompt: prompt, locale: "en")
        #expect(en.title == "Not a system dialog")
        #expect(en.sentence == "This window is not a macOS permission dialog. It was drawn by osascript, signed by Apple.")
        let he = HeadlineComposer().headline(for: result, subject: nil, prompt: prompt, locale: "he")
        #expect(he.title == "לא דיאלוג של המערכת")
        #expect(he.sentence.contains("osascript"))
        #expect(VerdictPresentation.forHardScore(result, locale: "en").title == "Not a system dialog")
        #expect(VerdictPresentation.forHardScore(result, locale: "en").color == "red")
    }

    @Test func otherRedReasonsKeepDoNotAllow() {
        let result = HardScoreResult(score: .red, reasons: [ScoreReason(code: "signature.broken")])
        #expect(HeadlineComposer().headline(for: result, subject: nil, prompt: prompt, locale: "en").title == "Do not allow")
    }

    @Test func newStringsExistInBothLanguages() {
        for key in ["headline.notSystemDialog", "reason.dialog.fake", "reason.dialog.fake.signer"] {
            for locale in ["en", "he"] {
                #expect(L10n.tables[locale]?[key] != nil, "missing \(locale) string for \(key)")
            }
        }
        #expect(L10n.text("reason.dialog.fake.signer", locale: "en", ["signer": "X"]) == ", signed by X")
    }

    @Test func dialogOriginRoundTripsThroughJSON() throws {
        let origins: [DialogOrigin] = [.system(bundleID: "com.apple.UserNotificationCenter"), .unverified(owner: "osascript", path: "/usr/bin/osascript", signer: "Apple")]
        let data = try JSONEncoder().encode(origins)
        #expect(try JSONDecoder().decode([DialogOrigin].self, from: data) == origins)
        #expect(origins[0].isSystem)
        #expect(!origins[1].isSystem)
        #expect(DialogInstance(id: "1", pid: 1, frame: Rect(x: 0, y: 0, width: 1, height: 1), title: "t").origin == .system(bundleID: ""))
    }
}

@Suite struct UnconfirmedIdentityTests {
    private let prompt = PermissionPrompt(title: "“Google Chrome” would like to access files in your Downloads folder.", requesterName: "Google Chrome", service: .downloadsFolder, requestPhrase: "access files in your Downloads folder")
    private let chrome = Subject(path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", bundleID: "com.google.Chrome", displayName: "Google Chrome", bundlePath: "/Applications/Google Chrome.app", resolver: ResolverOutcome(strategy: "running_process_basename", confidence: .high))
    private var notarized: [EvidenceItem] {
        [
            EvidenceItem(key: .signerIdentity, status: .pass, weight: .critical, summary: "Google", facts: [Fact.signerKind: "developerID", Fact.signerTeamID: "EQHXZ8M8AV", Fact.signatureValid: "true"]),
            EvidenceItem(key: .gatekeeper, status: .pass, weight: .high, summary: "notarized", facts: [Fact.notarized: "true"]),
            EvidenceItem(key: .publisher, status: .pass, weight: .high, summary: "Google LLC", facts: [Fact.publisherName: "Google LLC", Fact.publisherTrust: "normal"]),
        ]
    }
    private func record(verdict: Verdict? = nil) -> ScanRecord {
        var r = ScanRecord(prompt: prompt, subject: chrome, evidence: notarized)
        r.hardScore = HardScoreEngine().score(notarized, subject: chrome, prompt: prompt)
        r.verdict = verdict
        return r
    }
    private func allowVerdict() -> Verdict {
        Verdict(verdict: .legitimate, confidence: 90, headline: "h", whatItIs: "w", whyItAsks: "y", fit: .matches, recommendation: .allow, reasons: [], ifDenied: "d", suggestedQuestions: [], technicalNotes: "")
    }

    @Test func unconfirmedIsAConcernAndStrictCapsGreen() {
        let standard = IdentityConfirmation.applyUnconfirmed(to: record(), strictness: .standard, locale: "en")
        #expect(standard.hardScore?.score == .green)
        #expect(standard.hardScore?.reasons.contains { $0.code == "identity.unconfirmed" } == true)
        #expect(standard.evidence.contains { $0.key == .identity && $0.facts[Fact.identityConfirmed] == "false" })

        let strict = IdentityConfirmation.applyUnconfirmed(to: record(), strictness: .strict, locale: "en")
        #expect(strict.hardScore?.score == .amber)
        #expect(strict.hardScore?.reasons.first?.code == "identity.unconfirmed")
    }

    @Test func strictWithdrawsAnAllowVerdictWhenTheRequestIsUnconfirmed() {
        let updated = IdentityConfirmation.applyUnconfirmed(to: record(verdict: allowVerdict()), strictness: .strict, locale: "en")
        #expect(updated.hardScore?.score == .amber)
        #expect(updated.verdict == nil)
        #expect(updated.verdictRejected == IdentityConfirmation.verdictDroppedReason)
    }

    @Test func aConfirmedIdentityIsNotOverwritten() {
        var confirmed = record()
        confirmed.evidence.append(EvidenceItem(key: .identity, status: .pass, weight: .high, summary: "confirmed", facts: [Fact.identityConfirmed: "true"]))
        let result = IdentityConfirmation.applyUnconfirmed(to: confirmed, strictness: .strict, locale: "en")
        #expect(result.evidence.first { $0.key == .identity }?.facts[Fact.identityConfirmed] == "true")
    }

    @Test func unconfirmedSentenceExistsInBothLanguages() {
        for locale in ["en", "he"] {
            #expect(L10n.text("reason.identity.unconfirmed", locale: locale) != "reason.identity.unconfirmed")
        }
    }
}
