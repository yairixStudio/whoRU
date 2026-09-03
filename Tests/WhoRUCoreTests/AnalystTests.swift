import Foundation
import Testing
@testable import WhoRUCore

private func verdict(_ kind: VerdictKind, confidence: Int = 90, recommendation: Recommendation = .allow, reasons: [VerdictReason] = []) -> Verdict {
    Verdict(verdict: kind, confidence: confidence, headline: "h", whatItIs: "w", whyItAsks: "y", fit: .matches, recommendation: recommendation, reasons: reasons, ifDenied: "d", suggestedQuestions: ["a", "b", "c", "d"], technicalNotes: "")
}

@Suite struct VerdictValidatorTests {
    let validator = VerdictValidator()
    let keys: Set<String> = ["codesign.identity", "sha256"]

    @Test func redRejectsLegitimate() {
        let hard = HardScoreResult(score: .red, reasons: [ScoreReason(code: "signature.broken")])
        #expect(validator.validate(verdict(.legitimate), against: hard, evidenceKeys: keys) == .rejected(reason: "the model called a hard-red subject legitimate"))
        #expect(validator.validate(verdict(.probablyLegitimate), against: hard, evidenceKeys: keys) == .rejected(reason: "the model called a hard-red subject probably_legitimate"))
    }

    @Test func redRejectsAllowRecommendation() {
        let hard = HardScoreResult(score: .red, reasons: [])
        let result = validator.validate(verdict(.suspicious, recommendation: .allow), against: hard, evidenceKeys: keys)
        #expect(result == .rejected(reason: "the model recommended allowing a hard-red subject"))
    }

    @Test func redAcceptsSuspiciousWithInvestigate() {
        let hard = HardScoreResult(score: .red, reasons: [])
        if case .accepted(let v) = validator.validate(verdict(.suspicious, recommendation: .investigate), against: hard, evidenceKeys: keys) {
            #expect(v.verdict == .suspicious)
        } else {
            Issue.record("expected acceptance")
        }
    }

    @Test func amberCapsAtProbablyLegitimate() {
        let hard = HardScoreResult(score: .amber, reasons: [])
        guard case .accepted(let v) = validator.validate(verdict(.legitimate, confidence: 95), against: hard, evidenceKeys: keys) else {
            Issue.record("expected acceptance"); return
        }
        #expect(v.verdict == .probablyLegitimate)
        #expect(v.confidence == 75)
    }

    @Test func greenAcceptsAnything() {
        let hard = HardScoreResult(score: .green, reasons: [])
        guard case .accepted(let v) = validator.validate(verdict(.legitimate, confidence: 140), against: hard, evidenceKeys: keys) else {
            Issue.record("expected acceptance"); return
        }
        #expect(v.confidence == 100)
        #expect(v.suggestedQuestions.count == 3)
    }

    @Test func unknownEvidenceRefsBecomeInferences() {
        let hard = HardScoreResult(score: .green, reasons: [])
        let reasons = [
            VerdictReason(kind: .evidence, ref: "sha256", text: "real"),
            VerdictReason(kind: .evidence, ref: "made.up", text: "fake"),
            VerdictReason(kind: .evidence, ref: nil, text: "missing"),
        ]
        guard case .accepted(let v) = validator.validate(verdict(.legitimate, reasons: reasons), against: hard, evidenceKeys: keys) else {
            Issue.record("expected acceptance"); return
        }
        #expect(v.reasons.map(\.kind) == [.evidence, .inference, .inference])
        #expect(v.reasons[1].ref == nil)
    }

    @Test func incoherentRecommendationsAreSoftened() {
        let hard = HardScoreResult(score: .green, reasons: [])
        guard case .accepted(let v) = validator.validate(verdict(.legitimate, recommendation: .deny), against: hard, evidenceKeys: keys) else {
            Issue.record("expected acceptance"); return
        }
        #expect(v.recommendation == .investigate)
        #expect(validator.validate(verdict(.malicious, recommendation: .allow), against: hard, evidenceKeys: keys) == .rejected(reason: "the model called the subject malicious but recommended allowing it"))
    }

