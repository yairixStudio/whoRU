import Foundation

/// A small file logger for diagnostics. One line per event, rotated at 2 MB,
/// with the most recent lines kept in memory for the diagnostics report.
/// Never logs secrets or file contents; callers pass summaries.
public final class AppLog: @unchecked Sendable {
    public enum Level: String, Comparable, Sendable {
        case debug, info, warn, error

        private var rank: Int {
            switch self {
            case .debug: 0
            case .info: 1
            case .warn: 2
            case .error: 3
            }
        }

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rank < rhs.rank }
    }

    public static let shared = AppLog()

    private let lock = NSLock()
    private var handle: FileHandle?
    private var recent: [String] = []
    private let recentLimit = 600
    private let rotateAt = 2 * 1024 * 1024
    private var bytesWritten = 0

    public private(set) var fileURL: URL?
    public var minimumLevel: Level = .info
    /// Also print to stderr (command line).
    public var echoToStderr = false

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// Points the log at a directory; creates it and rotates an oversized file.
    public func configure(directory: URL, fileName: String = "whoru.log") {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > rotateAt {
            let rotated = directory.appendingPathComponent(fileName.replacingOccurrences(of: ".log", with: ".1.log"))
            try? FileManager.default.removeItem(at: rotated)
            try? FileManager.default.moveItem(at: url, to: rotated)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle?.closeFile()
        handle = FileHandle(forWritingAtPath: url.path)
        handle?.seekToEndOfFile()
        bytesWritten = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        fileURL = url
    }

    public func debug(_ category: String, _ message: @autoclosure () -> String) { log(.debug, category, message()) }
    public func info(_ category: String, _ message: @autoclosure () -> String) { log(.info, category, message()) }
    public func warn(_ category: String, _ message: @autoclosure () -> String) { log(.warn, category, message()) }
    public func error(_ category: String, _ message: @autoclosure () -> String) { log(.error, category, message()) }

    public func log(_ level: Level, _ category: String, _ message: String) {
        guard level >= minimumLevel else { return }
        let line = "\(formatter.string(from: Date())) \(level.rawValue.uppercased().padding(toLength: 5, withPad: " ", startingAt: 0)) [\(category)] \(message)"
        lock.lock()
        recent.append(line)
        if recent.count > recentLimit { recent.removeFirst(recent.count - recentLimit) }
        if let handle, let data = (line + "\n").data(using: .utf8) {
            handle.write(data)
            bytesWritten += data.count
            if bytesWritten > rotateAt, let fileURL {
                let dir = fileURL.deletingLastPathComponent()
                let name = fileURL.lastPathComponent
                lock.unlock()
                configure(directory: dir, fileName: name)
                lock.lock()
            }
        }
        let echo = echoToStderr
        lock.unlock()
        if echo { FileHandle.standardError.write(Data((line + "\n").utf8)) }
    }

    public func recentLines(_ count: Int = 300) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(recent.suffix(count))
    }
}

/// Milliseconds since a start date, for log lines.
public func elapsedMs(since start: Date) -> Int {
    Int(Date().timeIntervalSince(start) * 1000)
}
