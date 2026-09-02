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
        if settings.engine != .auto, settings.engine != .none, let explicit = explicitAnalyst(settings: settings, secrets: secrets) {
            return explicit
        }
        switch settings.engine {
        case .none:
            return nil
        case .local:
            return nil
        default:
            if let path = settings.claudeCodePath ?? ClaudeCodeAnalyst.locate(), await ClaudeCodeVerifier.isTrusted(path) {
                return ClaudeCodeAnalyst(executable: path, model: settings.model(for: .claudeCode))
            }
            if let key = secrets.secret(.anthropicAPIKey) {
                return ClaudeAPIAnalyst(apiKey: key, hardTimeout: .seconds(settings.hardTimeoutSeconds))
            }
            if let path = settings.codexPath ?? CodexAnalyst.locate() {
                return CodexAnalyst(executable: path, model: settings.model(for: .codex))
            }
            if let path = settings.geminiPath ?? GeminiAnalyst.locate() {
                return GeminiAnalyst(executable: path, model: settings.model(for: .gemini))
            }
            return nil
        }
    }

    private static func explicitAnalyst(settings: Settings, secrets: any SecretStore) -> (any Analyst)? {
        switch settings.engine {
        case .claudeAPI:
            return secrets.secret(.anthropicAPIKey).map { ClaudeAPIAnalyst(apiKey: $0, hardTimeout: .seconds(settings.hardTimeoutSeconds)) }
        case .claudeCode:
            return (settings.claudeCodePath ?? ClaudeCodeAnalyst.locate()).map { ClaudeCodeAnalyst(executable: $0, model: settings.model(for: .claudeCode)) }
        case .codex:
            return (settings.codexPath ?? CodexAnalyst.locate()).map { CodexAnalyst(executable: $0, model: settings.model(for: .codex)) }
        case .gemini:
            return (settings.geminiPath ?? GeminiAnalyst.locate()).map { GeminiAnalyst(executable: $0, model: settings.model(for: .gemini)) }
        case .local:
            return URL(string: settings.localModelURL).map { LocalModelAnalyst(baseURL: $0, model: settings.localModelName) }
        case .auto, .none:
            return nil
        }
    }

    public static func environment(settings: Settings, store: (any ScanStore)?, publishers: PublisherDirectory = PublisherDirectory(), locale: String = Locale.preferredLanguages.first ?? "en") async -> ScanEnvironment {
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
/// allowed to run on our behalf.
public enum ClaudeCodeVerifier {
    public static let expectedTeamID = "Q6L2SF6YDW"

    public static func isTrusted(_ path: String) async -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let info = await CodeSignature.inspect(path: resolved)
        return info.valid && info.kind == .developerID && info.teamID == expectedTeamID
    }
}
