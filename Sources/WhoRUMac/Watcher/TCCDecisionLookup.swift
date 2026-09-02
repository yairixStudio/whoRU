import Foundation
import WhoRUCore

/// One permission request as `tccd` logged it: the `AUTHREQ_*` lines that
/// share a message id. The system writes these for every request, including
/// the ones it put a dialog on screen for, and the result line carries the
/// user's answer. Reading the unified log needs no permission of its own.
public struct TCCAuthEvent: Sendable, Hashable {
    public var msgID: String
    public var service: String?
    public var preflight: Bool?
    /// Bundle identifiers (or executable paths, for bare binaries) named in
    /// the attribution and subject lines: responsible, accessing, requesting.
    public var identifiers: [String] = []
    public var binaryPaths: [String] = []
    public var authValue: Int?
    public var authReason: Int?
    /// A prompting line was logged for this request.
    public var prompted = false
    public var timestamp: Date?

    public init(msgID: String) {
        self.msgID = msgID
    }

    /// `auth_reason` values as TCC stores them.
    public enum Reason {
        public static let userConsent = 2
        public static let userSet = 3
        public static let promptTimeout = 9
    }

    /// The answer came from the user: a click in the dialog, or a change in
    /// System Settings in the meantime. Policy, entitlement and preflight
    /// results are not answers.
    public var isUserAnswer: Bool {
        guard let authValue else { return false }
        if authReason == Reason.userConsent || authReason == Reason.userSet { return true }
        return prompted && [0, 2, 3].contains(authValue)
    }

    /// 0 denied · 1 unknown · 2 allowed · 3 allowed with limits.
    public var decision: UserDecision? {
        switch authValue {
        case 0: .denied
        case 2, 3: .allowed
        default: nil
        }
    }

    /// Whether the request names the program the panel was about.
    public func names(_ subject: Subject) -> Bool {
        if let bundleID = subject.bundleID, identifiers.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }) {
            return true
        }
        let roots = [subject.bundlePath, subject.path].compactMap { $0 }
        return (binaryPaths + identifiers).contains { path in
            roots.contains { root in path == root || path.hasPrefix(root + "/") }
        }
    }

    /// Whether the request names a program called `name` (the dialog's own wording).
    public func names(displayName name: String) -> Bool {
        let wanted = name.lowercased()
        guard !wanted.isEmpty else { return false }
        if identifiers.contains(where: { id in
            let lower = id.lowercased()
            return lower == wanted || lower.hasSuffix("." + wanted) || (lower as NSString).lastPathComponent == wanted
        }) { return true }
        return binaryPaths.contains { ($0 as NSString).lastPathComponent.lowercased() == wanted }
    }
}

