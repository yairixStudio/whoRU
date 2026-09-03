import Foundation
import Testing
@testable import WhoRUCore

private func sampleRecord(sha: String, service: PermissionService = .downloadsFolder, daysAgo: Double = 0, decision: UserDecision = .unknown) -> ScanRecord {
    var record = ScanRecord(
        startedAt: Date().addingTimeInterval(-daysAgo * 86400),
        prompt: PermissionPrompt(title: "t", requesterName: "X", service: service, requestPhrase: "p"),
        subject: Subject(path: "/tmp/x", resolver: ResolverOutcome(strategy: "test", confidence: .high)),
        evidence: [
            EvidenceItem(key: .sha256, status: .pass, weight: .base, summary: sha, facts: [Fact.sha256: sha]),
            EvidenceItem(key: .signerIdentity, status: .pass, weight: .critical, summary: "s", facts: [Fact.signerTeamID: "TEAM"]),
        ],
        userDecision: decision
    )
    record.verdict = Verdict(verdict: .legitimate, confidence: 90, headline: "h", whatItIs: "w", whyItAsks: "y", fit: .matches, recommendation: .allow, reasons: [], ifDenied: "d", suggestedQuestions: [], technicalNotes: "")
    record.costUSD = 0.01
    return record
}

@Suite struct StoreTests {
    func temporaryStore() -> JSONFileScanStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whoru-tests-\(UUID().uuidString)")
        return JSONFileScanStore(directory: dir)
    }

    @Test func roundTripsRecords() async throws {
        let store = temporaryStore()
        let record = sampleRecord(sha: "abc")
        try await store.save(record)
        let loaded = try await store.load(id: record.id)
        #expect(loaded == record)
        let reopened = JSONFileScanStore(directory: store.directory)
        #expect(try await reopened.all().count == 1)
    }

    @Test func cacheLooksUpByHashAndServiceWithinWindow() async throws {
        let store = temporaryStore()
        try await store.save(sampleRecord(sha: "abc", daysAgo: 2))
        try await store.save(sampleRecord(sha: "abc", service: .camera, daysAgo: 1))
        try await store.save(sampleRecord(sha: "abc", daysAgo: 40))
        let hit = try await store.cachedVerdict(sha256: "abc", service: .downloadsFolder, within: 30)
        #expect(hit != nil)
        #expect(hit?.prompt.service == .downloadsFolder)
        let miss = try await store.cachedVerdict(sha256: "zzz", service: .downloadsFolder, within: 30)
        #expect(miss == nil)
    }

    @Test func historyCountsDecisions() async throws {
        let store = temporaryStore()
        try await store.save(sampleRecord(sha: "a", decision: .allowed))
        try await store.save(sampleRecord(sha: "b", decision: .denied))
        try await store.save(sampleRecord(sha: "c", decision: .allowed))
        let history = try await store.history(teamID: "TEAM", sha256: nil)
        #expect(history.timesSeen == 3)
        #expect(history.timesAllowed == 2)
        #expect(history.timesDenied == 1)
        #expect(history.lastVerdict == .legitimate)
    }

    @Test func purgeRemovesOldRecords() async throws {
        let store = temporaryStore()
        try await store.save(sampleRecord(sha: "old", daysAgo: 100))
        try await store.save(sampleRecord(sha: "new", daysAgo: 1))
        try await store.purge(olderThan: 90)
        let all = try await store.all()
        #expect(all.count == 1)
        #expect(all.first?.sha256 == "new")
    }

    @Test func monthlySpendSumsThisMonth() async throws {
        let store = temporaryStore()
        try await store.save(sampleRecord(sha: "a"))
        try await store.save(sampleRecord(sha: "b"))
        #expect(try await store.monthlySpend() == 0.02)
    }
}

@Suite struct JSONValueTests {
    @Test func roundTripsThroughText() throws {
        let value: JSONValue = ["a": 1, "b": [true, "x", nil], "c": ["d": 2.5]]
        let text = value.string()
        let back = try JSONValue.parse(text)
        #expect(back == value)
        #expect(back["c"]?["d"]?.doubleValue == 2.5)
        #expect(back["b"]?[1]?.stringValue == "x")
        #expect(back["a"]?.intValue == 1)
    }

    @Test func integersEncodeWithoutDecimalPoint() throws {
        let text = JSONValue.object(["n": 42]).string()
        #expect(text.contains("42"))
        #expect(!text.contains("42.0"))
    }

