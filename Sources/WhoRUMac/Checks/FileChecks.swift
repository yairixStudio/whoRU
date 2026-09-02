import Darwin
import Foundation
import WhoRUCore

enum ExtendedAttributes {
    static func read(_ name: String, at path: String) -> String? {
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let got = getxattr(path, name, &buffer, size, 0, 0)
        guard got > 0 else { return nil }
        return String(decoding: buffer.prefix(got), as: UTF8.self)
    }

    static func exists(_ name: String, at path: String) -> Bool {
        getxattr(path, name, nil, 0, 0, 0) >= 0
    }
}

/// Where the file came from: quarantine agent and original URLs.
public struct DownloadOriginCheck: EvidenceCheck {
    public let key: EvidenceKey = .downloadOrigin
    public let weight: EvidenceWeight = .high
    public init() {}

    static let knownAgents = ["Safari", "Google Chrome", "Chrome", "Firefox", "Microsoft Edge", "Arc", "Brave Browser", "Mail", "Messages", "AirDrop", "sharingd", "Finder", "Xcode", "App Store", "curl", "Homebrew", "brew", "Slack", "Telegram", "WhatsApp", "Discord", "Transmission", "Cursor", "Comet"]

    public func run(on subject: Subject, context: CheckContext) async throws -> EvidenceItem {
        let started = Date()
        let path = subject.verificationPath
        let quarantine = ExtendedAttributes.read("com.apple.quarantine", at: path)
        let provenance = ExtendedAttributes.exists("com.apple.provenance", at: path)
        var whereFroms: [String] = []
        if let output = try? await Command.run("/usr/bin/mdls", ["-name", "kMDItemWhereFroms", "-raw", path], timeout: .seconds(3)), output.succeeded {
            whereFroms = Self.parseWhereFroms(output.stdout)
        }
        let durationMs = Int(Date().timeIntervalSince(started) * 1000)
        var raw = "com.apple.quarantine: \(quarantine ?? "(none)")\ncom.apple.provenance: \(provenance ? "present" : "(none)")\nkMDItemWhereFroms: \(whereFroms.isEmpty ? "(none)" : whereFroms.joined(separator: ", "))"
        var facts: [String: String] = [:]

        // Quarantine format: flags;hex timestamp;agent name;UUID
        let agent = quarantine?.split(separator: ";", omittingEmptySubsequences: false).dropFirst(2).first.map(String.init) ?? ""
        let host = whereFroms.first.flatMap { URL(string: $0)?.host }

        if quarantine == nil, whereFroms.isEmpty {
            facts[Fact.downloadSource] = "none"
            let summary = provenance ? "no quarantine flag; provenance recorded (installed by a signed installer or package manager)" : "no download record (installed from the App Store, a package, or built locally)"
            return EvidenceItem(key: key, status: .pass, weight: weight, summary: summary, raw: raw, method: "getxattr, mdls", durationMs: durationMs, facts: facts)
        }
        if let host {
            facts[Fact.downloadURL] = host
            facts[Fact.downloadSource] = "known"
            raw += "\nhost: \(host)"
            let via = agent.isEmpty ? "" : " via \(agent)"
            return EvidenceItem(key: key, status: .pass, weight: weight, summary: "downloaded from \(host)\(via)", raw: raw, method: "getxattr, mdls", durationMs: durationMs, facts: facts)
        }
        if !agent.isEmpty, Self.knownAgents.contains(where: { agent.localizedCaseInsensitiveContains($0) }) {
            facts[Fact.downloadSource] = "known"
            return EvidenceItem(key: key, status: .info, weight: weight, summary: "arrived via \(agent), original address unknown", raw: raw, method: "getxattr, mdls", durationMs: durationMs, facts: facts)
        }
        facts[Fact.downloadSource] = "unknown"
        return EvidenceItem(key: key, status: .warn, weight: weight, summary: "quarantined with no known origin" + (agent.isEmpty ? "" : " (agent: \(agent))"), raw: raw, method: "getxattr, mdls", durationMs: durationMs, facts: facts)
    }

    static func parseWhereFroms(_ text: String) -> [String] {
        // mdls -raw prints a plist-style array: (\n    "https://…",\n    "https://…"\n)
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t,\"")) }
            .filter { $0.hasPrefix("http") || $0.hasPrefix("ftp") }
    }
}

