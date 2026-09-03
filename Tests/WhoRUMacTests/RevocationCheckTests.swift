import Foundation
import Security
import Testing
import WhoRUCore
@testable import WhoRUMac

@Suite struct RevocationClassificationTests {
    @Test func successMeansNotRevoked() {
        let result = RevocationCheck.classify(.init(status: errSecSuccess))
        #expect(result.status == .pass)
        #expect(result.facts == [Fact.signatureRevoked: "false"])
    }

    @Test func revocationCodesMeanRevoked() {
        for code: OSStatus in [-2_147_409_652, errSecCertificateRevoked, errSecCSRevokedNotarization] {
            let result = RevocationCheck.classify(.init(status: code, errorDomain: "NSOSStatusErrorDomain", errorCode: Int(code), description: "Error Domain=NSOSStatusErrorDomain Code=\(code)"))
            #expect(result.status == .fail, "code \(code)")
            #expect(result.facts == [Fact.signatureRevoked: "true"], "code \(code)")
        }
    }

    @Test func revocationCodeInTheErrorAloneIsEnough() {
        let result = RevocationCheck.classify(.init(status: errSecCSSignatureUntrusted, errorDomain: "NSOSStatusErrorDomain", errorCode: Int(errSecCertificateRevoked), description: nil))
        #expect(result.status == .fail)
        #expect(result.facts[Fact.signatureRevoked] == "true")
    }

    @Test func revokedInTheDescriptionIsEnough() {
        let result = RevocationCheck.classify(.init(status: errSecCSSignatureUntrusted, description: "The certificate was Revoked."))
        #expect(result.status == .fail)
        #expect(result.facts[Fact.signatureRevoked] == "true")
    }

    @Test func otherFailuresLeaveTheQuestionOpen() {
        for outcome in [
            RevocationCheck.ValidationOutcome(status: errSecCSSignatureUntrusted, description: "signature is valid but signer is not trusted"),
            RevocationCheck.ValidationOutcome(status: errSecCSSignatureFailed),
            RevocationCheck.ValidationOutcome(status: errSecCSUnsigned, errorDomain: "NSOSStatusErrorDomain", errorCode: Int(errSecCSUnsigned)),
            RevocationCheck.ValidationOutcome(status: -1, description: "network unreachable"),
        ] {
            let result = RevocationCheck.classify(outcome)
            #expect(result.status == .info, "status \(outcome.status)")
            #expect(result.summary == "revocation could not be checked")
            #expect(result.facts[Fact.signatureRevoked] == nil, "status \(outcome.status)")
        }
    }

    @Test func appleAndUnsignedFilesAreSkipped() async throws {
        let prompt = PermissionPrompt(title: "t", requesterName: "Finder", service: .camera, requestPhrase: "p")
        let finder = Subject(path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", bundlePath: "/System/Library/CoreServices/Finder.app", resolver: ResolverOutcome(strategy: "test", confidence: .high))
        let item = try await RevocationCheck().run(on: finder, context: CheckContext(prompt: prompt))
        #expect(item.status == .skipped)
        #expect(item.facts.isEmpty)

        let script = FileManager.default.temporaryDirectory.appendingPathComponent("whoru-unsigned-\(UUID().uuidString).sh")
        try "#!/bin/sh\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }
        let unsigned = Subject(path: script.path, resolver: ResolverOutcome(strategy: "test", confidence: .high))
        let unsignedItem = try await RevocationCheck().run(on: unsigned, context: CheckContext(prompt: prompt))
        #expect(unsignedItem.status == .skipped)
        #expect(unsignedItem.facts.isEmpty)
    }
}