    @Test func encodesCodableValues() throws {
        let verdict = Verdict(verdict: .suspicious, confidence: 40, headline: "h", whatItIs: "w", whyItAsks: "y", fit: .unusual, recommendation: .investigate, reasons: [VerdictReason(kind: .evidence, ref: "sha256", text: "t")], ifDenied: "d", suggestedQuestions: ["q"], technicalNotes: "n")
        let json = try JSONValue(encoding: verdict)
        #expect(json["verdict"]?.stringValue == "suspicious")
        #expect(json["what_it_is"]?.stringValue == "w")
        #expect(try json.decode(Verdict.self) == verdict)
    }
}

@Suite struct CommandTests {
    @Test func runsWithArgumentArray() async throws {
        let output = try await Command.run("/bin/echo", ["hello", "; rm -rf /"])
        #expect(output.succeeded)
        #expect(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello ; rm -rf /")
    }

    @Test func timesOut() async throws {
        let output = try await Command.run("/bin/sleep", ["5"], timeout: .milliseconds(200))
        #expect(output.timedOut)
        #expect(!output.succeeded)
    }

    @Test func rejectsNonExecutable() async {
        await #expect(throws: CommandError.self) {
            _ = try await Command.run("/nonexistent/binary", [])
        }
    }

    // The disclaimed path is a separate implementation (posix_spawn); it must
    // keep every part of the contract the Process path has.

    @Test func disclaimedReturnsOutput() async throws {
        let output = try await Command.run("/bin/echo", ["hello", "; rm -rf /"], disclaimResponsibility: true)
        #expect(output.succeeded)
        #expect(output.status == 0)
        #expect(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello ; rm -rf /")
        #expect(output.stderr.isEmpty)
    }

    @Test func disclaimedPropagatesExitStatus() async throws {
        let output = try await Command.run("/usr/bin/false", [], disclaimResponsibility: true)
        #expect(!output.succeeded)
        #expect(output.status == 1)
        #expect(!output.timedOut)
    }

    @Test func disclaimedHonoursEnvironmentAndWorkingDirectory() async throws {
        let env = try await Command.run("/usr/bin/env", [], environment: ["WHORU_TEST": "marker", "PATH": "/usr/bin:/bin"], disclaimResponsibility: true)
        #expect(env.succeeded)
        let lines = env.stdout.split(separator: "\n").map(String.init)
        #expect(lines.contains("WHORU_TEST=marker"))
        #expect(!lines.contains { $0.hasPrefix("HOME=") })

        let pwd = try await Command.run("/bin/pwd", [], workingDirectory: "/usr/bin", disclaimResponsibility: true)
        #expect(pwd.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "/usr/bin")
    }

    @Test func disclaimedCapturesBothStreamsWithoutDeadlock() async throws {
        // dd writes 200 KB to stdout and its statistics to stderr; larger than a pipe buffer on either side.
        let output = try await Command.run("/bin/dd", ["if=/dev/zero", "bs=1024", "count=200"], disclaimResponsibility: true)
        #expect(output.succeeded)
        #expect(output.stdout.utf8.count == 200 * 1024)
        #expect(output.stderr.contains("200"))
    }

    @Test func disclaimedTimesOut() async throws {
        let output = try await Command.run("/bin/sleep", ["5"], timeout: .milliseconds(200), disclaimResponsibility: true)
        #expect(output.timedOut)
        #expect(!output.succeeded)
        #expect(output.durationMs < 3000)
    }
}

@Suite struct BundleRedactionTests {
    @Test func redactsHomeDirectoryAndDropsRaw() {
        let prompt = PermissionPrompt(title: "t", requesterName: "X", service: .camera, requestPhrase: "p")
        let subject = Subject(path: "/Users/me/Downloads/X.app/Contents/MacOS/X", bundlePath: "/Users/me/Downloads/X.app", resolver: ResolverOutcome(strategy: "s", confidence: .high))
        let bundle = EvidenceBundle(
            prompt: prompt, subject: subject,
            evidence: [EvidenceItem(key: .location, status: .warn, weight: .medium, summary: "in /Users/me/Downloads", raw: "secret raw", facts: ["p": "/Users/me/x"])],
            hardScore: HardScoreResult(score: .amber, reasons: [])
        )
        let redacted = bundle.redactedForModel(homeDirectory: "/Users/me")
        #expect(redacted.subject?.path == "~/Downloads/X.app/Contents/MacOS/X")
        #expect(redacted.subject?.bundlePath == "~/Downloads/X.app")
        #expect(redacted.evidence.first?.raw == nil)
        #expect(redacted.evidence.first?.summary == "in ~/Downloads")
        #expect(redacted.evidence.first?.facts["p"] == "~/x")
    }
}
