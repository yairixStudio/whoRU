import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// What a signed read found next to the file.
public enum IntegrityState: String, Sendable, Hashable {
    /// The sidecar matches the bytes on disk.
    case verified
    /// No sidecar. Files written by a version before signing existed look like
    /// this once; they are trusted and signed on the next save.
    case missingSignature
    /// A sidecar exists and does not match: the file (or the sidecar) was
    /// changed by something that does not hold the key.
    case tampered
    /// No key was available, so nothing could be checked.
    case unverifiable
}

/// Tamper evidence for the JSON files in Application Support, which any
/// process running as the user can edit. Each file gets a sidecar
/// `<file>.sig` holding an HMAC-SHA256 of its bytes, keyed with a secret kept
/// in the Keychain. A process without the key can still read and rewrite the
/// file, but it cannot produce a matching sidecar, so the change is noticed.
///
/// This is evidence, not confidentiality: the files stay plain JSON. It is also
/// trust on first use: a file with no sidecar is accepted and signed, so the
/// first launch of a version that adds signing trusts the existing files once.
public struct FileIntegrity: Sendable {
    /// The HMAC key, or `nil` when the platform or the Keychain gave none.
    public let key: Data?

    public init(key: Data?) {
        self.key = key
    }

    /// Reads and writes without a sidecar. For the command line and tests.
    public static let unverifiable = FileIntegrity(key: nil)

    /// Whether a read can say anything beyond `.unverifiable`.
    public var canVerify: Bool { key != nil && Self.hasHMAC }

    public static func sidecarURL(for url: URL) -> URL {
        url.appendingPathExtension("sig")
    }

    /// Writes the file and its sidecar, each atomically. Without a key any
    /// stale sidecar is removed, so a keyed reader later sees "no signature"
    /// rather than a mismatch it would have to treat as tampering.
    public func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        let sidecar = Self.sidecarURL(for: url)
        if let hex = signature(of: data) {
            try Data(hex.utf8).write(to: sidecar, options: .atomic)
        } else if FileManager.default.fileExists(atPath: sidecar.path) {
            try FileManager.default.removeItem(at: sidecar)
        }
    }

    /// Reads the file and reports whether its sidecar vouches for it. Throws
    /// only when the file itself cannot be read; the caller decides what a
    /// tampered file means for it.
    public func read(_ url: URL) throws -> (data: Data, state: IntegrityState) {
        let data = try Data(contentsOf: url)
        guard let expected = signature(of: data) else { return (data, .unverifiable) }
        guard let stored = try? Data(contentsOf: Self.sidecarURL(for: url)) else { return (data, .missingSignature) }
        let storedHex = String(decoding: stored, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let storedBytes = Self.bytes(fromHex: storedHex), let expectedBytes = Self.bytes(fromHex: expected) else {
            return (data, .tampered)
        }
        return (data, Self.constantTimeEqual(storedBytes, expectedBytes) ? .verified : .tampered)
    }

    /// Lowercase hex HMAC-SHA256 of `data`, or `nil` when there is no key or
    /// no HMAC implementation on this platform.
    public func signature(of data: Data) -> String? {
        guard let key, !key.isEmpty else { return nil }
        #if canImport(CryptoKit)
        let code = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return code.map { Self.hexDigits[Int($0 >> 4)] + Self.hexDigits[Int($0 & 0x0f)] }.joined()
        #else
        return nil
        #endif
    }

    private static var hasHMAC: Bool {
        #if canImport(CryptoKit)
        true
        #else
        false
        #endif
    }

    private static let hexDigits = "0123456789abcdef".map { String($0) }

    private static func bytes(fromHex hex: String) -> [UInt8]? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0, !chars.isEmpty else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    /// Compares every byte regardless of where the first difference is, so
    /// the time taken says nothing about how much of a forged tag was right.
    private static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in a.indices { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}

/// The key that signs the store files, kept as a base64 secret.
public enum IntegrityKey {
    public static let length = 32

    /// The stored key, or a fresh one when `createIfMissing` and the store
    /// accepts writes. Returns `nil` when there is no key and none could be
    /// stored (a read-only environment store), and when the stored value is
    /// not base64: silently replacing a key would turn every signed file into
    /// a tampered one, so an unreadable key means "cannot verify" instead.
    public static func load(from secrets: any SecretStore, createIfMissing: Bool) -> Data? {
        if let stored = secrets.secret(.storeIntegrityKey) {
            guard let data = Data(base64Encoded: stored), !data.isEmpty else { return nil }
            return data
        }
        guard createIfMissing else { return nil }
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<length).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        let key = Data(bytes)
        do {
            try secrets.setSecret(key.base64EncodedString(), for: .storeIntegrityKey)
        } catch {
            return nil
        }
        return key
    }
}