    @Test func amberNeverRecommendsAllow() {
        let hard = HardScoreResult(score: .amber, reasons: [ScoreReason(code: "unsigned")])
        guard case .accepted(let v) = validator.validate(verdict(.legitimate, confidence: 90, recommendation: .allow), against: hard, evidenceKeys: keys) else {
            Issue.record("expected acceptance"); return
        }
        #expect(v.verdict == .probablyLegitimate)
        #expect(v.confidence == 75)
        #expect(v.recommendation == .investigate)
        guard case .accepted(let suspicious) = validator.validate(verdict(.suspicious, recommendation: .allow), against: hard, evidenceKeys: keys) else {
            Issue.record("expected acceptance"); return
        }
        #expect(suspicious.recommendation == .investigate)
        guard case .accepted(let denied) = validator.validate(verdict(.suspicious, recommendation: .deny), against: hard, evidenceKeys: keys) else {
            Issue.record("expected acceptance"); return
        }
        #expect(denied.recommendation == .deny)
    }

    @Test func unknownVerdictNeverRecommendsAllow() {
        for score in [HardScore.green, .amber] {
            let hard = HardScoreResult(score: score, reasons: [])
            guard case .accepted(let v) = validator.validate(verdict(.unknown, recommendation: .allow), against: hard, evidenceKeys: keys) else {
                Issue.record("expected acceptance"); return
            }
            #expect(v.recommendation == .investigate)
        }
        let green = HardScoreResult(score: .green, reasons: [])
        guard case .accepted(let v) = validator.validate(verdict(.legitimate, recommendation: .allow), against: green, evidenceKeys: keys) else {
            Issue.record("expected acceptance"); return
        }
        #expect(v.recommendation == .allow)
    }
}

@Suite struct PartialJSONTests {
    @Test func extractsHeadlineFromPartialStream() {
        let partial = #"{"verdict": "legitimate", "confidence": 96, "headline": "This is Claude Code, safe to allow.", "what_it_is": "a com"#
        #expect(PartialJSON.headline(in: partial) == "This is Claude Code, safe to allow.")
        #expect(PartialJSON.headline(in: #"{"verdict": "legitimate", "headline": "not yet clo"#) == nil)
        #expect(PartialJSON.headline(in: #"{"verdict": "legitimate""#) == nil)
    }

    @Test func handlesEscapes() {
        let text = #"{"headline": "Say \"hi\"\nnow שלום"}"#
        #expect(PartialJSON.headline(in: text) == "Say \"hi\"\nnow שלום")
    }

    @Test func findsFirstObjectInProse() {
        let text = "Here is the verdict:\n```json\n{\"a\": {\"b\": \"}\"}, \"c\": [1, 2]}\n```\nDone."
        #expect(PartialJSON.firstObject(in: text) == "{\"a\": {\"b\": \"}\"}, \"c\": [1, 2]}")
        #expect(PartialJSON.firstObject(in: "no json here") == nil)
        #expect(PartialJSON.firstObject(in: "{\"unclosed\": 1") == nil)
    }
}

@Suite struct ClaudeAPIRequestTests {
    @Test func structuredRequestHasSchemaCachingAndFallbacks() {
        let analyst = ClaudeAPIAnalyst(apiKey: "k")
        let prompt = PermissionPrompt(title: "t", requesterName: "X", service: .camera, requestPhrase: "p")
        let bundle = EvidenceBundle(prompt: prompt, subject: nil, evidence: [], hardScore: HardScoreResult(score: .amber, reasons: []))
        let request = AnalysisRequest(bundle: bundle, model: "claude-opus-5", effort: "medium", allowWebSearch: true)
        let body = analyst.requestBody(messages: [["role": "user", "content": "hi"]], request: request, tools: NoTools(), structured: true)
        #expect(body["model"]?.stringValue == "claude-opus-5")
        #expect(body["stream"]?.boolValue == true)
        #expect(body["thinking"]?["type"]?.stringValue == "adaptive")
        #expect(body["output_config"]?["effort"]?.stringValue == "medium")
        #expect(body["output_config"]?["format"]?["type"]?.stringValue == "json_schema")
        #expect(body["system"]?[0]?["cache_control"]?["type"]?.stringValue == "ephemeral")
        #expect(body["fallbacks"]?.stringValue == "default")
        #expect(body["tools"]?[0]?["type"]?.stringValue == "web_search_20260209")
        #expect(body["max_tokens"]?.intValue == 16000)
    }

