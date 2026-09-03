import Foundation
#if canImport(Darwin)
import Darwin

/// Private libSystem entry point that makes the spawned child its own
/// "responsible process" for TCC, so it inherits none of the parent's
/// privacy grants. Declared by hand: the header is not in the SDK, but the
/// symbol is exported and stable (Chromium and Homebrew rely on it too).
/// The pointer type matches what the SDK uses for `posix_spawnattr_setflags`.
@_silgen_name("responsibility_spawnattrs_setdisclaim")
private func responsibility_spawnattrs_setdisclaim(_ attrs: UnsafeMutablePointer<posix_spawnattr_t?>, _ disclaim: Int32) -> Int32
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

public struct CommandOutput: Sendable, Hashable {
    public var stdout: String
    public var stderr: String
    public var status: Int32
    public var durationMs: Int
    public var timedOut: Bool

    public var succeeded: Bool { status == 0 && !timedOut }
    /// stdout and stderr together, for “How did you check?”.
    public var combined: String {
        [stdout, stderr].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

public struct CommandError: Error, Sendable, CustomStringConvertible {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// Runs an external command with an argument array. There is deliberately no
/// way to pass a shell string: dialog text and file names are hostile input.
public enum Command {
    /// `disclaimResponsibility` matters for children we do not control: an AI
    /// engine installed in a user-writable directory. On macOS a child is
    /// normally attributed to its parent for privacy purposes, which would
    /// hand it whoRU's Accessibility grant. With the flag the child becomes
    /// its own responsible process and gets nothing from us. Apple's own
    /// tools (codesign, spctl, mdls, lsof) keep running attributed to whoRU
    /// so their file access keeps working. Ignored on other platforms.
    public static func run(_ executable: String, _ arguments: [String], timeout: Duration = .seconds(4), environment: [String: String]? = nil, workingDirectory: String? = nil, disclaimResponsibility: Bool = false) async throws -> CommandOutput {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw CommandError("not executable: \(executable)")
        }
        let timeoutSeconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let output = try await Task.detached(priority: .userInitiated) {
            #if canImport(Darwin)
            if disclaimResponsibility {
                return try runDisclaimed(executable, arguments, timeoutSeconds: timeoutSeconds, environment: environment, workingDirectory: workingDirectory)
            }
            #endif
            return try runBlocking(executable, arguments, timeoutSeconds: timeoutSeconds, environment: environment, workingDirectory: workingDirectory)
        }.value
        if output.timedOut {
            AppLog.shared.warn("command", "\((executable as NSString).lastPathComponent) timed out after \(output.durationMs) ms")
        } else if output.status != 0 {
            AppLog.shared.debug("command", "\((executable as NSString).lastPathComponent) exited \(output.status) in \(output.durationMs) ms")
        }
        return output
    }

    /// Synchronous body, kept off the async context because pipe reads and
    /// `waitUntilExit` block the thread.
    private static func runBlocking(_ executable: String, _ arguments: [String], timeoutSeconds: Double, environment: [String: String]?, workingDirectory: String?) throws -> CommandOutput {
        let started = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let workingDirectory { process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory) }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        try process.run()
        // Our copies of the write ends would keep the pipes from ever reaching EOF.
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()

        let drained = drain(
            stdout: out.fileHandleForReading.fileDescriptor, stderr: err.fileHandleForReading.fileDescriptor,
            deadline: started.addingTimeInterval(timeoutSeconds),
            atDeadline: { if process.isRunning { process.terminate() } },
            afterDeadline: {}
        )
        process.waitUntilExit()

        return CommandOutput(
            stdout: String(decoding: drained.stdout, as: UTF8.self),
            stderr: String(decoding: drained.stderr, as: UTF8.self),
            status: process.terminationStatus,
            durationMs: Int(Date().timeIntervalSince(started) * 1000),
            timedOut: drained.timedOut
        )
    }

    #if canImport(Darwin)
    /// Same contract as `runBlocking`, through `posix_spawn`, because
    /// Foundation's `Process` offers no way to set the disclaim attribute.
    /// stdin is /dev/null and every descriptor but the three standard ones is
    /// closed in the child (`POSIX_SPAWN_CLOEXEC_DEFAULT`).
    private static func runDisclaimed(_ executable: String, _ arguments: [String], timeoutSeconds: Double, environment: [String: String]?, workingDirectory: String?) throws -> CommandOutput {
        let started = Date()
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        guard pipe(&stdoutPipe) == 0 else { throw CommandError("pipe: \(String(cString: strerror(errno)))") }
        guard pipe(&stderrPipe) == 0 else {
            close(stdoutPipe[0]); close(stdoutPipe[1])
            throw CommandError("pipe: \(String(cString: strerror(errno)))")
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO)
        if let workingDirectory {
            posix_spawn_file_actions_addchdir(&actions, workingDirectory)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A fresh signal mask: a blocked signal in the parent must not stay blocked in the child.
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK))
        let disclaimStatus = responsibility_spawnattrs_setdisclaim(&attributes, 1)
        guard disclaimStatus == 0 else {
            close(stdoutPipe[0]); close(stdoutPipe[1]); close(stderrPipe[0]); close(stderrPipe[1])
            throw CommandError("cannot disclaim responsibility for \(executable): \(disclaimStatus)")
        }

        let argv = CStringArray([executable] + arguments)
        let envp = environment.map { CStringArray($0.map { "\($0.key)=\($0.value)" }) }
        var pid: pid_t = 0
        let spawnStatus = posix_spawn(&pid, executable, &actions, &attributes, argv.pointer, envp?.pointer ?? environ)
        // The child owns its copies now; keeping ours open would keep the reads from ever reaching EOF.
        close(stdoutPipe[1])
        close(stderrPipe[1])
        guard spawnStatus == 0 else {
            close(stdoutPipe[0]); close(stderrPipe[0])
            throw CommandError("posix_spawn \(executable): \(String(cString: strerror(spawnStatus)))")
        }
        defer { close(stdoutPipe[0]); close(stderrPipe[0]) }

        // SIGTERM at the deadline, SIGKILL a second later if the child ignored
        // it. Both happen before waitpid, so the pid is still ours.
        let drained = drain(
            stdout: stdoutPipe[0], stderr: stderrPipe[0],
            deadline: started.addingTimeInterval(timeoutSeconds),
            atDeadline: { kill(pid, SIGTERM) },
            afterDeadline: { kill(pid, SIGKILL) }
        )
        var rawStatus: Int32 = 0
        while waitpid(pid, &rawStatus, 0) == -1 && errno == EINTR {}
        // Like `Process.terminationStatus`: the exit code, or the signal number when killed by one.
        let signalNumber = rawStatus & 0x7f
        let status = signalNumber == 0 ? (rawStatus >> 8) & 0xff : signalNumber

        return CommandOutput(
            stdout: String(decoding: drained.stdout, as: UTF8.self),
            stderr: String(decoding: drained.stderr, as: UTF8.self),
            status: status,
            durationMs: Int(Date().timeIntervalSince(started) * 1000),
            timedOut: drained.timedOut
        )
    }
    #endif

