import AppKit
import Darwin
import Foundation
import WhoRUCore

/// Process listing through libproc, enriched with NSWorkspace for applications.
public struct MacProcessInspector: ProcessInspector {
    public init() {}

    public func runningProcesses() async throws -> [RunningProcess] {
        let apps = await MainActor.run { Self.applicationsByPID() }
        return Self.allProcesses().map { process in
            var p = process
            if let app = apps[p.pid] {
                p.bundleID = app.bundleIdentifier
                p.localizedName = app.localizedName
                p.isApplication = true
                p.startedAt = app.launchDate ?? p.startedAt
            }
            return p
        }
    }

    public func parentChain(of pid: Int32) async throws -> [RunningProcess] {
        let apps = await MainActor.run { Self.applicationsByPID() }
        var chain: [RunningProcess] = []
        var current = pid
        var guardCount = 0
        while current > 0, guardCount < 32 {
            guardCount += 1
            guard var process = Self.process(pid: current) else { break }
            if let app = apps[current] {
                process.bundleID = app.bundleIdentifier
                process.localizedName = app.localizedName
                process.isApplication = true
            }
            chain.append(process)
            if current == 1 { break }
            current = process.ppid
        }
        return chain
    }

    // MARK: libproc

    static func allProcesses() -> [RunningProcess] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled)).compactMap { pid in pid > 0 ? process(pid: pid) : nil }
    }

    static func process(pid: pid_t) -> RunningProcess? {
        guard let path = path(of: pid) else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let got = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        let ppid: Int32 = got == size ? Int32(info.pbi_ppid) : 0
        let started: Date? = got == size && info.pbi_start_tvsec > 0 ? Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)) : nil
        return RunningProcess(pid: pid, ppid: ppid, path: path, startedAt: started)
    }

    static func path(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN)) // PROC_PIDPATHINFO_MAXSIZE
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    @MainActor
    static func applicationsByPID() -> [pid_t: NSRunningApplication] {
        var map: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications { map[app.processIdentifier] = app }
        return map
    }
}

/// Finds installed applications by name: well-known folders first, then Spotlight.
public struct MacApplicationFinder: ApplicationFinder {
    public init() {}

    public func applications(named name: String) async throws -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var found: [String] = []
        for folder in ["/Applications", "/Applications/Utilities", "\(home)/Applications", "/System/Applications", "/System/Applications/Utilities", "/System/Library/CoreServices"] {
            let candidate = "\(folder)/\(name).app"
            if FileManager.default.fileExists(atPath: candidate) { found.append(candidate) }
        }
        if found.isEmpty, Self.isSafeSpotlightName(name) {
            // Spotlight. The name goes inside the query string, so only names that
            // cannot change the query's meaning get this far.
            let query = "kMDItemDisplayName == '\(name)' && kMDItemContentType == 'com.apple.application-bundle'"
            if let output = try? await Command.run("/usr/bin/mdfind", [query], timeout: .seconds(3)), output.succeeded {
                found = output.stdout.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            }
        }
        return found
    }

    /// Whether a dialog's display name may be interpolated into a Spotlight
    /// query. `*` and `?` are wildcards even inside a quoted string (a dialog
    /// named “*” would match every application), quotes and backslashes end or
    /// escape the string, and control characters have no place in a name.
    public static func isSafeSpotlightName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let forbidden = Set("*?\"'\\".unicodeScalars)
        return !name.unicodeScalars.contains { forbidden.contains($0) || CharacterSet.controlCharacters.contains($0) }
    }
}