    @Test func chatRequestHasNoFormatAndNoFallbacksForSonnet() {
        let analyst = ClaudeAPIAnalyst(apiKey: "k")
        let prompt = PermissionPrompt(title: "t", requesterName: "X", service: .camera, requestPhrase: "p")
        let bundle = EvidenceBundle(prompt: prompt, subject: nil, evidence: [], hardScore: HardScoreResult(score: .amber, reasons: []))
        let request = AnalysisRequest(bundle: bundle, model: "claude-sonnet-5")
        let body = analyst.requestBody(messages: [], request: request, tools: NoTools(), structured: false)
        #expect(body["output_config"]?["format"] == nil)
        #expect(body["fallbacks"] == nil)
        #expect(body["tools"] == nil)
        #expect(body["system"]?.arrayValue?.count == 2)
    }

    @Test func schemaOrdersHeadlineEarly() {
        let required = AnalystPrompt.verdictSchema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        #expect(Array(required.prefix(3)) == ["verdict", "confidence", "headline"])
        #expect(AnalystPrompt.systemPrompt.contains("hard_score \"red\""))
    }
}

@Suite struct PricingTests {
    @Test func estimatesCost() {
        #expect(Pricing.cost(model: "claude-opus-5", inputTokens: 1_000_000, outputTokens: 0) == 5)
        #expect(Pricing.cost(model: "claude-haiku-4-5", inputTokens: 0, outputTokens: 1_000_000) == 5)
        #expect(Pricing.cost(model: "unknown-model", inputTokens: 1_000_000, outputTokens: 1_000_000) == 0)
    }
}