    /// Reads both pipes to EOF from the calling thread with `poll(2)`, and
    /// enforces the deadline itself: `atDeadline` runs once when it passes,
    /// `afterDeadline` one second later if the pipes are still open.
    ///
    /// No helper thread and no dispatch timer, on purpose. Commands run on
    /// Swift's cooperative pool, one thread per core; when enough of them run
    /// at once (the test suite, a scan with many checks) every pool thread is
    /// blocked here, libdispatch starts no further worker, and a reader or a
    /// watchdog handed to a global queue never runs. One thread that waits on
    /// both descriptors cannot starve that way.
    private static func drain(stdout stdoutFD: Int32, stderr stderrFD: Int32, deadline: Date, atDeadline: () -> Void, afterDeadline: () -> Void) -> (stdout: Data, stderr: Data, timedOut: Bool) {
        var descriptors = [pollfd(fd: stdoutFD, events: Int16(POLLIN), revents: 0), pollfd(fd: stderrFD, events: Int16(POLLIN), revents: 0)]
        var buffers = [Data(), Data()]
        var open = [true, true]
        var timedOut = false
        var killed = false
        let killDeadline = deadline.addingTimeInterval(1)
        let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: 65536)
        defer { chunk.deallocate() }

        while open.contains(true) {
            let nextDeadline: Date? = !timedOut ? deadline : (!killed ? killDeadline : nil)
            let waitMs: Int32 = nextDeadline.map { Int32(clamping: Int(max(0, $0.timeIntervalSinceNow * 1000).rounded(.up))) } ?? -1
            let ready = poll(&descriptors, nfds_t(descriptors.count), waitMs)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            for index in descriptors.indices where open[index] && descriptors[index].revents != 0 {
                let count = read(descriptors[index].fd, chunk, 65536)
                if count > 0 {
                    buffers[index].append(chunk, count: count)
                } else if count == 0 || errno != EINTR {
                    open[index] = false
                    descriptors[index].fd = -1 // poll ignores negative descriptors
                }
            }
            if !timedOut, Date() >= deadline {
                timedOut = true
                atDeadline()
            } else if timedOut, !killed, Date() >= killDeadline {
                killed = true
                afterDeadline()
            }
        }
        return (buffers[0], buffers[1], timedOut)
    }
}

#if canImport(Darwin)
/// A NULL-terminated `char *[]` for `posix_spawn`, freed with the wrapper.
private final class CStringArray {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
        count = strings.count
        pointer = .allocate(capacity: count + 1)
        for (index, string) in strings.enumerated() { pointer[index] = strdup(string) }
        pointer[count] = nil
    }

    deinit {
        for index in 0..<count { free(pointer[index]) }
        pointer.deallocate()
    }
}
#endif

/// Runs an async operation with a deadline.
public struct TimeoutError: Error, Sendable, CustomStringConvertible {
    public var description: String { "timed out" }
    public init() {}
}

public func withTimeout<T: Sendable>(_ duration: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw TimeoutError()
        }
        guard let first = try await group.next() else { throw TimeoutError() }
        group.cancelAll()
        return first
    }
}
