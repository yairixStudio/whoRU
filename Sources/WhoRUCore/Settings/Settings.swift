import Foundation

public enum EngineChoice: String, Codable, Sendable, CaseIterable {
    /// Whatever is present: Claude Code, Codex, Gemini, Apple's on-device model, an API key, else none.
    case auto
    case claudeAPI
    case claudeCode
    case codex
    case gemini
    /// Apple's on-device foundation model (Apple Intelligence). Never leaves the Mac.
    case appleIntelligence
    case local
    case none

    public var displayName: String {
        switch self {
        case .auto: "Automatic"
        case .claudeAPI: "Claude API"
        case .claudeCode: "Claude Code"
        case .codex: "Codex CLI"
        case .gemini: "Gemini CLI"
        case .appleIntelligence: "Apple Intelligence"
        case .local: "Local model"
        case .none: "None"
        }
    }

    /// Models offered in the picker. The first one is what a fresh choice of
    /// this agent uses; there is no unnamed default.
    public var suggestedModels: [String] {
        switch self {
        case .claudeCode: ["claude-opus-5", "claude-fable-5-1", "claude-sonnet-5", "claude-haiku-4-5"]
        case .codex: ["gpt-5-codex", "gpt-5"]
        case .gemini: ["gemini-2.5-pro", "gemini-2.5-flash"]
        case .appleIntelligence: ["on-device"]
        default: []
        }
    }

    public var defaultModel: String { suggestedModels.first ?? "" }

    /// Human name for a model id in the picker.
    public func modelDisplayName(_ id: String) -> String {
        switch id {
        case "claude-fable-5-1": "Claude Fable 5.1"
        case "claude-opus-5": "Claude Opus 5"
        case "claude-sonnet-5": "Claude Sonnet 5"
        case "claude-haiku-4-5": "Claude Haiku 4.5"
        case "gpt-5-codex": "GPT-5 Codex"
        case "gpt-5": "GPT-5"
        case "gemini-2.5-pro": "Gemini 2.5 Pro"
        case "gemini-2.5-flash": "Gemini 2.5 Flash"
        case "on-device": "On-device model"
        default: id
        }
    }

    /// Engines that run entirely on this Mac and are allowed in local-only mode.
    public var isOnDevice: Bool { self == .appleIntelligence || self == .local }

    /// The `Analyst.id` this engine produces, so a stored conversation can be
    /// matched with the engine that can continue it.
    public var analystID: String? {
        switch self {
        case .claudeAPI: "claude-api"
        case .claudeCode: "claude-code"
        case .codex: "codex"
        case .gemini: "gemini"
        case .appleIntelligence: "apple"
        case .local: "local"
        case .auto, .none: nil
        }
    }

    public init?(analystID: String) {
        guard let match = Self.allCases.first(where: { $0.analystID == analystID }) else { return nil }
        self = match
    }

    /// Where to get the tool. The minimum: a page and a one-line install.
    public var installURL: URL? {
        switch self {
        case .claudeCode: URL(string: "https://docs.claude.com/en/docs/claude-code/quickstart")
        case .codex: URL(string: "https://github.com/openai/codex")
        case .gemini: URL(string: "https://github.com/google-gemini/gemini-cli")
        default: nil
        }
    }

    public var installCommand: String? {
        switch self {
        case .claudeCode: "curl -fsSL https://claude.ai/install.sh | bash"
        case .codex: "brew install codex"
        case .gemini: "brew install gemini-cli"
        default: nil
        }
    }

    /// How to sign in once the tool is installed. Interactive, so it runs in Terminal.
    public var loginCommand: String? {
        switch self {
        case .claudeCode: "claude auth login"
        case .codex: "codex login"
        case .gemini: "gemini"
        default: nil
        }
    }

    /// A script that runs the sign-in flow in Terminal and says what to do after.
    public var loginScript: String? {
        guard let command = loginCommand, let url = installURL?.absoluteString else { return nil }
        return """
        #!/bin/sh
        # whoRU: sign in to \(displayName)
        printf '\\n\\033[1mwhoRU → signing in to \(displayName)\\033[0m\\n'
        printf 'Follow the prompts. If this fails, see: \(url)\\n\\n'
        \(command)
        printf '\\n\\033[1mDone.\\033[0m Back in whoRU, \(displayName) should now show as signed in. You can close this window.\\n'
        """
    }

    /// A complete shell script that installs the tool the most reliable way
    /// available on the machine, and says where to look if it fails. The app
    /// runs it in Terminal so the user sees exactly what happens.
    public var installScript: String? {
        guard let url = installURL?.absoluteString else { return nil }
        let name = displayName
        let header = """
        #!/bin/sh
        # whoRU: install \(name)
        # If this does not work, see \(url)
        printf '\\n\\033[1mwhoRU → installing \(name)\\033[0m\\n'
        printf 'If this fails, see: \(url)\\n\\n'

        """
        let footer = """

        status=$?
        printf '\\n'
        if [ $status -eq 0 ]; then
          printf '\\033[1mDone.\\033[0m Back in whoRU, pick \(name) (or Automatic) under Settings → AI.\\n'
        else
          printf '\\033[1mThe install did not finish (exit %s).\\033[0m See \(url)\\n' "$status"
        fi
        printf 'You can close this window.\\n'
        """
        switch self {
        case .claudeCode:
            return header + "curl -fsSL https://claude.ai/install.sh | bash" + footer
        case .codex:
            return header + """
            if command -v brew >/dev/null 2>&1; then
              brew install codex
            elif command -v npm >/dev/null 2>&1; then
              npm install -g @openai/codex
            else
              printf 'Neither Homebrew nor Node.js is installed. Install Homebrew from https://brew.sh and run this again.\\n'; false
            fi
            """ + footer
        case .gemini:
            return header + """
            if command -v brew >/dev/null 2>&1; then
              brew install gemini-cli
            elif command -v npm >/dev/null 2>&1; then
              npm install -g @google/gemini-cli
            else
              printf 'Neither Homebrew nor Node.js is installed. Install Homebrew from https://brew.sh and run this again.\\n'; false
            fi
            """ + footer
        default:
            return nil
        }
    }