/// Is the file somewhere programs normally live.
public struct LocationCheck: EvidenceCheck {
    public let key: EvidenceKey = .location
    public let weight: EvidenceWeight = .medium
    public init() {}

    static let standardPrefixes = [
        "/Applications/", "/System/", "/usr/bin/", "/usr/sbin/", "/bin/", "/sbin/", "/usr/libexec/", "/usr/local/", "/opt/homebrew/", "/opt/local/",
        "/Library/Apple/", "/Library/Application Support/", "/Library/PrivilegedHelperTools/", "/Library/Frameworks/",
    ]
    static let standardHomeSuffixes = [
        "/Applications/", "/.local/", "/Library/Application Support/", "/.cargo/bin/", "/.nvm/", "/.npm/", "/.bun/", "/.rbenv/", "/.pyenv/", "/go/bin/", "/.vscode/", "/.cursor/", "/Library/Developer/", "/.rustup/", "/.deno/", "/.volta/", "/.asdf/", "/.sdkman/", "/.claude/", "/.docker/",
    ]
    static let suspiciousPrefixes = ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/", "/var/tmp/", "/dev/shm/"]
    static let suspiciousHomeSuffixes = ["/Downloads/", "/Desktop/", "/Public/", "/.Trash/", "/Library/Caches/"]

    public func run(on subject: Subject, context: CheckContext) async throws -> EvidenceItem {
        let path = subject.verificationPath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let (cls, description) = Self.classify(path, home: home)
        let status: EvidenceStatus = switch cls {
        case "standard": .pass
        case "suspicious": .warn
        default: .info
        }
        let shown = path.replacingOccurrences(of: home, with: "~")
        return EvidenceItem(key: key, status: status, weight: weight, summary: "\((shown as NSString).deletingLastPathComponent) (\(description))", method: "path classification", facts: [Fact.locationClass: cls])
    }

    static func classify(_ path: String, home: String) -> (String, String) {
        if standardPrefixes.contains(where: { path.hasPrefix($0) }) { return ("standard", "standard location") }
        if suspiciousPrefixes.contains(where: { path.hasPrefix($0) }) { return ("suspicious", "temporary folder") }
        if path.hasPrefix(home + "/") {
            let rest = String(path.dropFirst(home.count))
            if standardHomeSuffixes.contains(where: { rest.hasPrefix($0) }) { return ("standard", "known install path") }
            if suspiciousHomeSuffixes.contains(where: { rest.hasPrefix($0) }) { return ("suspicious", "not an install location") }
            if rest.hasPrefix("/.") { return ("suspicious", "hidden folder") }
            return ("unknown", "inside the home folder")
        }
        return ("unknown", "unusual location")
    }
}

/// Who launched it: the process chain up to launchd, with each link's signer.
public struct ParentChainCheck: EvidenceCheck {
    public let key: EvidenceKey = .parentChain
    public let weight: EvidenceWeight = .high
    public let processes: any ProcessInspector

    public init(processes: any ProcessInspector = MacProcessInspector()) { self.processes = processes }

    static let browsers = ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "com.microsoft.edgemac", "company.thebrowser.Browser", "com.brave.Browser", "ai.perplexity.comet"]

    public func run(on subject: Subject, context: CheckContext) async throws -> EvidenceItem {
        guard let pid = subject.pid else { return .skipped(key, weight: weight, reason: "not running, no launch chain") }
        let started = Date()
        let chain = try await processes.parentChain(of: pid)
        guard chain.count > 1 else { return EvidenceItem(key: key, status: .info, weight: weight, summary: "no parent information", method: "proc_pidinfo") }
        var links: [String] = []
        var launchedByBrowser = false
        var rawLines: [String] = []
        for process in chain.dropFirst() {
            let sig = await CodeSignature.inspect(path: process.path)
            let who: String = switch sig.kind {
            case .apple: "Apple"
            case .developerID, .appStore: sig.publisherName ?? "signed"
            case .adhoc: "ad-hoc"
            case .unsigned: "unsigned"
            case .unknown: "?"
            }
            let name = process.localizedName ?? process.name
            links.append(process.pid == 1 ? "launchd" : "\(name) (\(who))")
            rawLines.append("\(process.pid)\t\(process.ppid)\t\(process.path)\t\(sig.leafSummary ?? "-")")
            if let bundle = process.bundleID, Self.browsers.contains(bundle) { launchedByBrowser = true }
        }
        let summary = links.joined(separator: " → ")
        let isApp = subject.bundlePath != nil
        let status: EvidenceStatus = (launchedByBrowser && !isApp) ? .warn : .pass
        return EvidenceItem(key: key, status: status, weight: weight,
                            summary: status == .warn ? "launched by a browser: \(summary)" : summary,
                            raw: "pid\tppid\tpath\tsigner\n" + rawLines.joined(separator: "\n"), method: "proc_pidinfo + SecCode",
                            durationMs: Int(Date().timeIntervalSince(started) * 1000),
                            facts: ["parent.browser": launchedByBrowser ? "true" : "false"])
    }
}

