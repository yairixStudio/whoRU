import Foundation
import Testing
@testable import WhoRUCore

private func item(_ key: EvidenceKey, _ facts: [String: String]) -> EvidenceItem {
    EvidenceItem(key: key, status: .pass, weight: .high, summary: key.rawValue, facts: facts)
}

private let subject = Subject(path: "/Applications/Thing.app", resolver: ResolverOutcome(strategy: "test", confidence: .high))

@Suite struct StrictnessTests {
    let knownPublisherNotNotarized = [
        item(.signerIdentity, [Fact.signerKind: "developerID", Fact.signerTeamID: "Q6L2SF6YDW", Fact.signatureValid: "true"]),
        item(.gatekeeper, [Fact.notarized: "unknown"]),
        item(.publisher, [Fact.publisherName: "Anthropic PBC", Fact.publisherTrust: "normal"]),
    ]

    @Test func standardTrustsKnownPublishers() {
        let prompt = PermissionPrompt(title: "t", requesterName: "Thing", service: .downloadsFolder, requestPhrase: "p")
        #expect(HardScoreEngine(strictness: .standard).score(knownPublisherNotNotarized, subject: subject, prompt: prompt).score == .green)
    }

    @Test func strictRequiresNotarizationForKnownPublishers() {
        let prompt = PermissionPrompt(title: "t", requesterName: "Thing", service: .downloadsFolder, requestPhrase: "p")
        let result = HardScoreEngine(strictness: .strict).score(knownPublisherNotNotarized, subject: subject, prompt: prompt)
        #expect(result.score == .amber)
    }

    @Test func strictKeepsNotarizedGreen() {
        let prompt = PermissionPrompt(title: "t", requesterName: "Thing", service: .downloadsFolder, requestPhrase: "p")
        let evidence = [
            item(.signerIdentity, [Fact.signerKind: "developerID", Fact.signerTeamID: "ABC", Fact.signatureValid: "true"]),
            item(.gatekeeper, [Fact.notarized: "true"]),
        ]
        #expect(HardScoreEngine(strictness: .strict).score(evidence, subject: subject, prompt: prompt).score == .green)
    }

    @Test func strictDemotesUnknownOriginAndSensitivePermissions() {
        let notarized = [
            item(.signerIdentity, [Fact.signerKind: "developerID", Fact.signerTeamID: "ABC", Fact.signatureValid: "true"]),
            item(.gatekeeper, [Fact.notarized: "true"]),
            item(.downloadOrigin, [Fact.downloadSource: "unknown"]),
        ]
        let prompt = PermissionPrompt(title: "t", requesterName: "Thing", service: .downloadsFolder, requestPhrase: "p")
        #expect(HardScoreEngine(strictness: .strict).score(notarized, subject: subject, prompt: prompt).score == .amber)
        #expect(HardScoreEngine(strictness: .standard).score(notarized, subject: subject, prompt: prompt).score == .green)

        let camera = PermissionPrompt(title: "t", requesterName: "Thing", service: .camera, requestPhrase: "p")
        let unverified = [
            item(.signerIdentity, [Fact.signerKind: "developerID", Fact.signerTeamID: "Q6L2SF6YDW", Fact.signatureValid: "true"]),
            item(.publisher, [Fact.publisherName: "Anthropic PBC", Fact.publisherTrust: "normal"]),
        ]
        #expect(HardScoreEngine(strictness: .strict).score(unverified, subject: subject, prompt: camera).score == .amber)
    }

    @Test func officialSourceMatchStaysGreenUnderStrict() {
        let prompt = PermissionPrompt(title: "t", requesterName: "Thing", service: .camera, requestPhrase: "p")
        let evidence = [
            item(.signerIdentity, [Fact.signerKind: "developerID", Fact.signerTeamID: "Q6L2SF6YDW", Fact.signatureValid: "true"]),
            item(.officialManifest, [Fact.manifestMatch: "true"]),
            item(.downloadOrigin, [Fact.downloadSource: "unknown"]),
        ]
        #expect(HardScoreEngine(strictness: .strict).score(evidence, subject: subject, prompt: prompt).score == .green)
    }
}

@Suite struct SettingsDecodingTests {
    @Test func oldFilesDecodeWithDefaultsForNewFields() throws {
        let old = #"{"launchAtLogin": false, "engine": "claudeCode", "historyRetentionDays": 7}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(old.utf8))
        #expect(settings.launchAtLogin == false)
        #expect(settings.engine == .claudeCode)
        #expect(settings.historyRetentionDays == 7)
        #expect(settings.strictness == .standard)
        #expect(settings.engineModels.isEmpty)
        #expect(settings.model(for: .codex) == "")
    }

    @Test func unknownEngineValueFallsBackToDefaults() throws {
        let broken = #"{"engine": "something-new"}"#
        let settings = try? JSONDecoder().decode(Settings.self, from: Data(broken.utf8))
        // Unknown enum values fail; the file store then falls back to defaults rather than crashing.
        #expect(settings == nil || settings?.engine == .auto)
    }

    @Test func engineSuggestionsStartWithDefault() {
        #expect(EngineChoice.codex.suggestedModels.first == "")
        #expect(EngineChoice.claudeCode.suggestedModels.contains("opus"))
        #expect(EngineChoice.claudeAPI.suggestedModels.isEmpty)
    }
}

@Suite struct CLIAgentTests {
    @Test func chatPromptCarriesTranscript() {
        let prompt = PermissionPrompt(title: "t", requesterName: "X", service: .camera, requestPhrase: "p")
        let bundle = EvidenceBundle(prompt: prompt, subject: nil, evidence: [], hardScore: HardScoreResult(score: .amber, reasons: []))
        let text = CLIAgent.chatPrompt(transcript: [["role": "assistant", "text": "First answer"]], bundle: bundle, question: "Why?")
        #expect(text.contains("Assistant: First answer"))
        #expect(text.hasSuffix("User: Why?\nAssistant:"))
    }

    @Test func locateFindsNothingForMissingBinary() {
        #expect(CLIAgent.locate(names: ["definitely-not-a-real-binary-name"]) == nil)
    }
}
