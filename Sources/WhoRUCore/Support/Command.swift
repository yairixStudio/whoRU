import Foundation

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
    public static func run(_ executable: String, _ arguments: [String], timeout: Duration = .seconds(4), environment: [String: String]? = nil, workingDirectory: String? = nil) async throws -> CommandOutput {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw CommandError("not executable: \(executable)")
        }
        let timeoutSeconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let output = try await Task.detached(priority: .userInitiated) {
            try runBlocking(executable, arguments, timeoutSeconds: timeoutSeconds, environment: environment, workingDirectory: workingDirectory)
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

        let stderrBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrBox.set(err.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        try process.run()

        let timedOutBox = FlagBox()
        let watchdog = DispatchWorkItem {
            if process.isRunning {
                timedOutBox.set()
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeoutSeconds, execute: watchdog)

        let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        group.wait()

        return CommandOutput(
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrBox.get(), as: UTF8.self),
            status: process.terminationStatus,
            durationMs: Int(Date().timeIntervalSince(started) * 1000),
            timedOut: timedOutBox.isSet
        )
    }
}

private final class DataBox: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

private final class FlagBox: @unchecked Sendable {
    private var flag = false
    private let lock = NSLock()
    func set() { lock.lock(); flag = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

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
