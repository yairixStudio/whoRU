import Foundation

/// The process the platform itself held responsible for a permission request,
/// as read from its own record of the request (on macOS, `tccd`'s log). The
/// dialog is about this process, whatever the resolver guessed from the wording.
public struct AttributedIdentity: Sendable, Hashable {
    public var pid: Int32
    /// The executable that is running (the bundle's main binary for an app).
    public var binaryPath: String?
    /// The path the platform names as responsible when it differs from the
    /// binary: a command-line tool whose app wrapper is what actually runs.
    public var responsiblePath: String?
    /// Bundle identifier, or the executable path for a bare binary.
    public var identifier: String?

    public init(pid: Int32, binaryPath: String? = nil, responsiblePath: String? = nil, identifier: String? = nil) {
        self.pid = pid
        self.binaryPath = binaryPath
        self.responsiblePath = responsiblePath
        self.identifier = identifier
    }

    public var paths: [String] { [binaryPath, responsiblePath].compactMap { $0 } }
    /// The best path to build a subject from: what runs, else what was named.
    public var path: String? { binaryPath ?? responsiblePath }
}

/// What a platform found out about the code running as the attributed
/// process, compared with the file the evidence was collected from. Portable
/// on purpose: the core turns it into facts, the platform fills it.
public struct RunningCodeFacts: Sendable, Hashable {
    /// The running code passes the platform's dynamic validity check.
    public var valid: Bool
    /// The running code is the file on disk (same code directory hash); `nil`
    /// when one side could not be hashed.
    public var matchesDisk: Bool?
    public var cdhash: String?
    public var diskCdhash: String?
    public var path: String?
    /// `unsigned` when the file on disk carries no signature at all; such a
    /// file is already amber and must not become red for failing a check it
    /// cannot pass.
    public var error: String?

    public init(valid: Bool, matchesDisk: Bool? = nil, cdhash: String? = nil, diskCdhash: String? = nil, path: String? = nil, error: String? = nil) {
        self.valid = valid
        self.matchesDisk = matchesDisk
        self.cdhash = cdhash
        self.diskCdhash = diskCdhash
        self.path = path
        self.error = error
    }

    /// Whether the result says anything the score may act on.
    public var isConclusive: Bool { error != "unsigned" }
}

/// Reconciles a finished scan with the platform's own attribution of the
/// request. Pure: takes a record, returns what to do with it.
///
/// Three outcomes. The attribution names the scanned program: the record gains
/// hard evidence (identity, and running code when available), is re-scored and
/// gets a fresh headline. It names a different program: the caller must scan
/// that one instead, with the subject returned here. It is missing: nothing
/// changes, and the panel says so.
public enum IdentityConfirmation {
    public enum Outcome: Sendable {
        case confirmed(ScanRecord)
        case corrected(Subject)
        case unconfirmed
    }

    public static let verdictDroppedReason = "hard evidence changed after the verdict"
    public static let attributionStrategy = "system_attribution"

    public static func apply(to record: ScanRecord, attributed: AttributedIdentity?, running: RunningCodeFacts?, strictness: Strictness, locale: String) -> Outcome {
        guard let attributed else { return .unconfirmed }
        guard let subject = record.subject, names(subject, attributed: attributed) else {
            guard let path = attributed.path else { return .unconfirmed }
            return .corrected(subject(for: attributed, path: path))
        }

        var updated = record
        let shownPath = attributed.path ?? subject.path
        let identity = EvidenceItem(
            key: .identity, status: .pass, weight: .high,
            summary: "macOS attributes this request to \(shownPath) (pid \(attributed.pid))",
            raw: attributionRaw(attributed),
            method: "system log of the request (tccd)",
            facts: [Fact.identityConfirmed: "true", Fact.identityPID: String(attributed.pid)]
        )
        replace(identity, in: &updated.evidence)

        if let running, running.isConclusive {
            let matches = running.matchesDisk == true
            var facts = [Fact.runningValid: running.valid ? "true" : "false"]
            if let match = running.matchesDisk { facts[Fact.runningMatchesDisk] = match ? "true" : "false" }
            let summary: String
            if running.valid && matches {
                summary = "the running process is valid and is the file on disk"
            } else if !running.valid {
                summary = "the running process fails code-signature validation" + (running.error.map { ": \($0)" } ?? "")
            } else if running.matchesDisk == false {
                summary = "the running process is not the file on disk that was checked"
            } else {
                summary = "the running process could not be compared with the file on disk"
            }
            let raw = [
                "pid: \(attributed.pid)",
                "running path: \(running.path ?? "?")",
                "running cdhash: \(running.cdhash ?? "?")",
                "on-disk cdhash: \(running.diskCdhash ?? "?")",
            ].joined(separator: "\n")
            let runningItem = EvidenceItem(
                key: .runningCode, status: running.valid && matches ? .pass : .fail, weight: .critical,
                summary: summary, raw: raw, method: "SecCodeCheckValidity, SecCodeCopySigningInformation", facts: facts
            )
            replace(runningItem, in: &updated.evidence)
        }

        let hard = HardScoreEngine(strictness: strictness).score(updated.evidence, subject: subject, prompt: record.prompt, history: nil, candidates: record.candidates)
        updated.hardScore = hard
        updated.deterministicHeadline = HeadlineComposer().headline(for: hard, subject: subject, prompt: record.prompt, locale: locale)

        // The verdict was formed on the old evidence. Red is a floor the model
        // cannot lift, so a reassuring verdict cannot stand on it.
        if hard.score == .red, let verdict = updated.verdict,
           verdict.verdict == .legitimate || verdict.verdict == .probablyLegitimate || verdict.recommendation == .allow {
            updated.verdict = nil
            updated.verdictRejected = verdictDroppedReason
        }
        return .confirmed(updated)
    }

    /// Whether the attribution names the scanned program: the same bundle
    /// identifier, the same file, or a file inside the scanned bundle.
    public static func names(_ subject: Subject, attributed: AttributedIdentity) -> Bool {
        if let bundleID = subject.bundleID, let identifier = attributed.identifier,
           identifier.caseInsensitiveCompare(bundleID) == .orderedSame {
            return true
        }
        let roots = [subject.bundlePath, subject.path].compactMap { $0 }
        let named = attributed.paths + [attributed.identifier].compactMap { $0 }
        return named.contains { path in
            roots.contains { root in path == root || path.hasPrefix(root + "/") }
        }
    }

    /// A subject for the program the platform named, with what its bundle says about it.
    public static func subject(for attributed: AttributedIdentity, path: String) -> Subject {
        let bundle = BundleInfo.read(containing: path)
        return Subject(
            path: path, pid: attributed.pid,
            bundleID: bundle?.identifier ?? attributed.identifier.flatMap { $0.hasPrefix("/") ? nil : $0 },
            displayName: bundle?.displayName, version: bundle?.shortVersion, bundlePath: bundle?.bundlePath,
            resolver: ResolverOutcome(strategy: attributionStrategy, confidence: .high)
        )
    }

    private static func attributionRaw(_ attributed: AttributedIdentity) -> String {
        [
            "responsible pid: \(attributed.pid)",
            "identifier: \(attributed.identifier ?? "?")",
            "binary: \(attributed.binaryPath ?? "?")",
            "responsible path: \(attributed.responsiblePath ?? "-")",
        ].joined(separator: "\n")
    }

    private static func replace(_ item: EvidenceItem, in evidence: inout [EvidenceItem]) {
        if let index = evidence.firstIndex(where: { $0.key == item.key }) {
            evidence[index] = item
        } else {
            evidence.append(item)
        }
    }
}
