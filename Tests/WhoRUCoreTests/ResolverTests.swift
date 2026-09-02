import Foundation
import Testing
@testable import WhoRUCore

struct FakeProcesses: ProcessInspector {
    var list: [RunningProcess]
    func runningProcesses() async throws -> [RunningProcess] { list }
    func parentChain(of pid: Int32) async throws -> [RunningProcess] {
        var chain: [RunningProcess] = []
        var current = list.first { $0.pid == pid }
        while let c = current {
            chain.append(c)
            current = list.first { $0.pid == c.ppid }
        }
        return chain
    }
}

struct FakeFinder: ApplicationFinder {
    var results: [String: [String]]
    func applications(named name: String) async throws -> [String] { results[name] ?? [] }
}

private func prompt(_ name: String) -> PermissionPrompt {
    PermissionPrompt(title: "“\(name)” would like to access files in your Downloads folder.", requesterName: name, service: .downloadsFolder, requestPhrase: "access files in your Downloads folder")
}

@Suite struct ResolverTests {
    let claude = RunningProcess(pid: 41337, ppid: 4000, path: "/Users/me/.local/share/claude/versions/2.1.258")
    let zsh = RunningProcess(pid: 4000, ppid: 300, path: "/bin/zsh")
    let terminal = RunningProcess(pid: 300, ppid: 1, path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", bundleID: "com.apple.Terminal", localizedName: "Terminal", isApplication: true)
    let chrome = RunningProcess(pid: 500, ppid: 1, path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", bundleID: "com.google.Chrome", localizedName: "Google Chrome", isApplication: true)

    @Test func bareBinaryNamedAfterVersionResolvesByBasename() async {
        let resolver = RequesterResolver(processes: FakeProcesses(list: [claude, zsh, terminal]))
        let result = await resolver.resolve(prompt("2.1.258"))
        #expect(result.subject?.path == claude.path)
        #expect(result.subject?.pid == 41337)
        #expect(result.subject?.resolver.strategy == "running_process_basename")
        #expect(result.subject?.resolver.confidence == .high)
    }

    @Test func runningAppResolvesByLocalizedName() async {
        let resolver = RequesterResolver(processes: FakeProcesses(list: [chrome, terminal]))
        let result = await resolver.resolve(prompt("google chrome"))
        #expect(result.subject?.bundleID == "com.google.Chrome")
        #expect(result.subject?.resolver.strategy == "running_app_name")
    }

    @Test func collisionLowersConfidenceAndKeepsCandidates() async {
        let twin = RunningProcess(pid: 9, ppid: 1, path: "/tmp/evil/2.1.258")
        let resolver = RequesterResolver(processes: FakeProcesses(list: [claude, twin]))
        let result = await resolver.resolve(prompt("2.1.258"))
        #expect(result.candidates.count == 2)
        #expect(result.subject?.resolver.confidence == .medium)
    }

    @Test func installedButNotRunningUsesFinder() async {
        let resolver = RequesterResolver(processes: FakeProcesses(list: [terminal]), finder: FakeFinder(results: ["Slack": ["/Applications/Slack.app"]]))
        let result = await resolver.resolve(prompt("Slack"))
        #expect(result.subject?.path == "/Applications/Slack.app")
        #expect(result.subject?.resolver.confidence == .medium)
    }

    @Test func multipleInstalledMatchesAreLowConfidence() async {
        let resolver = RequesterResolver(processes: FakeProcesses(list: []), finder: FakeFinder(results: ["Thing": ["/Applications/Thing.app", "/Users/me/Downloads/Thing.app"]]))
        let result = await resolver.resolve(prompt("Thing"))
        #expect(result.subject?.resolver.confidence == .low)
        #expect(result.candidates.count == 2)
    }

    @Test func nothingFoundIsUnresolved() async {
        let resolver = RequesterResolver(processes: FakeProcesses(list: [terminal]), finder: FakeFinder(results: [:]))
        let result = await resolver.resolve(prompt("Ghost"))
        #expect(result.subject == nil)
        #expect(result.candidates.isEmpty)
    }

    @Test func enclosingBundleIsTheOutermostApp() {
        let path = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"
        // Outermost .app wins so that helpers are attributed to their parent application.
        #expect(BundleInfo.enclosingBundlePath(of: path) == "/Applications/Google Chrome.app")
        #expect(BundleInfo.enclosingBundlePath(of: "/usr/bin/zsh") == nil)
    }
}
