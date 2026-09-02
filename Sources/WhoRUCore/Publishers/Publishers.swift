import Foundation

public enum PublisherTrust: String, Codable, Sendable, Hashable {
    case normal, trusted, blocked
}

public enum PublisherSource: String, Codable, Sendable, Hashable {
    case builtin, user, learned
}

/// Where a publisher publishes checksums of its releases, so that a file can
/// be compared byte-for-byte with what the publisher shipped.
public struct ManifestSource: Codable, Sendable, Hashable {
    /// `{version}` is replaced with the subject's version string.
    public var urlTemplate: String
    /// Bundle identifiers (or executable names) this manifest covers.
    public var identifiers: [String]
    /// Format of the manifest document. `claudeCode`: `platforms.<key>.checksum`.
    public var format: String
    /// Key to pick inside the manifest, e.g. `darwin-arm64`.
    public var platformKey: String

    public init(urlTemplate: String, identifiers: [String], format: String, platformKey: String) {
        self.urlTemplate = urlTemplate
        self.identifiers = identifiers
        self.format = format
        self.platformKey = platformKey
    }
}

public struct Publisher: Codable, Sendable, Hashable, Identifiable {
    public static let appleTeamID = "APPLE"

    public var teamID: String
    public var name: String
    public var source: PublisherSource
    public var trust: PublisherTrust
    /// Product names this publisher is known for, used to detect impersonation.
    public var knownNames: [String]
    public var manifest: ManifestSource?

    public var id: String { teamID }

    public init(teamID: String, name: String, source: PublisherSource = .builtin, trust: PublisherTrust = .normal, knownNames: [String] = [], manifest: ManifestSource? = nil) {
        self.teamID = teamID
        self.name = name
        self.source = source
        self.trust = trust
        self.knownNames = knownNames
        self.manifest = manifest
    }
}

/// The built-in list merged with the user's additions and trust decisions.
public struct PublisherDirectory: Sendable {
    private var byTeamID: [String: Publisher]
    private var byProductName: [String: String]

    public init(builtin: [Publisher] = BuiltinPublishers.all, overrides: [Publisher] = []) {
        var map: [String: Publisher] = [:]
        for p in builtin { map[p.teamID] = p }
        for p in overrides {
            if var existing = map[p.teamID] {
                existing.trust = p.trust
                existing.source = p.source
                if !p.knownNames.isEmpty { existing.knownNames = p.knownNames }
                if p.manifest != nil { existing.manifest = p.manifest }
                if p.name != existing.name, p.source == .user { existing.name = p.name }
                map[p.teamID] = existing
            } else {
                map[p.teamID] = p
            }
        }
        byTeamID = map
        var names: [String: String] = [:]
        for p in map.values {
            for n in p.knownNames { names[n.lowercased()] = p.teamID }
        }
        byProductName = names
    }

    public var all: [Publisher] { byTeamID.values.sorted { $0.name < $1.name } }

    public func lookup(teamID: String) -> Publisher? { byTeamID[teamID] }

    /// The publisher whose product carries this exact name, if any.
    public func expectedPublisher(forProductName name: String) -> Publisher? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard let teamID = byProductName[key] else { return nil }
        return byTeamID[teamID]
    }

    /// Manifest sources that claim to cover this identifier.
    public func manifestSource(forIdentifier identifier: String) -> (Publisher, ManifestSource)? {
        for p in byTeamID.values {
            if let m = p.manifest, m.identifiers.contains(identifier) { return (p, m) }
        }
        return nil
    }
}
