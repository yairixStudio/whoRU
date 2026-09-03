import Darwin
import Foundation
import Security

/// Facts about a running process that the process cannot forge: whether it
/// is code Apple ships with macOS, and which file it runs. A window's owner
/// name and bundle identifier are the process's own claims; these are the
/// kernel's and the signature's.
public enum ProcessTrust {
    /// Whether the process satisfies the `anchor apple` requirement: signed
    /// by Apple as part of the platform. Cheap enough to run once per window.
    public static func isApplePlatformProcess(pid: pid_t) -> Bool {
        guard let code = runningCode(pid: pid) else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// The code object of a running process, for validity and signing queries.
    static func runningCode(pid: pid_t) -> SecCode? {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: Int(pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess else { return nil }
        return code
    }

    /// The executable the process runs, from the kernel (`proc_pidpath`).
    public static func executablePath(pid: pid_t) -> String? {
        MacProcessInspector.path(of: pid)
    }
}
