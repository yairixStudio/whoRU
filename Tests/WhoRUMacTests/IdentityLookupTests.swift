import Foundation
import Testing
import WhoRUCore
@testable import WhoRUMac

/// A Full Disk Access request from a Homebrew Python, as this machine logged
/// it: the responsible process is the interpreter, its app wrapper is what
/// runs, and a sandbox daemon did the asking.
private let pythonLog = """
2026-09-03 09:10:00.100 Df tccd[612:1] [com.apple.TCC:access] AUTHREQ_CTX: msgID=612.32430, function=TCCAccessRequest, service=kTCCServiceSystemPolicyAllFiles, preflight=yes, query=1, client_dict=(null), daemon_dict=<private>
2026-09-03 09:10:00.101 Df tccd[612:1] [com.apple.TCC:access] AUTHREQ_ATTRIBUTION: msgID=612.32430, attribution={responsible={TCCDProcess: identifier=python3-5555494470c540dced88303b8ad4c42585f27e94, pid=20958, auid=501, euid=501, responsible_path=/opt/homebrew/Cellar/python@3.14/3.14.6/Frameworks/Python.framework/Versions/3.14/bin/python3.14, binary_path=/opt/homebrew/Cellar/python@3.14/3.14.6/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python}, accessing={TCCDProcess: identifier=Python-55554944f2e8d3b321bd3918b78dc7e823116c0c, pid=20958, auid=501, euid=501, binary_path=/opt/homebrew/Cellar/python@3.14/3.14.6/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python}, accessing={...}, requesting={TCCDProcess: identifier=com.apple.sandboxd, pid=612, auid=0, euid=0, binary_path=/usr/libexec/sandboxd}, },
2026-09-03 09:10:00.102 Df tccd[612:1] [com.apple.TCC:access] AUTHREQ_SUBJECT: msgID=612.32430, subject=/opt/homebrew/Cellar/python@3.14/3.14.6/Frameworks/Python.framework/Versions/3.14/bin/python3.14,
2026-09-03 09:10:00.103 Df tccd[612:1] [com.apple.TCC:access] AUTHREQ_RESULT: msgID=612.32430, authValue=0, authReason=5, authVersion=1, desired_auth=0, error=(null),
"""

private let binary = "/opt/homebrew/Cellar/python@3.14/3.14.6/Frameworks/Python.framework/Versions/3.14/Resources/Python.app/Contents/MacOS/Python"
private let launched = "/opt/homebrew/Cellar/python@3.14/3.14.6/Frameworks/Python.framework/Versions/3.14/bin/python3.14"

@Test func parsesEachAttributionRoleSeparately() throws {
    let events = TCCLogParser.events(fromCompact: pythonLog)
    let event = try #require(events.first)
    let responsible = try #require(event.responsible)
    #expect(responsible.pid == 20958)
    #expect(responsible.identifier == "python3-5555494470c540dced88303b8ad4c42585f27e94")
    #expect(responsible.binaryPath == binary)
    #expect(responsible.responsiblePath == launched)
    let accessing = try #require(event.accessing)
    #expect(accessing.identifier == "Python-55554944f2e8d3b321bd3918b78dc7e823116c0c")
    #expect(accessing.pid == 20958)
    #expect(accessing.binaryPath == binary)
    #expect(accessing.responsiblePath == nil)
    let requesting = try #require(event.requesting)
    #expect(requesting.identifier == "com.apple.sandboxd")
    #expect(requesting.pid == 612)
    #expect(requesting.binaryPath == "/usr/libexec/sandboxd")
    // The flat lists the decision lookup relies on are unchanged.
    #expect(event.identifiers.contains("com.apple.sandboxd"))
    #expect(event.identifiers.contains(launched))
    #expect(event.binaryPaths == [binary, binary, "/usr/libexec/sandboxd"])
    #expect(event.service == "kTCCServiceSystemPolicyAllFiles")
}

@Test func attributionBecomesTheCoresIdentity() throws {
    let event = try #require(TCCLogParser.events(fromCompact: pythonLog).first)
    let identity = try #require(event.responsible?.identity)
    #expect(identity.pid == 20958)
    #expect(identity.path == binary)
    #expect(identity.paths == [binary, launched])
    #expect(TCCAttribution(identifier: "x").identity == nil)
}

@Test func matchPicksTheLatestResponsibleRequestForTheService() {
    let since = TCCLogParser.parseTimestamp("2026-09-03 09:09:50.000")!
    let events = TCCLogParser.events(fromCompact: pythonLog)
    #expect(IdentityLookup.match(events, service: .fullDiskAccess, since: since)?.responsible?.pid == 20958)
    #expect(IdentityLookup.match(events, service: .downloadsFolder, since: since) == nil)
    #expect(IdentityLookup.match(events, service: .keychain, since: since) == nil)
    let later = TCCLogParser.parseTimestamp("2026-09-03 09:11:00.000")!
    #expect(IdentityLookup.match(events, service: .fullDiskAccess, since: later) == nil)
}

@Test func matchPrefersThePromptedRequestAndSkipsDaemonsWithoutAResponsible() {
    var daemon = TCCAuthEvent(msgID: "1.1")
    daemon.service = "kTCCServiceCamera"
    daemon.requesting = TCCAttribution(identifier: "com.apple.something", pid: 5)
    var preflight = TCCAuthEvent(msgID: "2.1")
    preflight.service = "kTCCServiceCamera"
    preflight.responsible = TCCAttribution(identifier: "us.zoom.xos", pid: 77, binaryPath: "/Applications/zoom.us.app/Contents/MacOS/zoom.us")
    var prompted = TCCAuthEvent(msgID: "2.2")
    prompted.service = "kTCCServiceCamera"
    prompted.prompted = true
    prompted.responsible = TCCAttribution(identifier: "us.zoom.xos", pid: 77, binaryPath: "/Applications/zoom.us.app/Contents/MacOS/zoom.us")
    var later = TCCAuthEvent(msgID: "3.1")
    later.service = "kTCCServiceCamera"
    later.responsible = TCCAttribution(identifier: "com.other", pid: 99)
    #expect(IdentityLookup.match([daemon], service: .camera, since: .distantPast) == nil)
    #expect(IdentityLookup.match([daemon, preflight, prompted, later], service: .camera, since: .distantPast)?.msgID == "2.2")
    #expect(IdentityLookup.match([daemon, preflight, later], service: .camera, since: .distantPast)?.msgID == "3.1")
}

@Test func lookupWithoutASystemServiceReturnsAtOnce() async {
    #expect(await IdentityLookup.attribution(service: .keychain, since: Date(), looks: []) == nil)
}