@Suite struct ClaudeCodeParsingTests {
    @Test func parsesHeadlessOutput() throws {
        let output = CommandOutput(stdout: #"{"type":"result","is_error":false,"result":"Sure. {\"verdict\":\"legitimate\"}","session_id":"abc","total_cost_usd":0.012,"usage":{"input_tokens":10,"output_tokens":5}}"#, stderr: "", status: 0, durationMs: 1, timedOut: false)
        let (text, session, usage) = try ClaudeCodeAnalyst.parse(output)
        #expect(session == "abc")
        #expect(usage.cost == 0.012)
        #expect(usage.input == 10)
        #expect(PartialJSON.firstObject(in: text) == #"{"verdict":"legitimate"}"#)
    }

    @Test func reportsErrors() {
        let output = CommandOutput(stdout: #"{"is_error":true,"result":"boom"}"#, stderr: "", status: 0, durationMs: 1, timedOut: false)
        #expect(throws: AnalystError.self) { _ = try ClaudeCodeAnalyst.parse(output) }
    }

    @Test func allowedToolsIsTheShimOrNothing() {
        #expect(ClaudeCodeAnalyst.allowedTools(inspectShim: "/Applications/whoRU.app/Contents/MacOS/whoru-inspect") == ["Bash(/Applications/whoRU.app/Contents/MacOS/whoru-inspect:*)"])
        #expect(ClaudeCodeAnalyst.allowedTools(inspectShim: nil).isEmpty)
        #expect(ClaudeCodeAnalyst.toolInstruction(inspectShim: nil).contains("no commands"))
        let instruction = ClaudeCodeAnalyst.toolInstruction(inspectShim: "/x/whoru-inspect")
        #expect(instruction.contains("/x/whoru-inspect"))
        for subcommand in ClaudeCodeAnalyst.inspectSubcommands { #expect(instruction.contains(subcommand)) }
    }

    @Test func subjectEnvironmentExpandsRedactedPaths() {
        let subject = Subject(path: "~/Downloads/X.app/Contents/MacOS/X", pid: 4242, bundlePath: "~/Downloads/X.app", resolver: ResolverOutcome(strategy: "s", confidence: .high))
        let env = ClaudeCodeAnalyst.subjectEnvironment(for: subject, homeDirectory: "/Users/me")
        #expect(env["WHORU_SUBJECT_PATH"] == "/Users/me/Downloads/X.app")
        #expect(env["WHORU_SUBJECT_EXECUTABLE"] == "/Users/me/Downloads/X.app/Contents/MacOS/X")
        #expect(env["WHORU_SUBJECT_PID"] == "4242")
        #expect(ClaudeCodeAnalyst.subjectEnvironment(for: nil).isEmpty)
    }
}

/// Runs the built `whoru-inspect` binary. `swift test` builds every target,
/// so the shim sits in the build directory next to this target's resource
/// bundle (the test host itself lives in the toolchain, so `Bundle.main`
/// would not lead there).
@Suite struct InspectShimTests {
    static var shim: String? {
        ClaudeCodeAnalyst.locateInspectShim(near: Bundle.module.bundleURL.deletingLastPathComponent())
    }

    func run(_ arguments: [String], subject: String?, pid: Int32? = nil) async throws -> CommandOutput {
        let shim = try #require(Self.shim, "whoru-inspect was not built next to the tests")
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path]
        if let subject { env["WHORU_SUBJECT_PATH"] = subject }
        if let pid { env["WHORU_SUBJECT_PID"] = String(pid) }
        return try await Command.run(shim, arguments, timeout: .seconds(20), environment: env)
    }

    @Test func filesShowsFoldersUnderHomeOnly() async throws {
        // Our own process has the test bundle open, somewhere under the home directory.
        let output = try await run(["files"], subject: "/bin/ls", pid: ProcessInfo.processInfo.processIdentifier)
        #expect(output.status == 0)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let lines = output.stdout.split(separator: "\n").map(String.init)
        for line in lines {
            #expect(line.hasPrefix("~"))
            #expect(!line.contains(home))
        }
        #expect(Set(lines).count == lines.count)
    }

    @Test func processNeedsAPID() async throws {
        let output = try await run(["process"], subject: "/bin/ls")
        #expect(output.status == 2)
        #expect(output.stderr.contains("WHORU_SUBJECT_PID"))
    }

    @Test func signaturePrintsCodesignOutput() async throws {
        let output = try await run(["signature"], subject: "/bin/ls")
        #expect(output.status == 0)
        #expect(output.combined.contains("Identifier=com.apple.ls"))
        #expect(output.combined.contains("CodeDirectory"))
    }

    @Test func helpListsSubcommands() async throws {
        let output = try await run(["help"], subject: "/bin/ls")
        #expect(output.status == 0)
        for subcommand in ClaudeCodeAnalyst.inspectSubcommands { #expect(output.stdout.contains(subcommand)) }
    }

    @Test func unknownSubcommandExits2() async throws {
        let output = try await run(["strings"], subject: "/bin/ls")
        #expect(output.status == 2)
        #expect(output.stderr.contains("unknown subcommand"))
        let extra = try await run(["signature", "/etc/passwd"], subject: "/bin/ls")
        #expect(extra.status == 2)
    }

    @Test func missingOrBogusSubjectExits2() async throws {
        let missing = try await run(["signature"], subject: nil)
        #expect(missing.status == 2)
        #expect(missing.stderr.contains("WHORU_SUBJECT_PATH"))
        let bogus = try await run(["signature"], subject: "/nonexistent/thing")
        #expect(bogus.status == 2)
        let folder = try await run(["signature"], subject: "/usr/bin")
        #expect(folder.status == 2)
    }
}

@Suite struct PortableSHA256Tests {
    @Test func matchesKnownVectors() {
        var empty = PortableSHA256()
        #expect(empty.finalizeHex() == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        var abc = PortableSHA256()
        abc.update(Data("abc".utf8))
        #expect(abc.finalizeHex() == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        var long = PortableSHA256()
        long.update(Data(repeating: 0x61, count: 1_000_000))
        #expect(long.finalizeHex() == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    @Test func chunkingDoesNotChangeResult() {
        var whole = PortableSHA256()
        let data = Data((0..<1000).map { UInt8($0 % 251) })
        whole.update(data)
        var parts = PortableSHA256()
        parts.update(data.prefix(63))
        parts.update(data.dropFirst(63).prefix(130))
        parts.update(data.dropFirst(193))
        #expect(whole.finalizeHex() == parts.finalizeHex())
    }
}
