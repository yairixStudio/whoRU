import Foundation
import WhoRUCore

/// Assembles a `ScanEnvironment` with the macOS implementations.
public enum MacEnvironment {
    /// The standard check set, in authority order. Fast checks first; slow ones last.
    public static func checks() -> [any EvidenceCheck] {
        [
            SignerIdentityCheck(),
            SignatureIntegrityCheck(),
            GatekeeperCheck(),
            RevocationCheck(),
            Sha256Check(),
            OfficialManifestCheck(),
            DownloadOriginCheck(),
            LocationCheck(),
            ParentChainCheck(),
            PersistenceCheck(),
            DeclarationsCheck(),
            EntitlementsCheck(),
            TimestampsCheck(),
            NetworkConnectionsCheck(),
            VirusTotalCheck(),
        ]
    }

    public static func secrets() -> any SecretStore {
        LayeredSecretStore([KeychainSecretStore(), EnvironmentSecretStore()])
    }

    /// Picks the engine from settings and what is available on the machine.
    /// An explicit choice that is not available (key removed, tool
    /// uninstalled) falls back to automatic detection rather than to nothing.
    public static func analyst(settings: Settings, secrets: any SecretStore) async -> (any Analyst)? {
        // Local-only mode: nothing that talks to a server, whatever the engine setting says.
        if settings.localOnly {
            switch settings.engine {
            case .none: return nil
            case .local: return await explicitAnalyst(settings: settings, secrets: secrets)
            default: return AppleFoundationAnalyst.isAvailable ? AppleFoundationAnalyst() : nil
            }
        }
        if settings.engine != .auto, settings.engine != .none, let explicit = await explicitAnalyst(settings: settings, secrets: secrets) {
            return explicit
        }
        switch settings.engine {
        case .none:
            return nil
        case .local:
            return nil
        case .appleIntelligence:
            // Chosen explicitly but unavailable right now (model downloading): do not silently switch to a cloud agent.
            return nil
        default:
            // Agents first: they need no key. An API key is used only if it was set up on the command line.
            if let path = settings.claudeCodePath ?? ClaudeCodeAnalyst.locate(), await ClaudeCodeVerifier.isTrusted(path) {
                return ClaudeCodeAnalyst(executable: path, model: settings.model(for: .claudeCode))
            }
            if let path = settings.codexPath ?? CodexAnalyst.locate() {
                return CodexAnalyst(executable: path, model: settings.model(for: .codex))
            }
            if let path = settings.geminiPath ?? GeminiAnalyst.locate() {
                return GeminiAnalyst(executable: path, model: settings.model(for: .gemini))
            }
            if AppleFoundationAnalyst.isAvailable {
                return AppleFoundationAnalyst()
            }
            if let key = secrets.secret(.anthropicAPIKey) {
                return ClaudeAPIAnalyst(apiKey: key, hardTimeout: .seconds(settings.hardTimeoutSeconds))
            }
            return nil
        }
    }

    private static func explicitAnalyst(settings: Settings, secrets: any SecretStore) async -> (any Analyst)? {
        switch settings.engine {
        case .claudeAPI:
            return secrets.secret(.anthropicAPIKey).map { ClaudeAPIAnalyst(apiKey: $0, hardTimeout: .seconds(settings.hardTimeoutSeconds)) }
        case .claudeCode:
            // An explicit choice is verified like the automatic one: the path
            // is user-writable and a swapped binary would run with the user's
            // sign-in. Failing verification means no agent, not a fallback.
            guard let path = settings.claudeCodePath ?? ClaudeCodeAnalyst.locate() else { return nil }
            guard await ClaudeCodeVerifier.isTrusted(path) else {
                AppLog.shared.error("engine", "Claude Code at \(path) failed signature verification; not running it")
                return nil
            }
            return ClaudeCodeAnalyst(executable: path, model: settings.model(for: .claudeCode))
        // Codex and Gemini are Node scripts and cannot be signature-verified;
        // they are protected by running disclaimed, with no tools (CLIAgent).
        case .codex:
            return (settings.codexPath ?? CodexAnalyst.locate()).map { CodexAnalyst(executable: $0, model: settings.model(for: .codex)) }
        case .gemini:
            return (settings.geminiPath ?? GeminiAnalyst.locate()).map { GeminiAnalyst(executable: $0, model: settings.model(for: .gemini)) }
        case .appleIntelligence:
            return AppleFoundationAnalyst.isAvailable ? AppleFoundationAnalyst() : nil
        case .local:
            return URL(string: settings.localModelURL).map { LocalModelAnalyst(baseURL: $0, model: settings.localModelName) }
        case .auto, .none:
            return nil
        }
    }

    /// `engine` overrides the setting for one environment: a request the user
    /// makes by hand ("Ask AI" in the panel) names the agent it wants, whatever
    /// the automatic choice is. Local-only mode still applies.
    public static func environment(settings base: Settings, store: (any ScanStore)?, publishers: PublisherDirectory = PublisherDirectory(), locale: String = Locale.preferredLanguages.first ?? "en", engine: EngineChoice? = nil) async -> ScanEnvironment {
        let settings: Settings = {
            var adjusted = base
            if let engine { adjusted.engine = engine }
            return adjusted
        }()
        let secrets = secrets()
        let processes = MacProcessInspector()
        let analyst = await analyst(settings: settings, secrets: secrets)
        return ScanEnvironment(
            resolver: RequesterResolver(processes: processes, finder: MacApplicationFinder()),
            collector: Collector(checks: checks()),
            analyst: analyst,
            toolHandlers: { _, evidence in
                MacTools.handlers(processes: processes) + CoreTools.handlers(publishers: publishers, secrets: secrets, settings: settings, evidence: evidence)
            },
            store: store,
            settings: settings,
            publishers: publishers,
            secrets: secrets,
            paths: DefaultPaths(),
            locale: locale
        )
    }
}

/// The Claude Code binary gets the same scrutiny as anything else before it is
/// allowed to run on our behalf: a valid Developer ID signature from
/// Anthropic's team, with the hardened runtime the genuine builds ship with
/// (checked against 2.1.259, `flags=0x10000(runtime)`), so that a binary
/// with the right certificate but injected code does not pass either.
public enum ClaudeCodeVerifier {
    public static let expectedTeamID = "Q6L2SF6YDW"

    public static func isTrusted(_ path: String) async -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let info = await CodeSignature.inspect(path: resolved)
        return info.valid && info.kind == .developerID && info.teamID == expectedTeamID && info.hardenedRuntime
    }
}