/// Launch agents and daemons that point at this program.
public struct PersistenceCheck: EvidenceCheck {
    public let key: EvidenceKey = .persistence
    public let weight: EvidenceWeight = .medium
    public init() {}

    public func run(on subject: Subject, context: CheckContext) async throws -> EvidenceItem {
        let started = Date()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folders = ["\(home)/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"]
        let needles = [subject.path, subject.bundlePath, subject.bundleID].compactMap { $0 }.filter { !$0.isEmpty }
        var hits: [String] = []
        for folder in folders {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: folder) else { continue }
            for file in files where file.hasSuffix(".plist") {
                let full = "\(folder)/\(file)"
                guard let data = FileManager.default.contents(atPath: full),
                      let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { continue }
                var targets: [String] = []
                if let p = plist["Program"] as? String { targets.append(p) }
                if let args = plist["ProgramArguments"] as? [String] { targets += args }
                if let bundle = plist["BundleProgram"] as? String { targets.append(bundle) }
                if let label = plist["Label"] as? String { targets.append(label) }
                if targets.contains(where: { t in needles.contains(where: { t.contains($0) }) }) {
                    hits.append(full.replacingOccurrences(of: home, with: "~"))
                }
            }
        }
        let durationMs = Int(Date().timeIntervalSince(started) * 1000)
        if hits.isEmpty {
            return EvidenceItem(key: key, status: .pass, weight: weight, summary: "not registered to launch automatically", method: "LaunchAgents/LaunchDaemons scan", durationMs: durationMs, facts: [Fact.persistent: "false"])
        }
        return EvidenceItem(key: key, status: .info, weight: weight, summary: "launches automatically via \(hits.joined(separator: ", "))", raw: hits.joined(separator: "\n"), method: "LaunchAgents/LaunchDaemons scan", durationMs: durationMs, facts: [Fact.persistent: "true"])
    }
}

/// What the program declares about itself. Usage descriptions are hostile text.
public struct DeclarationsCheck: EvidenceCheck {
    public let key: EvidenceKey = .declarations
    public let weight: EvidenceWeight = .medium
    public init() {}

    public func run(on subject: Subject, context: CheckContext) async throws -> EvidenceItem {
        guard let bundlePath = subject.bundlePath ?? BundleInfo.enclosingBundlePath(of: subject.path),
              let info = BundleInfo.read(bundlePath: bundlePath) else {
            return EvidenceItem(key: key, status: .info, weight: weight, summary: "bare executable, no Info.plist", method: "Info.plist")
        }
        var facts: [String: String] = [:]
        if let id = info.identifier { facts[Fact.bundleID] = id }
        if let v = info.shortVersion { facts[Fact.version] = v }
        var parts: [String] = []
        if let id = info.identifier { parts.append(id) }
        if let v = info.shortVersion { parts.append("v\(v)") }
        let relevant = info.usageDescriptions.filter { Self.matches(key: $0.key, service: context.prompt.service) }
        let raw = info.usageDescriptions.isEmpty ? "(no usage descriptions)" : info.usageDescriptions.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")
        if let explanation = relevant.first?.value {
            parts.append("explains the request: “\(explanation)”")
        } else if !info.usageDescriptions.isEmpty {
            parts.append("\(info.usageDescriptions.count) usage descriptions, none for this permission")
        } else {
            parts.append("no usage descriptions")
        }
        return EvidenceItem(key: key, status: .info, weight: weight, summary: parts.joined(separator: " · "), raw: raw, method: "Info.plist", facts: facts)
    }

