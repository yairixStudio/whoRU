import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// SHA-256 of the executable. Hardware-accelerated on Apple platforms, pure
/// Swift elsewhere.
public struct Sha256Check: EvidenceCheck {
    public let key: EvidenceKey = .sha256
    public let weight: EvidenceWeight = .base
    public init() {}

    public func run(on subject: Subject, context: CheckContext) async throws -> EvidenceItem {
        let started = Date()
        let path = Self.executablePath(for: subject)
        let digest = try await Task.detached(priority: .userInitiated) { try Self.digest(ofFileAt: path) }.value
        return EvidenceItem(
            key: key, status: .pass, weight: weight, summary: digest,
            raw: "shasum -a 256 \"\(path)\"\n\(digest)  \(path)", method: "SHA-256 (CryptoKit)",
            durationMs: Int(Date().timeIntervalSince(started) * 1000),
            facts: [Fact.sha256: digest]
        )
    }

    /// The Mach-O the bundle actually runs, not the bundle directory.
    public static func executablePath(for subject: Subject) -> String {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: subject.path, isDirectory: &isDirectory), isDirectory.boolValue,
           let info = BundleInfo.read(bundlePath: subject.path), let exe = info.executable {
            return "\(subject.path)/Contents/MacOS/\(exe)"
        }
        return subject.path
    }

    public static func digest(ofFileAt path: String) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw CommandError("cannot open \(path)") }
        defer { try? handle.close() }
        #if canImport(CryptoKit)
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        var hasher = PortableSHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(chunk)
        }
        return hasher.finalizeHex()
        #endif
    }
}

/// Compares the file's hash with the publisher's own release manifest. The
/// strongest evidence there is: byte-for-byte what the publisher shipped.
public struct OfficialManifestCheck: EvidenceCheck {
    public let key: EvidenceKey = .officialManifest
    public let weight: EvidenceWeight = .decisive
    public init() {}

    public func run(on subject: Subject, context: CheckContext) async throws -> EvidenceItem {
        if context.settings.localOnly { return .skipped(key, weight: weight, reason: "local-only mode") }
        let identifiers = [subject.bundleID, subject.displayName, (subject.path as NSString).lastPathComponent].compactMap { $0 }
        guard let (publisher, source) = identifiers.lazy.compactMap({ context.publishers.manifestSource(forIdentifier: $0) }).first else {
            return .skipped(key, weight: weight, reason: "no official manifest source for this program")
        }
        guard let version = subject.version ?? Self.versionFromPath(subject.path) else {
            return .skipped(key, weight: weight, reason: "version unknown, cannot look up the manifest")
        }
        let started = Date()
        let path = Sha256Check.executablePath(for: subject)
        let digest = try await Task.detached { try Sha256Check.digest(ofFileAt: path) }.value
        let urlString = source.urlTemplate.replacingOccurrences(of: "{version}", with: version)
        guard let url = URL(string: urlString) else { return .error(key, weight: weight, "bad manifest URL") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            return EvidenceItem(key: key, status: .info, weight: weight, summary: "no manifest published for version \(version) (HTTP \(status))",
                                raw: urlString, method: "GET \(url.host ?? "")", durationMs: Int(Date().timeIntervalSince(started) * 1000))
        }
        let json = try JSONValue.parse(data)
        let expected: String?
        switch source.format {
        case "claudeCode": expected = json["platforms"]?[source.platformKey]?["checksum"]?.stringValue
        default: expected = json["sha256"]?.stringValue
        }
        guard let expected else { return .error(key, weight: weight, "manifest has no checksum for \(source.platformKey)") }
        let matches = expected.lowercased() == digest.lowercased()
        return EvidenceItem(
            key: key, status: matches ? .pass : .fail, weight: weight,
            summary: matches ? "matches \(url.host ?? "") manifest for \(version) (\(source.platformKey))" : "DOES NOT match the official \(version) release",
            raw: String(decoding: data.prefix(2000), as: UTF8.self), method: "GET \(urlString)",
            durationMs: Int(Date().timeIntervalSince(started) * 1000),
            facts: [Fact.manifestMatch: matches ? "true" : "false", Fact.manifestSource: url.host ?? "", Fact.publisherName: publisher.name]
        )
    }

    /// Bare binaries named after their version, like Claude Code's `2.1.258`.
    static func versionFromPath(_ path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        let parts = name.split(separator: ".")
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        return name
    }
}

public struct VirusTotalReport: Sendable {
    public var found: Bool
    public var malicious: Int
    public var suspicious: Int
    public var harmless: Int
    public var undetected: Int
    public var summary: String
}

public enum VirusTotal {
    public static func lookup(sha256: String, apiKey: String) async throws -> VirusTotalReport {
        var request = URLRequest(url: URL(string: "https://www.virustotal.com/api/v3/files/\(sha256)")!)
        request.setValue(apiKey, forHTTPHeaderField: "x-apikey")
        request.timeoutInterval = 6
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 {
            return VirusTotalReport(found: false, malicious: 0, suspicious: 0, harmless: 0, undetected: 0, summary: "hash not known to VirusTotal")
        }
        guard status == 200 else { throw AnalystError.http(status: status, body: String(decoding: data, as: UTF8.self)) }
        let json = try JSONValue.parse(data)
        let stats = json["data"]?["attributes"]?["last_analysis_stats"]
        let malicious = stats?["malicious"]?.intValue ?? 0
        let suspicious = stats?["suspicious"]?.intValue ?? 0
        let harmless = stats?["harmless"]?.intValue ?? 0
        let undetected = stats?["undetected"]?.intValue ?? 0
        let summary = malicious == 0 ? "known to VirusTotal, no engine flags it" : "\(malicious) of \(malicious + suspicious + harmless + undetected) engines flag it"
        return VirusTotalReport(found: true, malicious: malicious, suspicious: suspicious, harmless: harmless, undetected: undetected, summary: summary)
    }
}

/// Optional, slow, off by default. Sends the hash and nothing else.
public struct VirusTotalCheck: EvidenceCheck {
    public let key: EvidenceKey = .virusTotal
    public let weight: EvidenceWeight = .high
    public let isSlow = true
    public init() {}

    public func run(on subject: Subject, context: CheckContext) async throws -> EvidenceItem {
        guard context.settings.virusTotalEnabled, !context.settings.localOnly else { return .skipped(key, weight: weight, reason: "VirusTotal is off") }
        guard let apiKey = context.secrets.secret(.virusTotalAPIKey) else { return .skipped(key, weight: weight, reason: "no VirusTotal API key") }
        let started = Date()
        let path = Sha256Check.executablePath(for: subject)
        let digest = try await Task.detached { try Sha256Check.digest(ofFileAt: path) }.value
        let report = try await VirusTotal.lookup(sha256: digest, apiKey: apiKey)
        let status: EvidenceStatus = !report.found ? .info : (report.malicious >= 3 ? .fail : (report.malicious > 0 ? .warn : .pass))
        return EvidenceItem(key: key, status: status, weight: weight, summary: report.summary, method: "GET virustotal.com/api/v3/files/<sha256>",
                            durationMs: Int(Date().timeIntervalSince(started) * 1000),
                            facts: [Fact.virusTotalDetections: String(report.malicious)])
    }
}
