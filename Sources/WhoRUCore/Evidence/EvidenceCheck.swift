import Foundation

/// What a check may need beyond the subject itself.
public struct CheckContext: Sendable {
    public var prompt: PermissionPrompt
    public var settings: Settings
    public var publishers: PublisherDirectory
    public var secrets: any SecretStore
    /// Earlier scans of the same publisher or hash, if the app has a store.
    public var history: HistorySummary?
    /// Per-check deadline.
    public var timeout: Duration

    public init(
        prompt: PermissionPrompt,
        settings: Settings = Settings(),
        publishers: PublisherDirectory = PublisherDirectory(),
        secrets: any SecretStore = InMemorySecretStore(),
        history: HistorySummary? = nil,
        timeout: Duration = .seconds(4)
    ) {
        self.prompt = prompt
        self.settings = settings
        self.publishers = publishers
        self.secrets = secrets
        self.history = history
        self.timeout = timeout
    }
}

/// One evidence check: a deterministic command or system API whose result is
/// normalized into an `EvidenceItem`. Implementations live in the platform
/// module; the core only orchestrates them.
public protocol EvidenceCheck: Sendable {
    var key: EvidenceKey { get }
    var weight: EvidenceWeight { get }
    /// Slow checks run after the fast ones are on screen.
    var isSlow: Bool { get }
    func run(on subject: Subject, context: CheckContext) async throws -> EvidenceItem
}

public extension EvidenceCheck {
    var isSlow: Bool { false }
}

/// A step that derives evidence from other evidence, after the checks ran:
/// publisher lookup from the signer's Team ID, impersonation from the name
/// versus the publisher, history from the store.
public protocol EvidenceDerivation: Sendable {
    func derive(from evidence: [EvidenceItem], subject: Subject, context: CheckContext) -> EvidenceItem?
}

/// Runs checks in parallel with a deadline each and streams results as they
/// arrive, then applies derivations.
public struct Collector: Sendable {
    public let checks: [any EvidenceCheck]
    public let derivations: [any EvidenceDerivation]

    public init(checks: [any EvidenceCheck], derivations: [any EvidenceDerivation] = Collector.standardDerivations) {
        self.checks = checks
        self.derivations = derivations
    }

    public static let standardDerivations: [any EvidenceDerivation] = [
        PublisherDerivation(),
        ImpersonationDerivation(),
        HistoryDerivation(),
    ]

    /// - Parameter onItem: called on an arbitrary task as each item completes.
    /// - Returns: all items in the canonical order of `checks`, derivations last.
    public func collect(
        subject: Subject,
        context: CheckContext,
        includeSlow: Bool = true,
        onItem: @escaping @Sendable (EvidenceItem) -> Void = { _ in }
    ) async -> [EvidenceItem] {
        let fast = checks.filter { !$0.isSlow }
        let slow = includeSlow ? checks.filter(\.isSlow) : []

        var items = await runBatch(fast, subject: subject, context: context, onItem: onItem)
        for derivation in derivations {
            if let item = derivation.derive(from: items, subject: subject, context: context) {
                items.append(item)
                onItem(item)
            }
        }
        if !slow.isEmpty {
            items += await runBatch(slow, subject: subject, context: context, onItem: onItem)
        }
        return items
    }

    private func runBatch(
        _ batch: [any EvidenceCheck],
        subject: Subject,
        context: CheckContext,
        onItem: @escaping @Sendable (EvidenceItem) -> Void
    ) async -> [EvidenceItem] {
        let order = Dictionary(uniqueKeysWithValues: batch.enumerated().map { ($0.element.key, $0.offset) })
        let results: [EvidenceItem] = await withTaskGroup(of: EvidenceItem.self) { group in
            for check in batch {
                group.addTask {
                    let started = Date()
                    let item: EvidenceItem
                    do {
                        item = try await withTimeout(context.timeout) {
                            try await check.run(on: subject, context: context)
                        }
                    } catch is TimeoutError {
                        item = .error(check.key, weight: check.weight, "did not finish in time", durationMs: Int(Date().timeIntervalSince(started) * 1000))
                    } catch {
                        item = .error(check.key, weight: check.weight, String(describing: error), durationMs: Int(Date().timeIntervalSince(started) * 1000))
                    }
                    onItem(item)
                    return item
                }
            }
            var collected: [EvidenceItem] = []
            for await item in group { collected.append(item) }
            return collected
        }
        return results.sorted { (order[$0.key] ?? .max) < (order[$1.key] ?? .max) }
    }
}
