import Foundation

/// `publishers.json` in Application Support: the user's trust decisions and
/// additions over the built-in list. A "trusted" entry turns a publisher green
/// and skips the model, so the file is signed with `FileIntegrity`; an entry
/// added by another process does not carry a valid signature and the whole
/// file is then ignored rather than partly honoured.
///
/// The trust list is the one file whose content changes a verdict, so it is
/// held to a stricter rule than settings: once whoRU can sign (a key exists),
/// a file with no signature is treated like a tampered one and its trust
/// decisions are ignored, because an attacker can delete a sidecar as easily
/// as edit the file. Trust-on-first-use would reopen exactly the hole the
/// signature closes. A missing signature is honoured only when there is no key
/// to verify with at all (an older install, or the command line without one).
public struct PublisherOverridesStore: Sendable {
    public let url: URL
    public let integrity: FileIntegrity

    public init(paths: Paths, integrity: FileIntegrity = .unverifiable) {
        self.init(url: paths.applicationSupport.appendingPathComponent("publishers.json"), integrity: integrity)
    }

    public init(url: URL, integrity: FileIntegrity) {
        self.url = url
        self.integrity = integrity
    }

    /// The overrides and what the signature said. Tampered: an empty list, so
    /// no trust decision from the file is honoured. Throws only when the file
    /// exists and cannot be read or decoded.
    public func load() throws -> (publishers: [Publisher], state: IntegrityState) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ([], integrity.canVerify ? .verified : .unverifiable)
        }
        let (data, state) = try integrity.read(url)
        if state == .tampered { return ([], state) }
        // A key exists but the file is unsigned: an attacker who deleted the
        // sidecar looks the same as an upgrade from a pre-signing version, and
        // for the trust list the safe reading is to honour nothing.
        if state == .missingSignature, integrity.canVerify { return ([], .tampered) }
        return (try JSONDecoder().decode([Publisher].self, from: data), state)
    }

    public func save(_ publishers: [Publisher]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try integrity.write(try encoder.encode(publishers), to: url)
    }
}
