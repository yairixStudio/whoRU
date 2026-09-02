import Foundation
import Testing
import WhoRUCore
@testable import WhoRUMac

private let terminal = Subject(
    path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", bundleID: "com.apple.Terminal", displayName: "Terminal",
    version: "2.15", bundlePath: "/System/Applications/Utilities/Terminal.app", resolver: ResolverOutcome(strategy: "test", confidence: .high)
)

/// A prompted Downloads request from Terminal, answered Allow, between the
/// kinds of lines tccd writes all day: entitled daemons, preflights, policy.
private let compactLog = """
2026-09-02 16:20:00.500 Df tccd[956:2574] [com.apple.TCC:access] AUTHREQ_CTX: msgID=1002.1015, function=<private>, service=kTCCServiceAddressBook, preflight=yes, query=1, client_dict=(null), daemon_dict=<private>
2026-09-02 16:20:00.501 Df tccd[956:2574] [com.apple.TCC:access] AUTHREQ_ATTRIBUTION: msgID=1002.1015, attribution={accessing={TCCDProcess: identifier=com.apple.accountsd, pid=996, auid=501, euid=501, binary_path=/System/Library/Frameworks/Accounts.framework/Versions/A/Support/accountsd}, requesting={TCCDProcess: identifier=com.apple.contactsd, pid=1002, auid=501, euid=501, binary_path=/System/Library/Frameworks/Contacts.framework/Support/contactsd}, },
2026-09-02 16:20:00.502 Df tccd[956:2574] [com.apple.TCC:access] AUTHREQ_RESULT: msgID=1002.1015, authValue=2, authReason=11, authVersion=1, desired_auth=0, error=(null),
2026-09-02 16:20:01.000 Df tccd[618:ad66] [com.apple.TCC:access] AUTHREQ_CTX: msgID=612.327, function=TCCAccessRequest, service=kTCCServiceSystemPolicyDownloadsFolder, preflight=yes, query=1, client_dict=(null), daemon_dict=<private>
2026-09-02 16:20:01.001 Df tccd[618:ad66] [com.apple.TCC:access] AUTHREQ_ATTRIBUTION: msgID=612.327, attribution={accessing={TCCDProcess: identifier=com.google.Chrome, pid=1432, auid=501, euid=501, binary_path=/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}, requesting={TCCDProcess: identifier=com.apple.sandboxd, pid=612, auid=0, euid=0, binary_path=/usr/libexec/sandboxd}, },
2026-09-02 16:20:01.002 Df tccd[618:ad66] [com.apple.TCC:access] AUTHREQ_RESULT: msgID=612.327, authValue=1, authReason=0, authVersion=1, desired_auth=0, error=(null),
2026-09-02 16:20:01.100 Df tccd[618:ad66] [com.apple.TCC:access] AUTHREQ_CTX: msgID=900.12, function=TCCAccessRequest, service=kTCCServiceSystemPolicyDownloadsFolder, preflight=no, query=1, client_dict=(null), daemon_dict=<private>
2026-09-02 16:20:01.101 Df tccd[618:ad66] [com.apple.TCC:access] AUTHREQ_ATTRIBUTION: msgID=900.12, attribution={responsible={TCCDProcess: identifier=com.apple.Terminal, pid=900, auid=501, euid=501, binary_path=/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal}, accessing={TCCDProcess: identifier=/bin/ls, pid=1234, auid=501, euid=501, binary_path=/bin/ls}, },
2026-09-02 16:20:01.102 Df tccd[618:ad66] [com.apple.TCC:access] AUTHREQ_SUBJECT: msgID=900.12, subject=com.apple.Terminal,
2026-09-02 16:20:01.103 Df tccd[618:ad66] [com.apple.TCC:access] AUTHREQ_PROMPTING: msgID=900.12, service=kTCCServiceSystemPolicyDownloadsFolder, prompt_type=1,
2026-09-02 16:20:02.000 Df tccd[618:2326] [com.apple.TCC:access] AUTHREQ_CTX: msgID=1336.1, function=<private>, service=kTCCServiceSystemPolicyDownloadsFolder, preflight=yes, query=1, client_dict=(null), daemon_dict=<private>
2026-09-02 16:20:02.001 Df tccd[618:2326] [com.apple.TCC:access] AUTHREQ_ATTRIBUTION: msgID=1336.1, attribution={requesting={TCCDProcess: identifier=com.apple.dock.extra, pid=1336, auid=501, euid=501, binary_path=/System/Library/CoreServices/Dock.app/Contents/XPCServices/com.apple.dock.extra.xpc/Contents/MacOS/com.apple.dock.extra}, },
2026-09-02 16:20:02.002 Df tccd[618:2326] [com.apple.TCC:access] AUTHREQ_RESULT: msgID=1336.1, authValue=0, authReason=5, authVersion=1, desired_auth=0, error=(null),
2026-09-02 16:20:05.900 Df tccd[618:ad66] [com.apple.TCC:access] AUTHREQ_RESULT: msgID=900.12, authValue=2, authReason=2, authVersion=1, desired_auth=0, error=(null),
"""

