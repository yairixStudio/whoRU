import Foundation
import Security
import WhoRUCore

/// Whether Apple has revoked the certificate that signed the file. The shared
/// signature inspection validates strictly but never enforces revocation, so a
/// Developer ID that Apple pulled still reads as valid there; this check asks
/// Security.framework again with revocation enforced, which may go online.
public struct RevocationCheck: EvidenceCheck {
    public let key: EvidenceKey = .revocation
    public let weight: EvidenceWeight = .critical
    public init() {}

    static let method = "SecStaticCodeCheckValidityWithErrors + kSecCSEnforceRevocationChecks"

    public func run(on subject: Subject, context: CheckContext) async throws -> EvidenceItem {
        let path = subject.verificationPath
        let signature = await CodeSignature.inspect(path: path)
        switch signature.kind {
        case .apple:
            return .skipped(key, weight: weight, reason: "Apple software; not subject to Developer ID revocation")
        case .unsigned, .adhoc, .unknown:
            return .skipped(key, weight: weight, reason: "no certificate to revoke")
        case .developerID, .appStore:
            break
        }

        let started = Date()
        let outcome: ValidationOutcome
        do {
            // The Security call blocks (it may contact Apple's OCSP responder), so
            // it runs on its own thread and the check gives up after a few seconds.
            outcome = try await withTimeout(.seconds(3)) {
                await Task.detached { Self.validate(path: path) }.value
            }
        } catch {
            return EvidenceItem(key: key, status: .info, weight: weight, summary: "revocation could not be checked", raw: "timed out", method: Self.method, durationMs: Self.elapsedMs(since: started))
        }
        let verdict = Self.classify(outcome)
        return EvidenceItem(key: key, status: verdict.status, weight: weight, summary: verdict.summary, raw: outcome.description, method: Self.method, durationMs: Self.elapsedMs(since: started), facts: verdict.facts)
    }

    /// What Security.framework answered, reduced to values a test can build.
    public struct ValidationOutcome: Sendable, Hashable {
        public var status: OSStatus
        public var errorDomain: String?
        public var errorCode: Int?
        public var description: String?

        public init(status: OSStatus, errorDomain: String? = nil, errorCode: Int? = nil, description: String? = nil) {
            self.status = status
            self.errorDomain = errorDomain
            self.errorCode = errorCode
            self.description = description
        }
    }

    public struct Classification: Sendable, Hashable {
        public var status: EvidenceStatus
        public var summary: String
        public var facts: [String: String]
    }

    /// Codes Security.framework uses for a revoked signer (cssmerr.h, SecBase.h,
    /// CSCommon.h). `CSSMERR_TP_CERT_REVOKED` is what `codesign` prints for a
    /// pulled Developer ID; the other two are the modern certificate error and
    /// a notarization ticket Apple withdrew, which is a revocation as well.
    static let revokedCodes: Set<Int> = [
        -2_147_409_652, // CSSMERR_TP_CERT_REVOKED
        Int(errSecCertificateRevoked), // -67820
        Int(errSecCSRevokedNotarization), // -66992
    ]

    /// Pure: turns the call's result into evidence. Only a revocation, or a
    /// clean pass, produces the `signature.revoked` fact; any other failure
    /// (offline, a missing responder, a broken seal already reported elsewhere)
    /// means the question stayed open, and the score must not read it as an answer.
    public static func classify(_ outcome: ValidationOutcome) -> Classification {
        if outcome.status == errSecSuccess {
            return Classification(status: .pass, summary: "certificate not revoked", facts: [Fact.signatureRevoked: "false"])
        }
        let codes = [Int(outcome.status), outcome.errorCode].compactMap { $0 }
        let codeSaysRevoked = codes.contains { revokedCodes.contains($0) }
        let textSaysRevoked = outcome.description?.range(of: "revoked", options: .caseInsensitive) != nil
        if codeSaysRevoked || textSaysRevoked {
            return Classification(status: .fail, summary: "Apple revoked the signing certificate", facts: [Fact.signatureRevoked: "true"])
        }
        return Classification(status: .info, summary: "revocation could not be checked", facts: [:])
    }

    static func validate(path: String) -> ValidationOutcome {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            return ValidationOutcome(status: createStatus, description: SecCopyErrorMessageString(createStatus, nil) as String?)
        }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures).union(.enforceRevocationChecks)
        var error: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, nil, &error)
        guard status != errSecSuccess else { return ValidationOutcome(status: status) }
        if let error = error?.takeRetainedValue() {
            return ValidationOutcome(status: status, errorDomain: CFErrorGetDomain(error) as String, errorCode: CFErrorGetCode(error), description: String(describing: error))
        }
        return ValidationOutcome(status: status, description: SecCopyErrorMessageString(status, nil) as String?)
    }

    private static func elapsedMs(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }
}
