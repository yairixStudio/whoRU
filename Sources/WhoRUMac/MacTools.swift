import Foundation
import WhoRUCore

/// Tools the model may call on macOS. Every handler works on the scan's
/// subject only; the model cannot point them at other files.
public enum MacTools {
    public static func handlers(processes: any ProcessInspector = MacProcessInspector()) -> [ToolHandler] {
        [
            ToolHandler(
                tool: AnalystTool(name: "get_entitlements", description: "Entitlements and code-signing flags of the program under review (sandbox, hardened runtime, capabilities)."),
                run: { _, subject in
                    guard let subject else { return ["error": "no subject"] }
                    let info = await CodeSignature.inspect(path: subject.verificationPath)
                    return ["hardened_runtime": .bool(info.hardenedRuntime), "entitlements": .object(info.entitlements), "signer": .string(info.leafSummary ?? "none"), "summary": .string("\(info.entitlements.count) entitlements")]
                }
            ),
            ToolHandler(
                tool: AnalystTool(name: "get_parent_chain", description: "The chain of processes that launched the program, up to launchd, each with its path and signer."),
                run: { _, subject in
                    guard let subject, let pid = subject.pid else { return ["error": "the program is not running"] }
                    guard let chain = try? await processes.parentChain(of: pid) else { return ["error": "could not read the process chain"] }
                    var links: [JSONValue] = []
                    for p in chain {
                        let sig = await CodeSignature.inspect(path: p.path)
                        links.append(["pid": .number(Double(p.pid)), "name": .string(p.localizedName ?? p.name), "path": .string(p.path), "signer": .string(sig.leafSummary ?? sig.kind.rawValue)])
                    }
                    return ["chain": .array(links), "summary": .string(chain.map { $0.localizedName ?? $0.name }.joined(separator: " → "))]
                }
            ),
            ToolHandler(
                tool: AnalystTool(name: "list_network_connections", description: "Open network connections of the running program right now (lsof)."),
                run: { _, subject in
                    guard let subject, let pid = subject.pid else { return ["error": "the program is not running"] }
                    guard let output = try? await Command.run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-i", "-n", "-P"], timeout: .seconds(8)) else { return ["error": "lsof failed"] }
                    let lines = output.stdout.split(separator: "\n").dropFirst().map(String.init)
                    return ["connections": .array(lines.prefix(50).map { .string($0) }), "summary": .string("\(lines.count) sockets")]
                }
            ),
            ToolHandler(
                tool: AnalystTool(name: "read_info_plist", description: "Selected Info.plist fields of the program's bundle: identifier, version, usage descriptions (text written by the program itself)."),
                run: { _, subject in
                    guard let subject, let bundlePath = subject.bundlePath ?? BundleInfo.enclosingBundlePath(of: subject.path), let info = BundleInfo.read(bundlePath: bundlePath) else {
                        return ["error": "no bundle or Info.plist"]
                    }
                    return ["identifier": .string(info.identifier ?? ""), "version": .string(info.shortVersion ?? ""), "display_name": .string(info.displayName ?? ""),
                            "usage_descriptions_hostile": .object(info.usageDescriptions.mapValues { .string($0) }), "summary": .string(info.identifier ?? bundlePath)]
                }
            ),
            ToolHandler(
                tool: AnalystTool(name: "find_persistence", description: "Launch agents, launch daemons and login items that reference the program."),
                run: { _, subject in
                    guard let subject else { return ["error": "no subject"] }
                    let context = CheckContext(prompt: PermissionPrompt(title: "", requesterName: "", service: .other, requestPhrase: ""))
                    guard let item = try? await PersistenceCheck().run(on: subject, context: context) else { return ["error": "scan failed"] }
                    return ["present": .bool(item.facts[Fact.persistent] == "true"), "details": .string(item.raw ?? ""), "summary": .string(item.summary)]
                }
            ),
            ToolHandler(
                tool: AnalystTool(name: "list_open_files", description: "Folders in user data locations where the running program currently has files open, with a count of those files. Folder paths only, never file names."),
                run: { _, subject in
                    guard let subject, let pid = subject.pid else { return ["error": "the program is not running"] }
                    guard let output = try? await Command.run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-F", "n"], timeout: .seconds(8)) else { return ["error": "lsof failed"] }
                    let paths = output.stdout.split(separator: "\n").filter { $0.hasPrefix("n/") }.map { String($0.dropFirst()) }
                    let open = openFileFolders(paths, home: FileManager.default.homeDirectoryForCurrentUser.path)
                    return ["folders": .array(open.folders.map { .string($0) }), "file_count": .number(Double(open.fileCount)), "summary": .string("\(open.fileCount) user files open in \(open.folders.count) folders")]
                }
            ),
        ]
    }

    /// The folders of the user files among `paths`, home directory replaced by
    /// `~`, and how many files there were. File names stay on the machine: the
    /// model only needs to know where the program is reading, and it may be a
    /// cloud engine run by another vendor.
    static func openFileFolders(_ paths: [String], home: String, limit: Int = 25) -> (folders: [String], fileCount: Int) {
        let files = Set(paths
            .filter { $0.hasPrefix(home) || $0.hasPrefix("/Volumes") || $0.hasPrefix("/Users") }
            .filter { !$0.contains("/Library/Caches/") && !$0.hasSuffix(".dylib") })
        let folders = Set(files.map { ($0 as NSString).deletingLastPathComponent })
            .map { home.isEmpty ? $0 : $0.replacingOccurrences(of: home, with: "~") }
        return (Array(folders.sorted().prefix(limit)), files.count)
    }
}
