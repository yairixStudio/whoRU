import Foundation

public enum EngineChoice: String, Codable, Sendable, CaseIterable {
    /// Pick at first run: Claude Code if installed and verified, else an API key, else none.
    case auto
    case claudeAPI
    case claudeCode
    case local
    case none
}

public enum AnalysisDepth: String, Codable, Sendable, CaseIterable {
    case fast, balanced, deep

    public var modelID: String {
        switch self {
        case .fast: "claude-sonnet-5"
        case .balanced: "claude-opus-5"
        case .deep: "claude-fable-5-1"
        }
    }

    public var effort: String {
        switch self {
        case .fast: "low"
        case .balanced: "medium"
        case .deep: "high"
        }
    }
}

/// Every user-facing setting. Everything not here is a fixed default on
/// purpose; see docs/DESIGN.md §14.
public struct Settings: Codable, Sendable, Hashable {
    // General
    public var launchAtLogin = true
    public var showNextToDialogs = true
    public var askModelAutomatically = true
    /// `nil` means all services.
    public var enabledServices: Set<PermissionService>? = nil

    // AI
    public var engine: EngineChoice = .auto
    public var depth: AnalysisDepth = .balanced
    public var monthlyBudgetUSD: Double = 5
    public var allowWebSearch = false
    /// Resolved path of the Claude Code binary, when detected or set.
    public var claudeCodePath: String? = nil
    public var localModelURL: String = "http://localhost:11434"
    public var localModelName: String = "llama3"

    // Privacy
    public var localOnly = false
    public var virusTotalEnabled = false

    // Advanced
    public var historyRetentionDays = 90
    public var debugPanel = false
    /// Set once onboarding completed, so it is not shown again.
    public var onboardingCompleted = false

    // Fixed defaults (not exposed in the UI, but adjustable via import).
    public var maxToolCalls = 8
    public var softTimeoutSeconds = 20
    public var hardTimeoutSeconds = 45
    public var verdictCacheDays = 30

    public init() {}

    public func isEnabled(_ service: PermissionService) -> Bool {
        enabledServices?.contains(service) ?? true
    }
}

/// Where the app keeps its files. A port supplies its own.
public protocol Paths: Sendable {
    var applicationSupport: URL { get }
    var homeDirectory: String { get }
}

public struct DefaultPaths: Paths {
    public let applicationSupport: URL
    public let homeDirectory: String

    public init(appName: String = "whoRU") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".whoru")
        applicationSupport = base.appendingPathComponent(appName, isDirectory: true)
        homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    }

    public init(applicationSupport: URL, homeDirectory: String) {
        self.applicationSupport = applicationSupport
        self.homeDirectory = homeDirectory
    }
}

public protocol SettingsStore: Sendable {
    func load() throws -> Settings
    func save(_ settings: Settings) throws
}

public struct JSONFileSettingsStore: SettingsStore {
    public let url: URL

    public init(paths: Paths) {
        url = paths.applicationSupport.appendingPathComponent("settings.json")
    }

    public func load() throws -> Settings {
        guard FileManager.default.fileExists(atPath: url.path) else { return Settings() }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Settings.self, from: data)
    }

    public func save(_ settings: Settings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}

/// Secrets never go in settings files. macOS uses the Keychain; tests and the
/// command line use the environment or memory.
public protocol SecretStore: Sendable {
    func secret(_ key: SecretKey) -> String?
    func setSecret(_ value: String?, for key: SecretKey) throws
}

public enum SecretKey: String, Sendable, CaseIterable {
    case anthropicAPIKey = "anthropic-api-key"
    case virusTotalAPIKey = "virustotal-api-key"

    public var environmentVariable: String {
        switch self {
        case .anthropicAPIKey: "ANTHROPIC_API_KEY"
        case .virusTotalAPIKey: "VIRUSTOTAL_API_KEY"
        }
    }
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private var values: [SecretKey: String]
    private let lock = NSLock()

    public init(_ values: [SecretKey: String] = [:]) { self.values = values }

    public func secret(_ key: SecretKey) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[key]
    }

    public func setSecret(_ value: String?, for key: SecretKey) throws {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }
}

/// Reads secrets from environment variables; writes are not supported.
public struct EnvironmentSecretStore: SecretStore {
    public init() {}

    public func secret(_ key: SecretKey) -> String? {
        let value = ProcessInfo.processInfo.environment[key.environmentVariable]
        return (value?.isEmpty ?? true) ? nil : value
    }

    public func setSecret(_ value: String?, for key: SecretKey) throws {
        throw CommandError("environment secrets are read-only")
    }
}

/// Tries each store in order for reads; writes go to the first one.
public struct LayeredSecretStore: SecretStore {
    public let layers: [any SecretStore]
    public init(_ layers: [any SecretStore]) { self.layers = layers }

    public func secret(_ key: SecretKey) -> String? {
        for layer in layers {
            if let v = layer.secret(key) { return v }
        }
        return nil
    }

    public func setSecret(_ value: String?, for key: SecretKey) throws {
        guard let first = layers.first else { return }
        try first.setSecret(value, for: key)
    }
}
