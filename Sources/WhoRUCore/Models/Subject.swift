import Foundation

public enum Confidence: String, Codable, Sendable, Comparable {
    case low, medium, high

    private var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rank < rhs.rank }
}

/// How the resolver arrived at a subject.
public struct ResolverOutcome: Codable, Sendable, Hashable {
    public var strategy: String
    public var confidence: Confidence

    public init(strategy: String, confidence: Confidence) {
        self.strategy = strategy
        self.confidence = confidence
    }
}

/// The file on disk that the dialog is really about, plus what we know about it.
public struct Subject: Codable, Sendable, Hashable {
    /// Absolute path of the executable or bundle that was resolved.
    public var path: String
    /// The process that triggered the prompt, when it is still running.
    public var pid: Int32?
    public var bundleID: String?
    /// Human-readable name (bundle display name or file name).
    public var displayName: String
    /// Version string from the bundle, when available.
    public var version: String?
    /// Path of the enclosing application bundle when `path` points inside one.
    public var bundlePath: String?
    public var resolver: ResolverOutcome

    public init(
        path: String,
        pid: Int32? = nil,
        bundleID: String? = nil,
        displayName: String? = nil,
        version: String? = nil,
        bundlePath: String? = nil,
        resolver: ResolverOutcome
    ) {
        self.path = path
        self.pid = pid
        self.bundleID = bundleID
        self.displayName = displayName ?? (path as NSString).lastPathComponent
        self.version = version
        self.bundlePath = bundlePath
        self.resolver = resolver
    }

    /// The path a check should verify: the bundle when there is one, else the file.
    public var verificationPath: String { bundlePath ?? path }
}

/// A candidate the resolver found but did not pick, kept so that name
/// collisions can be shown to the user.
public struct SubjectCandidate: Codable, Sendable, Hashable {
    public var path: String
    public var pid: Int32?
    public var strategy: String
    public var confidence: Confidence

    public init(path: String, pid: Int32? = nil, strategy: String, confidence: Confidence) {
        self.path = path
        self.pid = pid
        self.strategy = strategy
        self.confidence = confidence
    }
}
