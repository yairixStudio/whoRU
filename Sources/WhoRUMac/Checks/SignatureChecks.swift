import Foundation
import WhoRUCore

/// Who signed the file. Decided by Security.framework; `codesign -dvvv` output
/// is attached for “How did you check?”.
public struct SignerIdentityCheck: EvidenceCheck {
    public let key: EvidenceKey = .signerIdentity
    public let weight: EvidenceWeight = .critical
    public init() {}

    public func run(on subject: Subject, context: CheckContext) async throws -> EvidenceItem {
        let started = Date()
        let path = subject.verificationPath
        async let display = Command.run("/usr/bin/codesign", ["-dvvv", path], timeout: .seconds(4))
        let info = await CodeSignature.inspect(path: path)
        let raw = (try? await display)?.combined
        var facts: [String: String] = [Fact.signerKind: info.kind.rawValue]
        if let team = info.teamID { facts[Fact.signerTeamID] = team }
        if let name = info.publisherName { facts[Fact.signerName] = name }
        if let id = info.identifier { facts[Fact.bundleID] = id }
        facts[Fact.hardenedRuntime] = info.hardenedRuntime ? "true" : "false"

        let summary: String
        let status: EvidenceStatus
        switch info.kind {
        case .apple:
            summary = "Apple (system software)"
            status = .pass
        case .appStore:
            summary = "App Store: \(info.publisherName ?? "unknown")"
            status = .pass
        case .developerID:
            summary = "Developer ID: \(info.publisherName ?? "?") (\(info.teamID ?? "no Team ID"))"
            status = .pass
        case .adhoc:
            summary = "ad-hoc signature: identifies no publisher"
            status = .warn
        case .unsigned:
            summary = "not signed"
            status = .warn
        case .unknown:
            summary = info.validationError.map { "signature could not be read: \($0)" } ?? "signature could not be read"
            status = .error
        }
        return EvidenceItem(key: key, status: status, weight: weight, summary: summary, raw: raw, method: "SecCodeCopySigningInformation",
                            durationMs: Int(Date().timeIntervalSince(started) * 1000), facts: facts)
    }
}

/// Whether the file still matches its signature. A failure here is hard red.
public struct SignatureIntegrityCheck: EvidenceCheck {
    public let key: EvidenceKey = .signatureIntegrity
    public let weight: EvidenceWeight = .critical
    public init() {}

    public func run(on subject: Subject, context: CheckContext) async throws -> EvidenceItem {
        let started = Date()
        let path = subject.verificationPath
        let info = await CodeSignature.inspect(path: path)
        let durationMs = Int(Date().timeIntervalSince(started) * 1000)
        switch info.kind {
        case .unsigned:
            return EvidenceItem(key: key, status: .skipped, weight: weight, summary: "nothing to verify: not signed", method: "SecStaticCodeCheckValidity", durationMs: durationMs)
        case .unknown where !info.valid:
            return EvidenceItem(key: key, status: .error, weight: weight, summary: info.validationError ?? "could not verify", method: "SecStaticCodeCheckValidity", durationMs: durationMs)
        default:
            if info.valid {
                return EvidenceItem(key: key, status: .pass, weight: weight, summary: "valid on disk, satisfies its designated requirement",
                                    raw: "codesign --verify --strict --deep \"\(path)\"\n(valid)", method: "SecStaticCodeCheckValidity (strict)",
                                    durationMs: durationMs, facts: [Fact.signatureValid: "true"])
            }
            return EvidenceItem(key: key, status: .fail, weight: weight, summary: "signature is BROKEN: \(info.validationError ?? "modified after signing")",
                                raw: info.validationError, method: "SecStaticCodeCheckValidity (strict)",
                                durationMs: durationMs, facts: [Fact.signatureValid: "false"])
        }
    }
}

/// Would Gatekeeper let it run, and was it notarized. Bare binaries are
/// rejected because they are not apps; that outcome is neutral.
public struct GatekeeperCheck: EvidenceCheck {
    public let key: EvidenceKey = .gatekeeper
    public let weight: EvidenceWeight = .high
    public init() {}

