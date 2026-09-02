import Foundation

/// One tool the model may call, with its implementation. Handlers receive the
/// validated input and the subject the scan is about; they never receive
/// arbitrary paths from the model.
public struct ToolHandler: Sendable {
    public var tool: AnalystTool
    public var run: @Sendable (_ input: JSONValue, _ subject: Subject?) async -> JSONValue

    public init(tool: AnalystTool, run: @escaping @Sendable (JSONValue, Subject?) async -> JSONValue) {
        self.tool = tool
        self.run = run
    }
}

/// The closed set of tools for one scan. The platform module registers its
/// handlers; the core supplies the network-based ones.
public struct ToolRegistry: AnalystToolRunner {
    public let subject: Subject?
    private let handlers: [String: ToolHandler]

    public init(subject: Subject?, handlers: [ToolHandler]) {
        self.subject = subject
        self.handlers = Dictionary(handlers.map { ($0.tool.name, $0) }, uniquingKeysWith: { _, last in last })
    }

    public var tools: [AnalystTool] { handlers.values.map(\.tool).sorted { $0.name < $1.name } }

    public func run(name: String, input: JSONValue) async -> JSONValue {
        guard let handler = handlers[name] else { return ["error": .string("unknown tool \(name)")] }
        return await handler.run(input, subject)
    }

    public func summary(forResult result: JSONValue, of name: String) -> String {
        if let error = result["error"]?.stringValue { return "\(name): \(error)" }
        if let summary = result["summary"]?.stringValue { return summary }
        return name
    }
}

/// Tools implemented in the core because they only need the network or the
/// publisher directory.
public enum CoreTools {
    public static func handlers(publishers: PublisherDirectory, secrets: any SecretStore, settings: Settings, evidence: [EvidenceItem]) -> [ToolHandler] {
        var list: [ToolHandler] = [
            ToolHandler(
                tool: AnalystTool(
                    name: "lookup_publisher",
                    description: "Look a Team ID up in the known-publisher directory. Returns the publisher name, trust level and the product names it is known for.",
                    inputSchema: ["type": "object", "properties": ["team_id": ["type": "string"]], "required": ["team_id"]]
                ),
                run: { input, _ in
                    guard let teamID = input["team_id"]?.stringValue, teamID.count <= 20 else { return ["error": "team_id required"] }
                    guard let publisher = publishers.lookup(teamID: teamID) else { return ["known": false, "summary": .string("\(teamID) is not a known publisher")] }
                    return ["known": true, "name": .string(publisher.name), "trust": .string(publisher.trust.rawValue), "products": .array(publisher.knownNames.map { .string($0) }), "summary": .string("\(teamID) is \(publisher.name)")]
                }
            ),
        ]
        if settings.virusTotalEnabled, let key = secrets.secret(.virusTotalAPIKey) {
            list.append(ToolHandler(
                tool: AnalystTool(
                    name: "virustotal_hash",
                    description: "Look a SHA-256 hash up on VirusTotal. Only the hash is sent. Returns detection counts.",
                    inputSchema: ["type": "object", "properties": ["sha256": ["type": "string"]], "required": ["sha256"]]
                ),
                run: { input, _ in
                    guard let sha = input["sha256"]?.stringValue, sha.count == 64 else { return ["error": "sha256 required"] }
                    // Only the subject's own hash may be looked up; the model cannot probe arbitrary hashes.
                    guard evidence.contains(where: { $0.facts[Fact.sha256] == sha }) else { return ["error": "only the subject's hash may be checked"] }
                    do {
                        let report = try await VirusTotal.lookup(sha256: sha, apiKey: key)
                        return ["found": .bool(report.found), "malicious": .number(Double(report.malicious)), "suspicious": .number(Double(report.suspicious)), "harmless": .number(Double(report.harmless)), "undetected": .number(Double(report.undetected)), "summary": .string(report.summary)]
                    } catch {
                        return ["error": .string(String(describing: error))]
                    }
                }
            ))
        }
        return list
    }
}
