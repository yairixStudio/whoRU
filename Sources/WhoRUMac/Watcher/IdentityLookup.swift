import Foundation
import WhoRUCore

/// Finds the system's own record of who asked: `tccd` logs every request
/// with the responsible process's pid and binary before the dialog is even
/// drawn. The resolver guesses from the dialog's wording; this is the answer.
///
/// The lines take a few seconds to become readable through `log show`, so
/// this looks several times and gives up well within the dialog's lifetime.
/// Some prompts leave no lines at all; the caller must treat `nil` as a
/// normal outcome, never as something to wait longer for.
public enum IdentityLookup {
    /// Delays before each look. About 17 s in total, spread so that the usual
    /// case (lines readable after 2–4 s) costs two or three runs of `log`.
    public static let lookSchedule: [Duration] = [.milliseconds(500), .seconds(1), .milliseconds(1500), .seconds(2), .seconds(3), .seconds(4), .seconds(5)]

    public static func attribution(service: PermissionService, since: Date, looks: [Duration] = lookSchedule) async -> TCCAuthEvent? {
        guard let wanted = service.tccServiceName else { return nil }
        let windowStart = since.addingTimeInterval(-10)
        let start = startFormatter.string(from: windowStart)
        let predicate = #"process == "tccd" AND category == "access" AND eventMessage BEGINSWITH "AUTHREQ_""#
        let began = Date()
        var events: [TCCAuthEvent] = []
        for (attempt, delay) in looks.enumerated() {
            if Task.isCancelled { return nil }
            try? await Task.sleep(for: delay)
            guard let output = try? await Command.run("/usr/bin/log", ["show", "--start", start, "--predicate", predicate, "--style", "ndjson"], timeout: .seconds(20)),
                  output.succeeded else { continue }
            events = TCCLogParser.events(fromNDJSON: output.stdout)
            if let hit = match(events, service: service, since: windowStart), let responsible = hit.responsible {
                AppLog.shared.info("identity", "\(service.shortName): responsible pid \(responsible.pid ?? -1) \(responsible.binaryPath ?? responsible.identifier ?? "?") (msgID \(hit.msgID), look \(attempt + 1), \(elapsedMs(since: began)) ms)")
                return hit
            }
        }
        // Say what was there, so a format change on a new macOS shows up in the log.
        let seen = events.suffix(6).map {
            "\($0.msgID) \($0.service?.replacingOccurrences(of: "kTCCService", with: "") ?? "?") responsible=\($0.responsible?.pid.map(String.init) ?? "-") ids=\($0.identifiers.joined(separator: "|"))"
        }
        AppLog.shared.info("identity", "\(service.shortName): no attribution with a responsible pid in the system log after \(looks.count) looks over \(elapsedMs(since: began)) ms · \(events.count) requests since 10 s before the dialog\(seen.isEmpty ? "" : " · last: " + seen.joined(separator: " ; ")) · service [\(wanted)]")
        return nil
    }

    /// The most recent request for this permission that names a responsible
    /// process with a pid; one the system put a dialog up for is preferred
    /// over preflights and policy checks for the same permission.
    public static func match(_ events: [TCCAuthEvent], service: PermissionService, since: Date) -> TCCAuthEvent? {
        guard let wanted = service.tccServiceName else { return nil }
        let candidates = events.filter { event in
            event.service == wanted && event.responsible?.pid != nil && (event.timestamp.map { $0 >= since } ?? true)
        }
        return candidates.last(where: \.prompted) ?? candidates.last
    }

    private static let startFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
