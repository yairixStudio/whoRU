import Foundation

/// A regular expression that extracts the requester and the request phrase
/// from a dialog title. Patterns are data so that fixtures in other languages
/// can add them without touching code.
public struct PromptPattern: Codable, Sendable, Hashable {
    public var locale: String
    public var regex: String
    public var requesterGroup: Int
    public var phraseGroup: Int
    /// Group holding the controlled app in automation prompts, if any.
    public var targetGroup: Int?
    /// When set, the pattern implies this service regardless of the phrase.
    public var service: PermissionService?

    public init(locale: String, regex: String, requesterGroup: Int = 1, phraseGroup: Int = 2, targetGroup: Int? = nil, service: PermissionService? = nil) {
        self.locale = locale
        self.regex = regex
        self.requesterGroup = requesterGroup
        self.phraseGroup = phraseGroup
        self.targetGroup = targetGroup
        self.service = service
    }
}

public struct ParsedPrompt: Sendable, Hashable {
    public var requester: String
    public var phrase: String
    public var service: PermissionService
    public var target: String?
    public var locale: String
    /// Index into the parser's pattern table, for diagnostics.
    public var patternIndex: Int
}

/// Turns the text of a permission dialog into a `PermissionPrompt`.
///
/// The parser is deliberately dumb: ordered patterns, first match wins, and a
/// keyword table maps the request phrase to a service. Anything it cannot
/// parse is reported as `nil` so the caller can show the raw text and ask the
/// user, rather than guessing.
public struct PromptParser: Sendable {
    public let patterns: [PromptPattern]

    public init(patterns: [PromptPattern] = PromptParser.builtinPatterns) {
        self.patterns = patterns
    }

    /// English wording as of macOS 26, plus a last-resort pattern that only
    /// requires the requester to be quoted. Other languages are added from
    /// fixtures contributed by users, never guessed.
    public static let builtinPatterns: [PromptPattern] = [
        PromptPattern(locale: "en", regex: #"^[“"](.+?)[”"] wants access to control [“"](.+?)[”"]\.?$"#, requesterGroup: 1, phraseGroup: 2, targetGroup: 2, service: .appleEvents),
        PromptPattern(locale: "en", regex: #"^[“"](.+?)[”"] would like to (.+?)\.?$"#),
        PromptPattern(locale: "en", regex: #"^[“"](.+?)[”"] wants to (.+?)\.?$"#),
        PromptPattern(locale: "en", regex: #"^[“"](.+?)[”"] would like access to (.+?)\.?$"#),
        PromptPattern(locale: "en", regex: #"^[“"](.+?)[”"] wants access to (.+?)\.?$"#),
        PromptPattern(locale: "en", regex: #"^[“"](.+?)[”"] is requesting (.+?)\.?$"#),
        // Newer wording (macOS 27+) puts "Allow" before the quoted requester, e.g. Bluetooth prompts.
        PromptPattern(locale: "en", regex: #"^Allow [“"](.+?)[”"] to (.+?)[.?]?$"#),
        // The keychain's and the authorization dialogs name the program without quotes.
        PromptPattern(locale: "en", regex: #"^(.+?) wants to ((?:access|use) (?:key|your confidential information stored in) [“"].+?[”"] in your keychain)\.?$"#, service: .keychain),
        PromptPattern(locale: "en", regex: #"^(.+?) wants to (make changes)\.?$"#, service: .adminRights),
        // Generic: a quoted name followed by anything, in any language that quotes the requester.
        PromptPattern(locale: "*", regex: #"^[“"״„«](.+?)[”"״“»]\s+(.+)$"#),
    ]

    public func parse(title: String, body: String? = nil) -> ParsedPrompt? {
        let cleaned = Self.normalize(title)
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern.regex, options: [.caseInsensitive]) else { continue }
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            guard let match = regex.firstMatch(in: cleaned, options: [], range: range) else { continue }
            guard let requester = Self.group(pattern.requesterGroup, in: match, of: cleaned),
                  let phrase = Self.group(pattern.phraseGroup, in: match, of: cleaned) else { continue }
            let target = pattern.targetGroup.flatMap { Self.group($0, in: match, of: cleaned) }
            let service = pattern.service ?? Self.service(forPhrase: phrase)
            return ParsedPrompt(
                requester: requester.trimmingCharacters(in: .whitespaces),
                phrase: phrase.trimmingCharacters(in: .whitespaces),
                service: service,
                target: target,
                locale: pattern.locale == "*" ? "und" : pattern.locale,
                patternIndex: index
            )
        }
        return nil
    }

    public func makePrompt(title: String, body: String? = nil, detectedAt: Date = Date()) -> PermissionPrompt? {
        guard let parsed = parse(title: title, body: body) else { return nil }
        return PermissionPrompt(
            title: title,
            body: body,
            requesterName: parsed.requester,
            service: parsed.service,
            requestPhrase: parsed.phrase,
            target: parsed.target,
            locale: parsed.locale,
            detectedAt: detectedAt
        )
    }

    /// Keyword table mapping the English request phrase to a service. Order
    /// matters: the first hit wins, so specific phrases come first.
    public static let serviceKeywords: [(PermissionService, [String])] = [
        (.networkVolumes, ["network volume"]),
        (.removableVolumes, ["removable volume"]),
        (.desktopFolder, ["desktop folder"]),
        (.documentsFolder, ["documents folder"]),
        (.downloadsFolder, ["downloads folder"]),
        (.fullDiskAccess, ["full disk"]),
        (.screenCapture, ["record this computer's screen", "record this computer’s screen", "screen recording", "screen and audio"]),
        (.inputMonitoring, ["keystrokes", "input monitoring"]),
        (.accessibility, ["accessibility features", "control this computer"]),
        (.speechRecognition, ["speech recognition"]),
        (.appleEvents, ["data from other apps", "control", "apple events"]),
        (.camera, ["camera"]),
        (.microphone, ["microphone"]),
        (.contacts, ["contacts"]),
        (.calendar, ["calendar"]),
        (.reminders, ["reminders"]),
        (.photos, ["photos", "photo library"]),
        (.bluetooth, ["bluetooth"]),
        (.localNetwork, ["local network"]),
        (.location, ["location"]),
        (.keychain, ["keychain"]),
        (.adminRights, ["make changes"]),
    ]

    public static func service(forPhrase phrase: String) -> PermissionService {
        let lower = phrase.lowercased()
        for (service, keywords) in serviceKeywords where keywords.contains(where: { lower.contains($0) }) {
            return service
        }
        return .other
    }

    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func group(_ index: Int, in match: NSTextCheckingResult, of text: String) -> String? {
        guard index < match.numberOfRanges else { return nil }
        let nsRange = match.range(at: index)
        guard nsRange.location != NSNotFound, let range = Range(nsRange, in: text) else { return nil }
        return String(text[range])
    }
}