    static func matches(key: String, service: PermissionService) -> Bool {
        switch service {
        case .camera: key == "NSCameraUsageDescription"
        case .microphone: key == "NSMicrophoneUsageDescription"
        case .contacts: key == "NSContactsUsageDescription"
        case .calendar: key.hasPrefix("NSCalendars")
        case .reminders: key.hasPrefix("NSReminders")
        case .photos: key.hasPrefix("NSPhotoLibrary")
        case .appleEvents: key == "NSAppleEventsUsageDescription"
        case .location: key.hasPrefix("NSLocation")
        case .speechRecognition: key == "NSSpeechRecognitionUsageDescription"
        case .bluetooth: key.hasPrefix("NSBluetooth")
        case .desktopFolder: key == "NSDesktopFolderUsageDescription"
        case .documentsFolder: key == "NSDocumentsFolderUsageDescription"
        case .downloadsFolder: key == "NSDownloadsFolderUsageDescription"
        case .networkVolumes: key == "NSNetworkVolumesUsageDescription"
        case .removableVolumes: key == "NSRemovableVolumesUsageDescription"
        case .fullDiskAccess: key == "NSSystemAdministrationUsageDescription"
        default: false
        }
    }
}

/// When the file appeared and when it was signed.
public struct TimestampsCheck: EvidenceCheck {
    public let key: EvidenceKey = .timestamps
    public let weight: EvidenceWeight = .low
    public init() {}

    public func run(on subject: Subject, context: CheckContext) async throws -> EvidenceItem {
        let path = subject.verificationPath
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let created = attrs[.creationDate] as? Date
        let modified = attrs[.modificationDate] as? Date
        let signed = await CodeSignature.inspect(path: path).signingTime
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        var parts: [String] = []
        var facts: [String: String] = [:]
        let iso = ISO8601DateFormatter()
        if let created {
            parts.append("created \(formatter.localizedString(for: created, relativeTo: Date()))")
            facts[Fact.createdAt] = iso.string(from: created)
        }
        if let modified { parts.append("modified \(formatter.localizedString(for: modified, relativeTo: Date()))") }
        if let signed { parts.append("signed \(formatter.localizedString(for: signed, relativeTo: Date()))") }
        let brandNew = created.map { Date().timeIntervalSince($0) < 600 } ?? false
        let status: EvidenceStatus = (brandNew && context.prompt.service.isSensitive) ? .warn : .info
        return EvidenceItem(key: key, status: status, weight: weight,
                            summary: (status == .warn ? "created minutes ago and asking for a sensitive permission: " : "") + parts.joined(separator: ", "),
                            method: "stat, kSecCodeInfoTime", facts: facts)
    }
}

/// Open network connections of the running process. Slow, runs after the verdict.
public struct NetworkConnectionsCheck: EvidenceCheck {
    public let key: EvidenceKey = .networkConnections
    public let weight: EvidenceWeight = .medium
    public let isSlow = true
    public init() {}

    public func run(on subject: Subject, context: CheckContext) async throws -> EvidenceItem {
        guard let pid = subject.pid else { return .skipped(key, weight: weight, reason: "not running") }
        // -a ANDs the selectors; without it lsof ORs -p and -i and lists every internet socket on the machine.
        let output = try await Command.run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-i", "-n", "-P", "-F", "n"], timeout: .seconds(8))
        let hosts = output.stdout.split(separator: "\n").filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
        let remote = Set(hosts.compactMap { line -> String? in
            guard let arrow = line.range(of: "->") else { return nil }
            return String(line[arrow.upperBound...])
        })
        if remote.isEmpty {
            return EvidenceItem(key: key, status: .info, weight: weight, summary: hosts.isEmpty ? "no network sockets" : "listening or local only, no remote connections", raw: output.combined, method: "lsof -p <pid> -i", durationMs: output.durationMs)
        }
        let shown = remote.sorted().prefix(5).joined(separator: ", ")
        return EvidenceItem(key: key, status: .info, weight: weight, summary: "\(remote.count) remote connection\(remote.count == 1 ? "" : "s"): \(shown)\(remote.count > 5 ? "…" : "")", raw: output.combined, method: "lsof -p <pid> -i", durationMs: output.durationMs, facts: ["network.remoteCount": String(remote.count)])
    }
}
