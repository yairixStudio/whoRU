import Foundation

/// Stable identifier of an evidence check, e.g. `codesign.identity`.
///
/// The model refers to evidence by this key in its `reasons`, so keys are part
/// of the contract and must not change once published.
public struct EvidenceKey: RawRepresentable, Codable, Sendable, Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public static let signerIdentity: EvidenceKey = "codesign.identity"
    public static let signatureIntegrity: EvidenceKey = "codesign.verify"
    public static let gatekeeper: EvidenceKey = "spctl"
    public static let sha256: EvidenceKey = "sha256"
    public static let officialManifest: EvidenceKey = "official_manifest"
    public static let downloadOrigin: EvidenceKey = "quarantine"
    public static let location: EvidenceKey = "location"
    public static let parentChain: EvidenceKey = "parent_chain"
    public static let persistence: EvidenceKey = "persistence"
    public static let declarations: EvidenceKey = "info_plist"
    public static let entitlements: EvidenceKey = "entitlements"
    public static let timestamps: EvidenceKey = "timestamps"
    public static let networkConnections: EvidenceKey = "network"
    public static let virusTotal: EvidenceKey = "virustotal"
    public static let history: EvidenceKey = "history"
    public static let impersonation: EvidenceKey = "impersonation"
    public static let publisher: EvidenceKey = "publisher"
}

public enum EvidenceStatus: String, Codable, Sendable, Hashable {
    /// The check found what a legitimate program would show.
    case pass
    /// Something worth attention but not damning on its own.
    case warn
    /// A hard negative finding.
    case fail
    /// Purely informational.
    case info
    /// The check ran but its result carries no weight in this context
    /// (for example Gatekeeper rejecting a bare binary because it is not an app).
    case neutral
    /// The check was not applicable or was disabled.
    case skipped
    /// The check could not complete.
    case error
}

public enum EvidenceWeight: String, Codable, Sendable, Hashable {
    case decisive, critical, high, medium, low, base
}

/// One row of evidence. `summary` is what the user sees; `raw` is what
/// “How did you check?” shows; `facts` is the normalized, platform-neutral
/// data the hard-score engine reads.
public struct EvidenceItem: Codable, Sendable, Hashable, Identifiable {
    public var key: EvidenceKey
    public var status: EvidenceStatus
    public var weight: EvidenceWeight
    public var summary: String
    public var raw: String?
    /// The command or API that produced the result, for display.
    public var method: String?
    public var durationMs: Int
    public var facts: [String: String]

    public var id: EvidenceKey { key }

    public init(
        key: EvidenceKey,
        status: EvidenceStatus,
        weight: EvidenceWeight,
        summary: String,
        raw: String? = nil,
        method: String? = nil,
        durationMs: Int = 0,
        facts: [String: String] = [:]
    ) {
        self.key = key
        self.status = status
        self.weight = weight
        self.summary = summary
        self.raw = raw
        self.method = method
        self.durationMs = durationMs
        self.facts = facts
    }

    public static func skipped(_ key: EvidenceKey, weight: EvidenceWeight, reason: String) -> EvidenceItem {
        EvidenceItem(key: key, status: .skipped, weight: weight, summary: reason)
    }

    public static func error(_ key: EvidenceKey, weight: EvidenceWeight, _ message: String, durationMs: Int = 0) -> EvidenceItem {
        EvidenceItem(key: key, status: .error, weight: weight, summary: message, durationMs: durationMs)
    }
}

/// Keys of the normalized facts that checks may emit. Platform-neutral on
/// purpose: a Windows port fills `signer.kind` from Authenticode, not from
/// `SecStaticCode`, and the scoring engine does not care.
public enum Fact {
    /// `developerID` | `appStore` | `apple` | `adhoc` | `unsigned` | `unknown`
    public static let signerKind = "signer.kind"
    public static let signerTeamID = "signer.teamID"
    public static let signerName = "signer.name"
    /// `true` | `false`
    public static let signatureValid = "signature.valid"
    /// `true` | `false` | `unknown`
    public static let notarized = "notarized"
    /// `true` | `false`
    public static let manifestMatch = "manifest.match"
    public static let manifestSource = "manifest.source"
    /// `true` when the name matches a known publisher but the identity does not
    public static let impersonation = "impersonation"
    public static let impersonatedName = "impersonation.name"
    /// Integer count
    public static let virusTotalDetections = "virustotal.detections"
    /// `known` | `unknown` | `none` (no quarantine information)
    public static let downloadSource = "download.source"
    public static let downloadURL = "download.url"
    /// `standard` | `suspicious` | `unknown`
    public static let locationClass = "location.class"
    public static let resolverConfidence = "resolver.confidence"
    /// `normal` | `trusted` | `blocked`
    public static let publisherTrust = "publisher.trust"
    public static let publisherName = "publisher.name"
    /// `true` when the program is registered to launch automatically
    public static let persistent = "persistence.present"
    public static let sha256 = "sha256"
    public static let bundleID = "bundle.id"
    public static let version = "bundle.version"
    /// ISO-8601
    public static let createdAt = "file.createdAt"
    public static let sandboxed = "entitlements.sandbox"
    public static let hardenedRuntime = "entitlements.hardenedRuntime"
}

public enum SignerKind: String, Codable, Sendable {
    case developerID, appStore, apple, adhoc, unsigned, unknown
}