@Test func parsesTheLinesOfOneRequestIntoOneEvent() {
    let events = TCCLogParser.events(fromCompact: compactLog)
    #expect(events.count == 4)
    let prompted = events.first { $0.msgID == "900.12" }
    #expect(prompted?.service == "kTCCServiceSystemPolicyDownloadsFolder")
    #expect(prompted?.preflight == false)
    #expect(prompted?.prompted == true)
    #expect(prompted?.authValue == 2)
    #expect(prompted?.authReason == 2)
    #expect(prompted?.identifiers.contains("com.apple.Terminal") == true)
    #expect(prompted?.identifiers.contains("/bin/ls") == true)
    #expect(prompted?.binaryPaths.contains("/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal") == true)
    #expect(prompted?.timestamp != nil)
}

@Test func keepsSpacesInBinaryPaths() {
    let events = TCCLogParser.events(fromCompact: compactLog)
    let chrome = events.first { $0.msgID == "612.327" }
    #expect(chrome?.binaryPaths == ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "/usr/libexec/sandboxd"])
}

@Test func onlyUserAnswersCount() {
    let events = TCCLogParser.events(fromCompact: compactLog)
    let answers = events.filter(\.isUserAnswer)
    #expect(answers.map(\.msgID) == ["900.12"])
    #expect(answers.first?.decision == .allowed)
}

@Test func matchesTheAnswerToTheProgramThePanelWasAbout() {
    let events = TCCLogParser.events(fromCompact: compactLog)
    let since = TCCLogParser.parseTimestamp("2026-09-02 16:20:00.000")!
    let hit = TCCDecisionLookup.match(events, service: .downloadsFolder, subject: terminal, requesterName: "Terminal", since: since)
    #expect(hit?.msgID == "900.12")
    #expect(hit?.decision == .allowed)
}

@Test func matchesByTheDialogsNameWhenNothingWasResolved() {
    let events = TCCLogParser.events(fromCompact: compactLog)
    let since = TCCLogParser.parseTimestamp("2026-09-02 16:20:00.000")!
    let hit = TCCDecisionLookup.match(events, service: .downloadsFolder, subject: nil, requesterName: "Terminal", since: since)
    #expect(hit?.msgID == "900.12")
}

@Test func doesNotMatchAnotherProgramOrPermission() {
    let events = TCCLogParser.events(fromCompact: compactLog)
    let since = TCCLogParser.parseTimestamp("2026-09-02 16:20:00.000")!
    let chrome = Subject(path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", bundleID: "com.google.Chrome", displayName: "Google Chrome",
                         bundlePath: "/Applications/Google Chrome.app", resolver: ResolverOutcome(strategy: "test", confidence: .high))
    #expect(TCCDecisionLookup.match(events, service: .downloadsFolder, subject: chrome, requesterName: "Google Chrome", since: since) == nil)
    #expect(TCCDecisionLookup.match(events, service: .contacts, subject: terminal, requesterName: "Terminal", since: since) == nil)
}

@Test func ignoresAnswersFromBeforeTheDialog() {
    let events = TCCLogParser.events(fromCompact: compactLog)
    let later = TCCLogParser.parseTimestamp("2026-09-02 16:21:00.000")!
    #expect(TCCDecisionLookup.match(events, service: .downloadsFolder, subject: terminal, requesterName: "Terminal", since: later) == nil)
}

@Test func readsADenialAndTheNDJSONStyle() throws {
    let lines = [
        ["timestamp": "2026-09-02 16:30:01.000000+0300", "eventMessage": "AUTHREQ_CTX: msgID=77.1, function=TCCAccessRequest, service=kTCCServiceCamera, preflight=no, query=1, client_dict=(null), daemon_dict=<private>"],
        ["timestamp": "2026-09-02 16:30:01.001000+0300", "eventMessage": "AUTHREQ_ATTRIBUTION: msgID=77.1, attribution={requesting={TCCDProcess: identifier=us.zoom.xos, pid=77, auid=501, euid=501, binary_path=/Applications/zoom.us.app/Contents/MacOS/zoom.us}, },"],
        ["timestamp": "2026-09-02 16:30:04.000000+0300", "eventMessage": "AUTHREQ_RESULT: msgID=77.1, authValue=0, authReason=2, authVersion=1, desired_auth=0, error=(null),"],
        ["count": 3, "finished": 1],
    ]
    let text = try lines.map { try String(decoding: JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n")
    let events = TCCLogParser.events(fromNDJSON: text)
    #expect(events.count == 1)
    #expect(events.first?.decision == .denied)
    #expect(events.first?.isUserAnswer == true)
    let zoom = Subject(path: "/Applications/zoom.us.app/Contents/MacOS/zoom.us", bundleID: "us.zoom.xos", displayName: "zoom.us",
                       bundlePath: "/Applications/zoom.us.app", resolver: ResolverOutcome(strategy: "test", confidence: .high))
    let hit = TCCDecisionLookup.match(events, service: .camera, subject: zoom, requesterName: "zoom.us", since: Date(timeIntervalSince1970: 0))
    #expect(hit?.decision == .denied)
}
