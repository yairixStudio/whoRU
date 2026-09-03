import Darwin
import Foundation
import Security
import WhoRUCore

/// What Security.framework says about the code running as one process,
/// compared with the file on disk the evidence was collected from.
public struct RunningCodeInfo: Sendable, Hashable {
    /// The running code passes dynamic validation.
    public var valid: Bool
    /// Where the running code lives, as the kernel sees it.
    public var path: String?
    /// Code directory hash of the running code, hex.
    public var cdhash: String?
    /// Code directory hash of the file on disk, hex (the architecture the
    /// process runs when the file is universal).
    public var diskCdhash: String?
    /// Both hashes known and equal; `nil` when one side could not be hashed.
    public var matchesDisk: Bool?
    public var error: String?

    public init(valid: Bool, path: String? = nil, cdhash: String? = nil, diskCdhash: String? = nil, matchesDisk: Bool? = nil, error: String? = nil) {
        self.valid = valid
        self.path = path
        self.cdhash = cdhash
        self.diskCdhash = diskCdhash
        self.matchesDisk = matchesDisk
        self.error = error
    }

    /// The portable form the core turns into facts.
    public var facts: RunningCodeFacts {
        RunningCodeFacts(valid: valid, matchesDisk: matchesDisk, cdhash: cdhash, diskCdhash: diskCdhash, path: path, error: error)
    }
}

/// Checks that the process the system attributed a request to is the file
/// that was examined on disk, and that it is still intact in memory. The
/// evidence checks read a file; this reads the process. A swapped binary,
/// a tampered process or a file replaced after launch shows up here.
public enum RunningCode {
    /// Blocking: call off the main actor.
    public static func validate(pid: pid_t, diskPath: String) -> RunningCodeInfo {
        var info = RunningCodeInfo(valid: false)

        // The file on disk first: an unsigned file has nothing to compare
        // with, and the caller must not turn that into a finding.
        let disk = diskHashes(path: diskPath)
        if disk.unsigned {
            info.error = "unsigned"
            return info
        }
        info.diskCdhash = disk.hashes.first

        guard let code = ProcessTrust.runningCode(pid: pid) else {
            info.error = "process \(pid) has no code object (gone?)"
            return info
        }
        let validity = SecCodeCheckValidity(code, [], nil)
        info.valid = validity == errSecSuccess
        if validity != errSecSuccess {
            info.error = (SecCopyErrorMessageString(validity, nil) as String?) ?? "OSStatus \(validity)"
        }
        // The static view of the running code: where it lives and its hash.
        var staticCode: SecStaticCode?
        if SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode {
            var url: CFURL?
            if SecCodeCopyPath(staticCode, [], &url) == errSecSuccess, let url = url as URL? {
                info.path = url.path
            }
            info.cdhash = uniqueHash(of: staticCode)
        }
        // The pid may have been reused between the attribution and this check,
        // or the process may be a different program that happens to share the
        // pid. If what is running is not the file we examined, this is not our
        // subject and we say nothing: comparing hashes would raise a false red.
        if let runningPath = info.path, !Self.isSameFile(runningPath, diskPath) {
            info.matchesDisk = nil
            info.error = "process \(pid) is now \(runningPath), not the program that was scanned"
            return info
        }
        if let running = info.cdhash, !disk.hashes.isEmpty {
            // A universal file has one hash per slice; the process runs one of them.
            info.matchesDisk = disk.hashes.contains(running)
            if info.matchesDisk == false, let exact = disk.hashes.first { info.diskCdhash = exact }
        }
        return info
    }

    /// Whether the running code and the scanned file are the same program.
    /// `SecCodeCopyPath` returns the bundle for an app but the executable for a
    /// bare binary, while the scanned path may be the Mach-O inside the bundle,
    /// so one being the other's prefix counts as a match. Symlinks are resolved.
    static func isSameFile(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let ra = URL(fileURLWithPath: a).resolvingSymlinksInPath().path
        let rb = URL(fileURLWithPath: b).resolvingSymlinksInPath().path
        return ra == rb || ra.hasPrefix(rb + "/") || rb.hasPrefix(ra + "/")
    }

    /// Code directory hashes of the file for every architecture it carries
    /// (the default slice first), so a Rosetta process still matches its file.
    static func diskHashes(path: String) -> (hashes: [String], unsigned: Bool) {
        let url = URL(fileURLWithPath: path) as CFURL
        var hashes: [String] = []
        var unsigned = false
        var attributeSets: [[String: Any]] = [[:]]
        attributeSets += ["arm64", "x86_64"].map { [kSecCodeAttributeArchitecture as String: $0] }
        for (index, attributes) in attributeSets.enumerated() {
            var staticCode: SecStaticCode?
            let created = SecStaticCodeCreateWithPathAndAttributes(url, [], attributes as CFDictionary, &staticCode)
            guard created == errSecSuccess, let staticCode else { continue }
            if index == 0, SecStaticCodeCheckValidity(staticCode, [], nil) == errSecCSUnsigned {
                unsigned = true
                break
            }
            if let hash = uniqueHash(of: staticCode), !hashes.contains(hash) { hashes.append(hash) }
        }
        return (hashes, unsigned)
    }

    static func uniqueHash(of code: SecStaticCode) -> String? {
        var signingInfo: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &signingInfo) == errSecSuccess,
              let dict = signingInfo as? [String: Any],
              let unique = dict[kSecCodeInfoUnique as String] as? Data else { return nil }
        return unique.map { String(format: "%02x", $0) }.joined()
    }
}