    public func run(on subject: Subject, context: CheckContext) async throws -> EvidenceItem {
        let path = subject.verificationPath
        let output = try await Command.run("/usr/sbin/spctl", ["--assess", "--type", "execute", "-vv", path], timeout: .seconds(6))
        let text = output.combined
        var facts: [String: String] = [:]
        let notarized = text.contains("Notarized Developer ID")
        if notarized { facts[Fact.notarized] = "true" }

        if text.contains("accepted") {
            let source = text.split(separator: "\n").first { $0.hasPrefix("source=") }.map { String($0.dropFirst(7)) } ?? "accepted"
            if !notarized { facts[Fact.notarized] = source.contains("Apple") ? "true" : "unknown" }
            return EvidenceItem(key: key, status: .pass, weight: weight, summary: "Gatekeeper accepts it (\(source))", raw: text, method: "spctl --assess --type execute", durationMs: output.durationMs, facts: facts)
        }
        if text.contains("does not seem to be an app") {
            facts[Fact.notarized] = "unknown"
            return EvidenceItem(key: key, status: .neutral, weight: weight, summary: "not an app bundle; Gatekeeper does not assess bare executables", raw: text, method: "spctl --assess --type execute", durationMs: output.durationMs, facts: facts)
        }
        facts[Fact.notarized] = notarized ? "true" : "false"
        let reason = text.split(separator: "\n").first { $0.contains("rejected") || $0.hasPrefix("source=") }.map(String.init) ?? "rejected"
        return EvidenceItem(key: key, status: .warn, weight: weight, summary: "Gatekeeper would reject it: \(reason)", raw: text, method: "spctl --assess --type execute", durationMs: output.durationMs, facts: facts)
    }
}

/// Sandbox, hardened runtime and notable capabilities from the signature.
public struct EntitlementsCheck: EvidenceCheck {
    public let key: EvidenceKey = .entitlements
    public let weight: EvidenceWeight = .medium
    public init() {}

    static let notable: [String: String] = [
        "com.apple.security.app-sandbox": "sandboxed",
        "com.apple.security.cs.allow-jit": "JIT",
        "com.apple.security.cs.disable-library-validation": "loads unsigned libraries",
        "com.apple.security.cs.allow-unsigned-executable-memory": "unsigned executable memory",
        "com.apple.security.cs.allow-dyld-environment-variables": "dyld environment variables",
        "com.apple.security.cs.debugger": "debugger",
        "com.apple.security.device.camera": "camera",
        "com.apple.security.device.audio-input": "microphone",
        "com.apple.security.automation.apple-events": "Apple Events automation",
        "com.apple.security.network.client": "network client",
        "com.apple.security.network.server": "network server",
        "com.apple.security.files.user-selected.read-write": "user-selected files",
        "com.apple.security.get-task-allow": "debuggable (get-task-allow)",
    ]

    public func run(on subject: Subject, context: CheckContext) async throws -> EvidenceItem {
        let started = Date()
        let info = await CodeSignature.inspect(path: subject.verificationPath)
        guard info.kind != .unsigned else { return .skipped(key, weight: weight, reason: "not signed, no entitlements") }
        var facts: [String: String] = [
            Fact.hardenedRuntime: info.hardenedRuntime ? "true" : "false",
            Fact.sandboxed: (info.entitlements["com.apple.security.app-sandbox"]?.boolValue ?? false) ? "true" : "false",
        ]
        var labels: [String] = []
        if info.hardenedRuntime { labels.append("hardened runtime") }
        for (key, label) in Self.notable.sorted(by: { $0.key < $1.key }) {
            if let v = info.entitlements[key], v.boolValue == true { labels.append(label) }
        }
        let risky = ["com.apple.security.cs.disable-library-validation", "com.apple.security.cs.allow-dyld-environment-variables", "com.apple.security.get-task-allow"]
            .filter { info.entitlements[$0]?.boolValue == true }
        facts["entitlements.risky"] = risky.isEmpty ? "false" : "true"
        let raw = info.entitlements.isEmpty ? "(no entitlements)" : JSONValue.object(info.entitlements).string(pretty: true)
        let summary = labels.isEmpty ? "no notable entitlements" + (info.hardenedRuntime ? "" : ", no hardened runtime") : labels.joined(separator: ", ")
        return EvidenceItem(key: key, status: risky.isEmpty ? .info : .warn, weight: weight, summary: summary, raw: raw, method: "kSecCodeInfoEntitlementsDict",
                            durationMs: Int(Date().timeIntervalSince(started) * 1000), facts: facts)
    }
}
