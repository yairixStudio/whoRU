import Foundation

/// Builds the deterministic headline shown as soon as the hard score is known.
/// No model involved: a title of two to four words and one sentence from a
/// template, in the interface language.
public struct HeadlineComposer: Sendable {
    public init() {}

    public func headline(for result: HardScoreResult, subject: Subject?, prompt: PermissionPrompt, locale: String, history: HistorySummary? = nil, now: Date = Date()) -> Headline {
        let name = subject?.displayName ?? prompt.requesterName
        let first = result.reasons.first
        var params = first?.params ?? [:]
        // A reason may carry its own name (the impersonated one); the subject's name is the fallback.
        params["name"] = params["name"] ?? name

        let title: String
        var sentence: String
        defer { _ = sentence }
        switch result.score {
        case .red:
            title = L10n.text("headline.doNotAllow", locale: locale)
            sentence = L10n.text("reason.\(first?.code ?? "signature.broken")", locale: locale, params)
        case .green:
            if result.isSystemComponent {
                title = L10n.text("headline.systemComponent", locale: locale)
                sentence = L10n.text("reason.signed.apple", locale: locale, params)
            } else if result.matchesOfficialSource {
                title = L10n.text("headline.safe", locale: locale)
                sentence = L10n.text("reason.manifest.match", locale: locale, params)
            } else {
                title = L10n.text("headline.probablyFine", locale: locale)
                sentence = L10n.text("reason.\(first?.code ?? "signed.notarized")", locale: locale, params)
            }
        case .amber:
            if first?.code == "unresolved" {
                title = L10n.text("headline.unresolved", locale: locale)
                sentence = L10n.text("reason.unresolved", locale: locale, params)
            } else {
                title = L10n.text("headline.worthALook", locale: locale)
                sentence = L10n.text("reason.\(first?.code ?? "signer.unknown")", locale: locale, params)
            }
        }
        if let history, let clause = Self.historyClause(history, locale: locale, now: now) {
            sentence += " " + clause
        }
        return Headline(title: title, sentence: sentence, source: "deterministic")
    }

    /// One sentence about earlier scans: this exact file first, else the publisher.
    public static func historyClause(_ history: HistorySummary, locale: String, now: Date = Date()) -> String? {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: locale)
        formatter.unitsStyle = .full
        func when(_ date: Date?) -> String {
            guard let date else { return "" }
            if now.timeIntervalSince(date) < 120 { return L10n.text("history.justNow", locale: locale) }
            return formatter.localizedString(for: date, relativeTo: now)
        }
        if history.sameFileTimes > 0 {
            var params: [String: String] = ["n": String(history.sameFileTimes), "when": when(history.sameFileLastSeen)]
            let verdictKey: String
            switch history.sameFileLastVerdict {
            case .legitimate, .probablyLegitimate: verdictKey = "history.verdict.fine"
            case .suspicious, .malicious: verdictKey = "history.verdict.flagged"
            default: verdictKey = "history.verdict.unknown"
            }
            params["verdict"] = L10n.text(verdictKey, locale: locale)
            var text = L10n.text(history.sameFileTimes == 1 ? "history.sameFile.once" : "history.sameFile.many", locale: locale, params)
            if let decision = history.sameFileLastDecision {
                text += " " + L10n.text(decision == .allowed ? "history.decision.allowed" : "history.decision.denied", locale: locale)
            }
            return text
        }
        if history.timesSeen > 0, let publisher = history.publisherName {
            var params: [String: String] = ["n": String(history.timesSeen), "publisher": publisher]
            params["when"] = when(history.lastSeen)
            return L10n.text(history.timesSeen == 1 ? "history.publisher.once" : "history.publisher.many", locale: locale, params)
        }
        return nil
    }
}

/// How a verdict is presented: the user-facing title, the SF Symbol name and
/// the semantic color. Kept in the core so every front end says the same thing.
public struct VerdictPresentation: Sendable, Hashable {
    public var title: String
    public var symbol: String
    /// `green` | `orange` | `red` | `secondary` | `accent`
    public var color: String

    public static func forVerdict(_ kind: VerdictKind, locale: String) -> VerdictPresentation {
        switch kind {
        case .legitimate:
            VerdictPresentation(title: L10n.text("headline.safe", locale: locale), symbol: "checkmark.seal.fill", color: "green")
        case .probablyLegitimate:
            VerdictPresentation(title: L10n.text("headline.probablyFine", locale: locale), symbol: "checkmark.circle", color: "green")
        case .suspicious:
            VerdictPresentation(title: L10n.text("headline.worthALook", locale: locale), symbol: "exclamationmark.triangle.fill", color: "orange")
        case .malicious:
            VerdictPresentation(title: L10n.text("headline.doNotAllow", locale: locale), symbol: "xmark.shield.fill", color: "red")
        case .unknown:
            VerdictPresentation(title: L10n.text("headline.unresolved", locale: locale), symbol: "questionmark.app.dashed", color: "secondary")
        }
    }

    public static func forHardScore(_ result: HardScoreResult, locale: String) -> VerdictPresentation {
        switch result.score {
        case .green:
            if result.isSystemComponent {
                return VerdictPresentation(title: L10n.text("headline.systemComponent", locale: locale), symbol: "apple.logo", color: "secondary")
            }
            return result.matchesOfficialSource
                ? forVerdict(.legitimate, locale: locale)
                : forVerdict(.probablyLegitimate, locale: locale)
        case .amber:
            return result.reasons.first?.code == "unresolved"
                ? forVerdict(.unknown, locale: locale)
                : forVerdict(.suspicious, locale: locale)
        case .red:
            return forVerdict(.malicious, locale: locale)
        }
    }

    public static let scanning = VerdictPresentation(title: "", symbol: "magnifyingglass", color: "secondary")
    public static let thinking = VerdictPresentation(title: "", symbol: "sparkles", color: "accent")
}
