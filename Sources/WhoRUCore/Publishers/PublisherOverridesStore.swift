import Foundation

/// `publishers.json` in Application Support: the user's trust decisions and
/// additions over the built-in list. A "trusted" entry turns a publisher green
/// and skips the model, so the file is signed with `FileIntegrity`; an entry
/// added by another process does not carry a valid signature and the whole
/// file is then ignored rather than partly honoured.
///
/// Tamper evidence only: the file is plain JSON, and a file with no signature
/// yet (written before signing existed) is trusted once and signed on save.
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
        return (try JSONDecoder().decode([Publisher].self, from: data), state)
    }

    public func save(_ publishers: [Publisher]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try integrity.write(try encoder.encode(publishers), to: url)
    }
}
