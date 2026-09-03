import Foundation
import WhoRUCore

/// The one command an AI engine may run while it works for whoRU.
///
/// It takes a subcommand and nothing else; the program under review comes
/// from environment variables whoRU sets when it spawns the engine. Every
/// subcommand runs a fixed system tool with a fixed argument list on that
/// subject, so the model can inspect what it was asked about and nothing
/// else: no other binary's strings, no other plist, no other process.
///
///   WHORU_SUBJECT_PATH        the bundle or file whoRU is checking (required)
///   WHORU_SUBJECT_EXECUTABLE  the Mach-O the bundle actually runs (defaults to the path)
///   WHORU_SUBJECT_PID         the process behind the dialog, when it is still running
@main
struct Inspect {
    static let subcommands: [(name: String, help: String)] = [
        ("signature", "code signature and entitlements (codesign -dvvv --entitlements -)"),
        ("gatekeeper", "Gatekeeper assessment (spctl --assess --type execute -vv)"),
        ("libraries", "linked libraries of the executable (otool -L)"),
        ("headers", "Mach-O header of the executable (otool -h)"),
        ("plist", "Info.plist of the bundle (plutil -p)"),
        ("attributes", "extended attributes, stat, file type and Spotlight metadata"),
        ("process", "the running process, if any (ps)"),
        ("network", "its open network connections (lsof -i)"),
        ("files", "folders under the home directory it has files open in (never file names)"),
        ("help", "this list"),
    ]

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 1, let subcommand = arguments.first else {
            fail("usage: whoru-inspect <subcommand>; run `whoru-inspect help` for the list")
        }
        if subcommand == "help" {
            print(usage())
            exit(0)
        }
        guard subcommands.contains(where: { $0.name == subcommand }) else {
            fail("unknown subcommand: \(subcommand)")
        }
        let subject = Subject.fromEnvironment()
        do {
            exit(try await run(subcommand, on: subject))
        } catch {
            fail(String(describing: error))
        }
    }

    static func usage() -> String {
        var lines = ["whoru-inspect: inspects the program whoRU is checking. Subcommands:"]
        for entry in subcommands {
            lines.append("  \(entry.name.padding(toLength: 12, withPad: " ", startingAt: 0))\(entry.help)")
        }
        return lines.joined(separator: "\n")
    }

    /// Prints one line to stderr and exits 2, the code Claude Code shows as a
    /// usage error rather than a crash.
    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("whoru-inspect: \(message)\n".utf8))
        exit(2)
    }

    static func run(_ subcommand: String, on subject: Subject) async throws -> Int32 {
        switch subcommand {
        case "signature":
            return try await emit("/usr/bin/codesign", ["-dvvv", "--entitlements", "-", subject.path])
        case "gatekeeper":
            return try await emit("/usr/sbin/spctl", ["--assess", "--type", "execute", "-vv", subject.path])
        case "libraries":
            return try await emit("/usr/bin/otool", ["-L", subject.executable])
        case "headers":
            return try await emit("/usr/bin/otool", ["-h", subject.executable])
        case "plist":
            let plist = subject.path + "/Contents/Info.plist"
            guard subject.isBundle, FileManager.default.fileExists(atPath: plist) else { fail("the subject is not an application bundle") }
            return try await emit("/usr/bin/plutil", ["-p", plist])
        case "attributes":
            var status: Int32 = 0
            for (tool, arguments) in [
                ("/usr/bin/xattr", ["-l", subject.path]),
                ("/usr/bin/stat", [subject.path]),
                ("/usr/bin/file", [subject.path]),
                ("/usr/bin/mdls", [subject.path]),
            ] {
                print("$ \((tool as NSString).lastPathComponent) \(arguments.dropLast().joined(separator: " "))".trimmingCharacters(in: .whitespaces))
                status = max(status, try await emit(tool, arguments, timeout: .seconds(10)))
            }
            return status
        case "process":
            let pid = try requirePID(subject)
            return try await emit("/bin/ps", ["-p", pid, "-o", "pid,ppid,user,lstart,command"])
        case "network":
            let pid = try requirePID(subject)
            return try await emit("/usr/sbin/lsof", ["-a", "-p", pid, "-i", "-n", "-P"], timeout: .seconds(10))
        case "files":
            let pid = try requirePID(subject)
            let output = try await Command.run("/usr/sbin/lsof", ["-p", pid, "-F", "n"], timeout: .seconds(10))
            for folder in openFolders(lsofNames: output.stdout) { print(folder) }
            if !output.stderr.isEmpty { FileHandle.standardError.write(Data(output.stderr.utf8)) }
            return output.succeeded ? 0 : 1
        default:
            fail("unknown subcommand: \(subcommand)")
        }
    }

    /// Runs one fixed tool and relays what it printed. codesign and spctl
    /// write their report to stderr; both streams are passed through as is.
    static func emit(_ tool: String, _ arguments: [String], timeout: Duration = .seconds(8)) async throws -> Int32 {
        let output = try await Command.run(tool, arguments, timeout: timeout)
        if !output.stdout.isEmpty { print(output.stdout, terminator: output.stdout.hasSuffix("\n") ? "" : "\n") }
        if !output.stderr.isEmpty { FileHandle.standardError.write(Data(output.stderr.utf8)) }
        if output.timedOut { fail("\((tool as NSString).lastPathComponent) timed out") }
        return output.status
    }

    static func requirePID(_ subject: Subject) throws -> String {
        guard let pid = subject.pid else { fail("the subject is not running (WHORU_SUBJECT_PID is not set)") }
        return String(pid)
    }

    /// The `-F n` field output of lsof, reduced to the folders under the home
    /// directory that hold open files. Names are never shown: which folders a
    /// process reaches into says enough, and a file name could be personal.
    static func openFolders(lsofNames: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        var folders = Set<String>()
        for line in lsofNames.split(separator: "\n") where line.hasPrefix("n") {
            let name = String(line.dropFirst())
            guard name.hasPrefix(home + "/") else { continue }
            let folder = (name as NSString).deletingLastPathComponent
            guard folder.hasPrefix(home) else { continue }
            folders.insert("~" + folder.dropFirst(home.count))
        }
        return folders.sorted()
    }

    struct Subject {
        var path: String
        var executable: String
        var pid: Int32?
        var isBundle: Bool

        /// Reads the subject whoRU described, or exits 2. The path must exist:
        /// a shim that accepted any string would be a probe for the file system.
        static func fromEnvironment() -> Subject {
            let env = ProcessInfo.processInfo.environment
            guard let path = env["WHORU_SUBJECT_PATH"], !path.isEmpty else {
                fail("WHORU_SUBJECT_PATH is not set; this tool only runs inside whoRU")
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                fail("subject does not exist: \(path)")
            }
            let isBundle = isDirectory.boolValue && FileManager.default.fileExists(atPath: path + "/Contents/Info.plist")
            guard !isDirectory.boolValue || isBundle else {
                fail("subject is a folder, not a program: \(path)")
            }
            var executable = env["WHORU_SUBJECT_EXECUTABLE"] ?? ""
            if executable.isEmpty || !FileManager.default.fileExists(atPath: executable) { executable = path }
            let pid = env["WHORU_SUBJECT_PID"].flatMap { Int32($0) }.flatMap { $0 > 0 ? $0 : nil }
            return Subject(path: path, executable: executable, pid: pid, isBundle: isBundle)
        }
    }
}