    public static let agents: [EngineChoice] = [.claudeCode, .codex, .gemini, .appleIntelligence]

    /// Engines that are installed as command-line tools.
    public static let commandLineAgents: [EngineChoice] = [.claudeCode, .codex, .gemini]
}

/// How hard the evidence has to work before something is green.
public enum Strictness: String, Codable, Sendable, CaseIterable {
    /// Known publishers are green even when notarization cannot be checked (command-line tools).
    case standard
    /// Green needs notarization or an official-source match; unknown origin or a
    /// sensitive permission without notarization stays amber.
    case strict
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

    public var strictness: Strictness = .standard

    // AI
    public var engine: EngineChoice = .auto
    public var depth: AnalysisDepth = .balanced
    public var monthlyBudgetUSD: Double = 5
    public var allowWebSearch = false
    /// Resolved path of the Claude Code binary, when detected or set.
    public var claudeCodePath: String? = nil
    public var codexPath: String? = nil
    public var geminiPath: String? = nil
    /// Model per command-line engine, keyed by `EngineChoice.rawValue`. Empty = the CLI's default.
    public var engineModels: [String: String] = [:]
    public var localModelURL: String = "http://localhost:11434"
    public var localModelName: String = "llama3"

    /// The chosen model for an engine, or that engine's first suggestion.
    public func model(for engine: EngineChoice) -> String {
        let chosen = engineModels[engine.rawValue] ?? ""
        return chosen.isEmpty || chosen == "custom" ? engine.defaultModel : chosen
    }

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

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        showNextToDialogs = try c.decodeIfPresent(Bool.self, forKey: .showNextToDialogs) ?? d.showNextToDialogs
        askModelAutomatically = try c.decodeIfPresent(Bool.self, forKey: .askModelAutomatically) ?? d.askModelAutomatically
        enabledServices = try c.decodeIfPresent(Set<PermissionService>.self, forKey: .enabledServices)
        strictness = try c.decodeIfPresent(Strictness.self, forKey: .strictness) ?? d.strictness
        engine = try c.decodeIfPresent(EngineChoice.self, forKey: .engine) ?? d.engine
        depth = try c.decodeIfPresent(AnalysisDepth.self, forKey: .depth) ?? d.depth
        monthlyBudgetUSD = try c.decodeIfPresent(Double.self, forKey: .monthlyBudgetUSD) ?? d.monthlyBudgetUSD
        allowWebSearch = try c.decodeIfPresent(Bool.self, forKey: .allowWebSearch) ?? d.allowWebSearch
        claudeCodePath = try c.decodeIfPresent(String.self, forKey: .claudeCodePath)
        codexPath = try c.decodeIfPresent(String.self, forKey: .codexPath)
        geminiPath = try c.decodeIfPresent(String.self, forKey: .geminiPath)
        engineModels = try c.decodeIfPresent([String: String].self, forKey: .engineModels) ?? d.engineModels
        localModelURL = try c.decodeIfPresent(String.self, forKey: .localModelURL) ?? d.localModelURL
        localModelName = try c.decodeIfPresent(String.self, forKey: .localModelName) ?? d.localModelName
        localOnly = try c.decodeIfPresent(Bool.self, forKey: .localOnly) ?? d.localOnly
        virusTotalEnabled = try c.decodeIfPresent(Bool.self, forKey: .virusTotalEnabled) ?? d.virusTotalEnabled
        historyRetentionDays = try c.decodeIfPresent(Int.self, forKey: .historyRetentionDays) ?? d.historyRetentionDays
        debugPanel = try c.decodeIfPresent(Bool.self, forKey: .debugPanel) ?? d.debugPanel
        onboardingCompleted = try c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? d.onboardingCompleted
        maxToolCalls = try c.decodeIfPresent(Int.self, forKey: .maxToolCalls) ?? d.maxToolCalls
        softTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .softTimeoutSeconds) ?? d.softTimeoutSeconds
        hardTimeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .hardTimeoutSeconds) ?? d.hardTimeoutSeconds
        verdictCacheDays = try c.decodeIfPresent(Int.self, forKey: .verdictCacheDays) ?? d.verdictCacheDays
    }

    static func merging(defaults: Settings, with data: Data) -> Settings {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Settings.self, from: data)) ?? defaults
    }

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
        // Fields added after a file was written decode with their defaults.
        return (try? decoder.decode(Settings.self, from: data)) ?? Settings.merging(defaults: Settings(), with: data)
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
