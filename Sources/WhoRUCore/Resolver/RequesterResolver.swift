import Foundation

public struct ResolveResult: Sendable, Hashable {
    public var subject: Subject?
    /// Everything else that matched, so collisions can be shown.
    public var candidates: [SubjectCandidate]

    public init(subject: Subject?, candidates: [SubjectCandidate] = []) {
        self.subject = subject
        self.candidates = candidates
    }
}

/// Turns the display name in a dialog into a file on disk. Strategies run in
/// order; the first high-confidence hit wins, but every match is kept as a
/// candidate so that two processes with the same name are visible.
public struct RequesterResolver: Sendable {
    public let processes: any ProcessInspector
    public let finder: (any ApplicationFinder)?

    public init(processes: any ProcessInspector, finder: (any ApplicationFinder)? = nil) {
        self.processes = processes
        self.finder = finder
    }

    public func resolve(_ prompt: PermissionPrompt) async -> ResolveResult {
        resolveName(prompt.requesterName, running: (try? await processes.runningProcesses()) ?? [], found: await findApplications(prompt.requesterName))
    }

    /// Pure function over a snapshot, so it can be unit-tested with fakes.
    public func resolveName(_ rawName: String, running: [RunningProcess], found: [String]) -> ResolveResult {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        var candidates: [SubjectCandidate] = []
        var best: Subject?

        func consider(_ process: RunningProcess, strategy: String, confidence: Confidence) {
            // Several processes of the same file (many terminal sessions of one tool) are one candidate.
            if !candidates.contains(where: { $0.path == process.path }) {
                candidates.append(SubjectCandidate(path: process.path, pid: process.pid, strategy: strategy, confidence: confidence))
            }
            if best == nil || confidence > best!.resolver.confidence {
                best = makeSubject(from: process, strategy: strategy, confidence: confidence)
            }
        }

        // 1. A running process whose executable has exactly this name.
        // This is the “2.1.258” case: a bare binary named after its version.
        for p in running where p.name == name {
            consider(p, strategy: "running_process_basename", confidence: .high)
        }

        // 2. A running application whose display name matches.
        if best == nil {
            for p in running where p.isApplication && Self.namesMatch(p.localizedName, name) {
                consider(p, strategy: "running_app_name", confidence: .high)
            }
        }

        // 3. A helper process inside an app bundle whose bundle name matches,
        // or whose name is "<App> Helper"-style.
        if best == nil {
            for p in running {
                if let bundle = BundleInfo.read(containing: p.path), Self.namesMatch(bundle.displayName, name) {
                    consider(p, strategy: "helper_in_bundle", confidence: .medium)
                } else if Self.namesMatch(p.name, name) || Self.namesMatch(p.localizedName, name) {
                    consider(p, strategy: "running_process_name_ci", confidence: .medium)
                }
            }
        }

        // 4. Installed applications with this name that are not running.
        if best == nil, !found.isEmpty {
            let confidence: Confidence = found.count == 1 ? .medium : .low
            for path in found {
                candidates.append(SubjectCandidate(path: path, strategy: "installed_app", confidence: confidence))
            }
            if let first = found.first {
                let bundle = BundleInfo.read(bundlePath: first) ?? BundleInfo.read(containing: first)
                best = Subject(
                    path: first,
                    bundleID: bundle?.identifier,
                    displayName: bundle?.displayName ?? name,
                    version: bundle?.shortVersion,
                    bundlePath: bundle?.bundlePath,
                    resolver: ResolverOutcome(strategy: "installed_app", confidence: confidence)
                )
            }
        }

        // Several distinct high-confidence matches lower confidence: the user
        // must see the collision.
        let distinctHigh = Set(candidates.filter { $0.confidence == .high }.map(\.path))
        if distinctHigh.count > 1, var subject = best {
            subject.resolver.confidence = .medium
            best = subject
        }

        return ResolveResult(subject: best, candidates: candidates)
    }

    private func findApplications(_ name: String) async -> [String] {
        guard let finder else { return [] }
        return (try? await finder.applications(named: name)) ?? []
    }

    private func makeSubject(from process: RunningProcess, strategy: String, confidence: Confidence) -> Subject {
        let bundle = BundleInfo.read(containing: process.path)
        return Subject(
            path: process.path,
            pid: process.pid,
            bundleID: process.bundleID ?? bundle?.identifier,
            displayName: process.localizedName ?? bundle?.displayName ?? process.name,
            version: bundle?.shortVersion,
            bundlePath: bundle?.bundlePath,
            resolver: ResolverOutcome(strategy: strategy, confidence: confidence)
        )
    }

    static func namesMatch(_ a: String?, _ b: String) -> Bool {
        guard let a else { return false }
        return a.caseInsensitiveCompare(b) == .orderedSame
    }
}