/// Turns `log show --style ndjson` output for `tccd` into events.
public enum TCCLogParser {
    public static func events(fromNDJSON text: String) -> [TCCAuthEvent] {
        var byID: [String: TCCAuthEvent] = [:]
        var order: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = object["eventMessage"] as? String,
                  message.hasPrefix("AUTHREQ_") else { continue }
            let stamp = (object["timestamp"] as? String).flatMap(parseTimestamp)
            apply(message, timestamp: stamp, to: &byID, order: &order)
        }
        return order.compactMap { byID[$0] }
    }

    /// The same, from `--style compact` lines (used by the tests and the log viewer).
    public static func events(fromCompact text: String) -> [TCCAuthEvent] {
        var byID: [String: TCCAuthEvent] = [:]
        var order: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let range = line.range(of: "AUTHREQ_") else { continue }
            let message = String(line[range.lowerBound...])
            let stamp = parseTimestamp(String(line.prefix(23)))
            apply(message, timestamp: stamp, to: &byID, order: &order)
        }
        return order.compactMap { byID[$0] }
    }

    private static func apply(_ message: String, timestamp: Date?, to byID: inout [String: TCCAuthEvent], order: inout [String]) {
        guard let id = firstMatch(#"msgID=([0-9.]+)"#, in: message) else { return }
        var event = byID[id] ?? TCCAuthEvent(msgID: id)
        if byID[id] == nil { order.append(id) }
        if let timestamp { event.timestamp = timestamp }
        if message.hasPrefix("AUTHREQ_CTX") {
            event.service = firstMatch(#"service=(kTCCService[A-Za-z0-9_]+)"#, in: message)
            if let preflight = firstMatch(#"preflight=(yes|no|true|false)"#, in: message) {
                event.preflight = preflight == "yes" || preflight == "true"
            }
        } else if message.hasPrefix("AUTHREQ_ATTRIBUTION") {
            event.identifiers += allMatches(#"identifier=([^,}\s]+)"#, in: message)
            event.binaryPaths += allMatches(#"binary_path=(.+?)(?=\}|, [a-z_]+=)"#, in: message)
        } else if message.hasPrefix("AUTHREQ_SUBJECT") {
            if let subject = firstMatch(#"subject=([^,]+)"#, in: message) { event.identifiers.append(subject) }
        } else if message.hasPrefix("AUTHREQ_RESULT") {
            event.authValue = firstMatch(#"authValue=(\d+)"#, in: message).flatMap { Int($0) }
            event.authReason = firstMatch(#"authReason=(\d+)"#, in: message).flatMap { Int($0) }
        } else if message.hasPrefix("AUTHREQ_PROMPTING") {
            event.prompted = true
            if event.service == nil { event.service = firstMatch(#"service=(kTCCService[A-Za-z0-9_]+)"#, in: message) }
        }
        byID[id] = event
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        allMatches(pattern, in: text).first
    }

    private static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[r]).trimmingCharacters(in: .whitespaces)
        }
    }

    private static let timestampFormats: [DateFormatter] = ["yyyy-MM-dd HH:mm:ss.SSSSSSZ", "yyyy-MM-dd HH:mm:ss.SSSZ", "yyyy-MM-dd HH:mm:ss.SSS"].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter
    }

    static func parseTimestamp(_ text: String) -> Date? {
        for formatter in timestampFormats {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

/// Finds out what the user answered in a permission dialog without asking
/// them: the system logs every request with its result, and the log is
/// readable by the user who answered. Runs after the dialog closes; the
/// entry can take a moment to land, so it looks more than once.
public enum TCCDecisionLookup {
    public struct Match: Sendable {
        public var decision: UserDecision
        public var event: TCCAuthEvent
    }

    /// Looks at the log a few times, at growing intervals: the entry usually
    /// lands within seconds, but the daemon can be busy.
    public static let lookSchedule: [Duration] = [.milliseconds(1500), .seconds(2), .seconds(3), .seconds(5), .seconds(8), .seconds(12)]

    public static func decision(service: PermissionService, subject: Subject?, requesterName: String, since: Date,
                                looks: [Duration] = lookSchedule) async -> Match? {
        guard service.tccServiceName != nil else { return nil }
        let windowStart = since.addingTimeInterval(-5)
        let start = Self.startFormatter.string(from: windowStart)
        let predicate = #"process == "tccd" AND category == "access" AND eventMessage BEGINSWITH "AUTHREQ_""#
        var events: [TCCAuthEvent] = []
        for (attempt, delay) in ([Duration.zero] + looks).enumerated() {
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let output = try? await Command.run("/usr/bin/log", ["show", "--start", start, "--predicate", predicate, "--style", "ndjson"], timeout: .seconds(20)),
                  output.succeeded else { continue }
            events = TCCLogParser.events(fromNDJSON: output.stdout)
            if let hit = match(events, service: service, subject: subject, requesterName: requesterName, since: windowStart),
               let decision = hit.decision {
                AppLog.shared.info("decision", "“\(requesterName)” \(service.shortName): \(decision.rawValue), read from the system log (authValue \(hit.authValue ?? -1), reason \(hit.authReason ?? -1), service \(hit.service ?? "?"), msgID \(hit.msgID), look \(attempt + 1))")
                return Match(decision: decision, event: hit)
            }
        }
        // Say what was there, so a format change on a new macOS shows up in the log.
        let services = Set(events.compactMap(\.service)).sorted().map { $0.replacingOccurrences(of: "kTCCService", with: "") }
        let answers = events.filter(\.isUserAnswer).suffix(5).map {
            "\($0.msgID) \($0.service?.replacingOccurrences(of: "kTCCService", with: "") ?? "?") value=\($0.authValue.map(String.init) ?? "-") reason=\($0.authReason.map(String.init) ?? "-") ids=\($0.identifiers.joined(separator: "|"))"
        }
        AppLog.shared.info("decision", "“\(requesterName)” \(service.shortName): no answer in the system log after \(looks.count + 1) looks over \(Int(Date().timeIntervalSince(since))) s · \(events.count) requests since the dialog, services [\(services.joined(separator: ", "))]\(answers.isEmpty ? "" : " · user answers: " + answers.joined(separator: " ; "))")
        return nil
    }

    /// The most recent answer for this permission that names the program;
    /// failing that, an answer whose service the log hid but that names the
    /// program; failing that, the only answer for the permission in the
    /// window when the log names no program at all.
    public static func match(_ events: [TCCAuthEvent], service: PermissionService, subject: Subject?, requesterName: String, since: Date) -> TCCAuthEvent? {
        guard let wanted = service.tccServiceName else { return nil }
        let answers = events.filter { event in
            event.isUserAnswer && event.decision != nil && (event.timestamp.map { $0 >= since } ?? true)
        }
        let forService = answers.filter { $0.service == wanted }
        func names(_ event: TCCAuthEvent) -> Bool {
            (subject.map(event.names) ?? false) || event.names(displayName: requesterName)
        }
        if let hit = forService.last(where: names) { return hit }
        if let hit = answers.filter({ $0.service == nil }).last(where: names) { return hit }
        if forService.count == 1, forService[0].identifiers.isEmpty, forService[0].binaryPaths.isEmpty { return forService[0] }
        return nil
    }

    private static let startFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
