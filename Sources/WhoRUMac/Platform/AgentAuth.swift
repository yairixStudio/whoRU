import Foundation
import WhoRUCore

/// Whether an installed agent can actually be used: signed in, or given a key.
/// Heuristics per tool, kept cheap; `nil` means unknown.
public enum AgentAuth {
    public static func isSignedIn(_ engine: EngineChoice, executable: String?) async -> Bool? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let env = ProcessInfo.processInfo.environment
        switch engine {
        case .claudeCode:
            if let key = env["ANTHROPIC_API_KEY"], !key.isEmpty { return true }
            guard let executable else { return nil }
            // `claude auth status` prints JSON with "loggedIn".
            if let output = try? await Command.run(executable, ["auth", "status"], timeout: .seconds(15), environment: CLIAgentEnvironment.value) {
                let text = (output.stdout + output.stderr).lowercased().replacingOccurrences(of: " ", with: "")
                if text.contains("\"loggedin\":false") || text.contains("notloggedin") || text.contains("notauthenticated") { return false }
                if text.contains("\"loggedin\":true") { return true }
                return output.status == 0
            }
            return nil
        case .codex:
            if let key = env["OPENAI_API_KEY"], !key.isEmpty { return true }
            if let executable, let output = try? await Command.run(executable, ["login", "status"], timeout: .seconds(15), environment: CLIAgentEnvironment.value) {
                let text = (output.stdout + output.stderr).lowercased()
                if text.contains("not logged in") { return false }
                if text.contains("logged in") { return true }
            }
            return FileManager.default.fileExists(atPath: "\(home)/.codex/auth.json")
        case .gemini:
            if let key = env["GEMINI_API_KEY"] ?? env["GOOGLE_API_KEY"], !key.isEmpty { return true }
            return FileManager.default.fileExists(atPath: "\(home)/.gemini/oauth_creds.json")
        default:
            return nil
        }
    }
}

/// The environment for child agents: no nesting markers, plain output.
enum CLIAgentEnvironment {
    static var value: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["CLAUDECODE"] = nil
        env["CLAUDE_CODE_ENTRYPOINT"] = nil
        env["NO_COLOR"] = "1"
        return env
    }
}
