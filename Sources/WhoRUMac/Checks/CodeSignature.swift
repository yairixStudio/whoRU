import Foundation
import Security
import WhoRUCore

/// What Security.framework says about a file's signature. Read once per scan
/// and shared by the identity, integrity and entitlements checks.
public struct SignatureInfo: Sendable {
    public var kind: SignerKind
    public var valid: Bool
    public var validationError: String?
    public var teamID: String?
    /// Subject summary of the leaf certificate, e.g. "Developer ID Application: Anthropic PBC (Q6L2SF6YDW)".
    public var leafSummary: String?
    public var chain: [String]
    public var identifier: String?
    public var isPlatformBinary: Bool
    public var hardenedRuntime: Bool
    public var signingTime: Date?
    public var entitlements: [String: JSONValue]

    /// Publisher name parsed out of the leaf summary.
    public var publisherName: String? {
        guard let leaf = leafSummary else { return nil }
        if let colon = leaf.firstIndex(of: ":") {
            var name = String(leaf[leaf.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if let paren = name.lastIndex(of: "("), name.hasSuffix(")") {
                name = String(name[..<paren]).trimmingCharacters(in: .whitespaces)
            }
            return name
        }
        return leaf
    }
}

public enum CodeSignature {
    private static let cache = SignatureCache()

    public static func inspect(path: String) async -> SignatureInfo {
        await cache.inspect(path)
    }

    static func inspectNow(path: String) -> SignatureInfo {
        var info = SignatureInfo(kind: .unknown, valid: false, chain: [], isPlatformBinary: false, hardenedRuntime: false, entitlements: [:])
        var staticCode: SecStaticCode?
        let url = URL(fileURLWithPath: path) as CFURL
        let createStatus = SecStaticCodeCreateWithPath(url, [], &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            info.validationError = SecCopyErrorMessageString(createStatus, nil) as String? ?? "cannot read code object"
            return info
        }

        // Strict, all architectures. Nested code is deliberately not re-verified:
        // it multiplies the cost on large bundles and the outer seal already covers it.
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        var validationError: Unmanaged<CFError>?
        let validity = SecStaticCodeCheckValidityWithErrors(code, flags, nil, &validationError)
        if validity == errSecSuccess {
            info.valid = true
        } else if validity == errSecCSUnsigned {
            info.kind = .unsigned
            info.valid = false
            info.validationError = "unsigned"
            return info
        } else {
            info.valid = false
            info.validationError = (validationError?.takeRetainedValue()).map { String(describing: $0) }
                ?? (SecCopyErrorMessageString(validity, nil) as String?) ?? "invalid signature"
        }

        // Signing information.
        var signingInfo: CFDictionary?
        let infoFlags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(code, infoFlags, &signingInfo) == errSecSuccess, let dict = signingInfo as? [String: Any] else {
            info.kind = info.valid ? .unknown : info.kind
            return info
        }
        info.identifier = dict[kSecCodeInfoIdentifier as String] as? String
        info.teamID = dict[kSecCodeInfoTeamIdentifier as String] as? String
        let signatureFlags = (dict[kSecCodeInfoFlags as String] as? UInt32) ?? 0
        // SecCodeSignatureFlags: kSecCodeSignatureAdhoc = 0x2, kSecCodeSignatureRuntime = 0x10000 (CSCommon.h)
        let adhoc = signatureFlags & 0x0002 != 0
        info.hardenedRuntime = signatureFlags & 0x10000 != 0
        info.isPlatformBinary = ((dict[kSecCodeInfoPlatformIdentifier as String] as? Int) ?? 0) != 0
        info.signingTime = dict[kSecCodeInfoTime as String] as? Date
        if let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate] {
            info.chain = certs.map { (SecCertificateCopySubjectSummary($0) as String?) ?? "?" }
            info.leafSummary = info.chain.first
        }
        if let ent = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any] {
            info.entitlements = ent.compactMapValues { Self.jsonValue($0) }
        }

        // Classification.
        if info.isPlatformBinary || info.leafSummary == "Software Signing" {
            info.kind = .apple
        } else if let leaf = info.leafSummary, leaf.contains("Mac OS Application Signing") || leaf.contains("Apple Mac OS Application Signing") {
            info.kind = .appStore
        } else if let leaf = info.leafSummary, leaf.hasPrefix("Developer ID Application") {
            info.kind = .developerID
        } else if adhoc || info.chain.isEmpty {
            info.kind = .adhoc
        } else if let leaf = info.leafSummary, leaf.hasPrefix("Apple Development") || leaf.hasPrefix("Mac Developer") {
            info.kind = .developerID // development certificate; treated like Developer ID but not notarizable
        } else {
            info.kind = .unknown
        }
        return info
    }

    private static func jsonValue(_ any: Any) -> JSONValue? {
        switch any {
        case let b as Bool: return .bool(b)
        case let n as NSNumber: return .number(n.doubleValue)
        case let s as String: return .string(s)
        case let a as [Any]: return .array(a.compactMap(jsonValue))
        case let d as [String: Any]: return .object(d.compactMapValues(jsonValue))
        default: return nil
        }
    }
}

/// Caches results per path and modification time, and coalesces concurrent
/// requests for the same path so three checks cost one inspection.
actor SignatureCache {
    private var entries: [String: (Date, SignatureInfo)] = [:]
    private var inFlight: [String: Task<SignatureInfo, Never>] = [:]

    func inspect(_ path: String) async -> SignatureInfo {
        if let (mtime, info) = entries[path], Self.modificationDate(path) == mtime { return info }
        if let task = inFlight[path] { return await task.value }
        let task = Task.detached(priority: .userInitiated) { CodeSignature.inspectNow(path: path) }
        inFlight[path] = task
        let info = await task.value
        inFlight[path] = nil
        entries[path] = (Self.modificationDate(path), info)
        if entries.count > 64 { entries.removeAll() }
        return info
    }

    static func modificationDate(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
    }
}
