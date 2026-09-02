import Foundation

public enum UserDecision: String, Codable, Sendable, Hashable {
    case allowed, denied, unknown
}

public struct ChatMessage: Codable, Sendable, Hashable, Identifiable {
    public enum Role: String, Codable, Sendable { case user, assistant, tool }
    public var id: UUID
    public var role: Role
    public var text: String
    public var createdAt: Date
    /// Tool calls the assistant made while producing this message, for display.
    public var toolCalls: [String]

    public init(id: UUID = UUID(), role: Role, text: String, createdAt: Date = Date(), toolCalls: [String] = []) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.toolCalls = toolCalls
    }
}

/// Everything about one scan, as persisted. One JSON file each.
public struct ScanRecord: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var startedAt: Date
    public var finishedAt: Date?
    public var prompt: PermissionPrompt
    public var subject: Subject?
    public var candidates: [SubjectCandidate]
    public var evidence: [EvidenceItem]
    public var hardScore: HardScoreResult?
    public var deterministicHeadline: Headline?
    public var verdict: Verdict?
    public var verdictRejected: String?
    public var engine: String?
    public var model: String?
    public var userDecision: UserDecision
    public var inputTokens: Int
    public var outputTokens: Int
    public var costUSD: Double
    public var messages: [ChatMessage]
    /// Opaque provider state to continue the conversation.
    public var analystSession: AnalystSession?
    /// Whether the verdict came from the cache rather than a fresh model call.
    public var fromCache: Bool

    public init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        prompt: PermissionPrompt,
        subject: Subject? = nil,
        candidates: [SubjectCandidate] = [],
        evidence: [EvidenceItem] = [],
        hardScore: HardScoreResult? = nil,
        deterministicHeadline: Headline? = nil,
        verdict: Verdict? = nil,
        engine: String? = nil,
        model: String? = nil,
        userDecision: UserDecision = .unknown
    ) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = nil
        self.prompt = prompt
        self.subject = subject
        self.candidates = candidates
        self.evidence = evidence
        self.hardScore = hardScore
        self.deterministicHeadline = deterministicHeadline
        self.verdict = verdict
        self.verdictRejected = nil
        self.engine = engine
        self.model = model
        self.userDecision = userDecision
        self.inputTokens = 0
        self.outputTokens = 0
        self.costUSD = 0
        self.messages = []
        self.analystSession = nil
        self.fromCache = false
    }

    public var sha256: String? { evidence.first { $0.key == .sha256 }?.facts[Fact.sha256] }
    public var teamID: String? { evidence.first { $0.key == .signerIdentity }?.facts[Fact.signerTeamID] }

    /// The best headline available: the model's if accepted, else the deterministic one.
    public var bestHeadline: Headline? {
        if let verdict {
            return Headline(title: VerdictPresentation.forVerdict(verdict.verdict, locale: prompt.locale).title, sentence: verdict.headline, source: engine ?? "model")
        }
        return deterministicHeadline
    }
}

public struct AnalystSession: Codable, Sendable, Hashable {
    public var engine: String
    public var model: String
    public var payload: JSONValue

    public init(engine: String, model: String, payload: JSONValue) {
        self.engine = engine
        self.model = model
        self.payload = payload
    }
}

public protocol ScanStore: Sendable {
    func save(_ record: ScanRecord) async throws
    func load(id: UUID) async throws -> ScanRecord?
    func all() async throws -> [ScanRecord]
    func delete(id: UUID) async throws
    func purge(olderThan days: Int) async throws
    /// The most recent completed scan of the same file for the same permission.
    func cachedVerdict(sha256: String, service: PermissionService, within days: Int) async throws -> ScanRecord?
    func history(teamID: String?, sha256: String?) async throws -> HistorySummary
    func monthlySpend() async throws -> Double
}

/// One pretty-printed JSON file per scan under `<app support>/scans/`, with an
/// in-memory index. Simple, inspectable, portable. A SQLite store behind the
/// same protocol is welcome.
public actor JSONFileScanStore: ScanStore {
    public nonisolated let directory: URL
    private var index: [UUID: ScanRecord] = [:]
    private var loaded = false

    public init(paths: Paths) {
        directory = paths.applicationSupport.appendingPathComponent("scans", isDirectory: true)
    }

    public init(directory: URL) {
        self.directory = directory
    }

    private func ensureLoaded() throws {
        guard !loaded else { return }
        loaded = true
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = Self.decoder
        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file), let record = try? decoder.decode(ScanRecord.self, from: data) {
                index[record.id] = record
            }
        }
    }

    public func save(_ record: ScanRecord) async throws {
        try ensureLoaded()
        index[record.id] = record
        let data = try Self.encoder.encode(record)
        try data.write(to: fileURL(for: record.id), options: .atomic)
    }

    public func load(id: UUID) async throws -> ScanRecord? {
        try ensureLoaded()
        return index[id]
    }

    public func all() async throws -> [ScanRecord] {
        try ensureLoaded()
        return index.values.sorted { $0.startedAt > $1.startedAt }
    }

    public func delete(id: UUID) async throws {
        try ensureLoaded()
        index[id] = nil
        try? FileManager.default.removeItem(at: fileURL(for: id))
    }

    public func purge(olderThan days: Int) async throws {
        try ensureLoaded()
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        for record in index.values where record.startedAt < cutoff {
            try await delete(id: record.id)
        }
    }

    public func cachedVerdict(sha256: String, service: PermissionService, within days: Int) async throws -> ScanRecord? {
        try ensureLoaded()
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        return index.values
            .filter { $0.verdict != nil && $0.sha256 == sha256 && $0.prompt.service == service && $0.startedAt >= cutoff && !$0.fromCache }
            .max { $0.startedAt < $1.startedAt }
    }

    public func history(teamID: String?, sha256: String?) async throws -> HistorySummary {
        try ensureLoaded()
        let matches = index.values.filter { record in
            (teamID != nil && record.teamID == teamID) || (sha256 != nil && record.sha256 == sha256)
        }
        var summary = HistorySummary(timesSeen: matches.count)
        summary.timesAllowed = matches.filter { $0.userDecision == .allowed }.count
        summary.timesDenied = matches.filter { $0.userDecision == .denied }.count
        if let last = matches.max(by: { $0.startedAt < $1.startedAt }) {
            summary.lastSeen = last.startedAt
            summary.lastVerdict = last.verdict?.verdict
        }
        return summary
    }

    public func monthlySpend() async throws -> Double {
        try ensureLoaded()
        let calendar = Calendar.current
        let now = Date()
        return index.values
            .filter { calendar.isDate($0.startedAt, equalTo: now, toGranularity: .month) }
            .reduce(0) { $0 + $1.costUSD }
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
