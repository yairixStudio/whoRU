import Foundation

/// Builds the deterministic headline shown as soon as the hard score is known.
/// No model involved: a title of two to four words and one sentence from a
/// template, in the interface language.
public struct HeadlineComposer: Sendable {
    public init() {}

    public func headline(for result: HardScoreResult, subject: Subject?, prompt: PermissionPrompt, locale: String) -> Headline {
        let name = subject?.displayName ?? prompt.requesterName
        let first = result.reasons.first
        var params = first?.params ?? [:]
        // A reason may carry its own name (the impersonated one); the subject's name is the fallback.
        params["name"] = params["name"] ?? name

        let title: String
        let sentence: String
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
        return Headline(title: title, sentence: sentence, source: "deterministic")
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
