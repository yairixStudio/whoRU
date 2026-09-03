import Foundation

/// A platform-neutral rectangle in screen points, origin top-left.
public struct Rect: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct RunningProcess: Sendable, Hashable, Codable {
    public var pid: Int32
    public var ppid: Int32
    /// Absolute path of the executable.
    public var path: String
    /// Last path component of `path`.
    public var name: String
    public var bundleID: String?
    /// The name the system shows for an application, when it is one.
    public var localizedName: String?
    public var isApplication: Bool
    public var startedAt: Date?

    public init(pid: Int32, ppid: Int32, path: String, bundleID: String? = nil, localizedName: String? = nil, isApplication: Bool = false, startedAt: Date? = nil) {
        self.pid = pid
        self.ppid = ppid
        self.path = path
        self.name = (path as NSString).lastPathComponent
        self.bundleID = bundleID
        self.localizedName = localizedName
        self.isApplication = isApplication
        self.startedAt = startedAt
    }
}

/// Process listing. macOS: libproc + NSWorkspace. Windows: Toolhelp.
public protocol ProcessInspector: Sendable {
    func runningProcesses() async throws -> [RunningProcess]
    /// The chain from `pid` upwards, starting with the process itself.
    func parentChain(of pid: Int32) async throws -> [RunningProcess]
}

/// Finds installed applications by display name (Launch Services, Spotlight,
/// the Start menu...). Returns bundle or executable paths.
public protocol ApplicationFinder: Sendable {
    func applications(named name: String) async throws -> [String]
}

/// Who drew a dialog window. Any program can draw a window that reads like a
/// permission prompt; only the platform's own dialog process can put a real
/// one on screen. The watcher settles this from facts a program cannot forge
/// (the window's owner process and that process's code signature), so that a
/// panel is never a green badge next to an impostor.
public enum DialogOrigin: Sendable, Hashable, Codable {
    /// Drawn by a platform process known to show permission prompts.
    case system(bundleID: String)
    /// Drawn by something else: the owner's name, its executable and a
    /// summary of who signed it, for the panel to show.
    case unverified(owner: String, path: String?, signer: String?)

    public var isSystem: Bool {
        if case .system = self { return true }
        return false
    }
}

/// A permission dialog as observed on screen.
public struct DialogInstance: Sendable, Hashable {
    public var id: String
    public var pid: Int32
    public var frame: Rect
    public var title: String
    public var body: String?
    public var buttons: [String]
    /// The platform's window handle (CGWindowID on macOS), so a companion can
    /// follow the window directly at display rate.
    public var nativeWindowID: Int?
    public var origin: DialogOrigin

    public init(id: String, pid: Int32, frame: Rect, title: String, body: String? = nil, buttons: [String] = [], nativeWindowID: Int? = nil, origin: DialogOrigin = .system(bundleID: "")) {
        self.id = id
        self.pid = pid
        self.frame = frame
        self.title = title
        self.body = body
        self.buttons = buttons
        self.nativeWindowID = nativeWindowID
        self.origin = origin
    }
}

public enum DialogEvent: Sendable, Hashable {
    case appeared(DialogInstance)
    case moved(id: String, frame: Rect)
    case closed(id: String)
}

/// Watches for permission dialogs. The macOS implementation uses the
/// Accessibility API; other platforms use whatever lets them observe consent
/// prompts. Events arrive on `events`.
public protocol DialogWatcher: AnyObject, Sendable {
    var events: AsyncStream<DialogEvent> { get }
    /// Whether the platform permission needed to observe dialogs is granted.
    var isAuthorized: Bool { get }
    func start() throws
    func stop()
}

/// Fields read from an application bundle's metadata (Info.plist on macOS,
/// VERSIONINFO on Windows). The core reads Apple property lists itself since
/// `PropertyListSerialization` is portable Foundation.
public struct BundleInfo: Sendable, Hashable, Codable {
    public var bundlePath: String
    public var identifier: String?
    public var displayName: String?
    public var shortVersion: String?
    public var build: String?
    public var executable: String?
    /// `NS*UsageDescription` strings, keyed by their plist key. Hostile text.
    public var usageDescriptions: [String: String]
    public var isAgent: Bool

    public init(bundlePath: String, identifier: String? = nil, displayName: String? = nil, shortVersion: String? = nil, build: String? = nil, executable: String? = nil, usageDescriptions: [String: String] = [:], isAgent: Bool = false) {
        self.bundlePath = bundlePath
        self.identifier = identifier
        self.displayName = displayName
        self.shortVersion = shortVersion
        self.build = build
        self.executable = executable
        self.usageDescriptions = usageDescriptions
        self.isAgent = isAgent
    }

    /// The outermost `.app` (or `.xpc`, `.appex`) bundle containing `path`, if any.
    public static func enclosingBundlePath(of path: String) -> String? {
        var components = (path as NSString).pathComponents
        var found: String?
        while !components.isEmpty {
            let candidate = NSString.path(withComponents: components)
            if let ext = Self.bundleExtension(of: candidate), ["app", "xpc", "appex"].contains(ext) {
                found = candidate
            }
            components.removeLast()
        }
        return found
    }

    private static func bundleExtension(of path: String) -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }

    public static func read(bundlePath: String) -> BundleInfo? {
        let plistURL = URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        var usage: [String: String] = [:]
        for (key, value) in plist where key.hasPrefix("NS") && key.hasSuffix("UsageDescription") {
            if let text = value as? String { usage[key] = text }
        }
        return BundleInfo(
            bundlePath: bundlePath,
            identifier: plist["CFBundleIdentifier"] as? String,
            displayName: (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String),
            shortVersion: plist["CFBundleShortVersionString"] as? String,
            build: plist["CFBundleVersion"] as? String,
            executable: plist["CFBundleExecutable"] as? String,
            usageDescriptions: usage,
            isAgent: (plist["LSUIElement"] as? Bool) ?? ((plist["LSUIElement"] as? String) == "1")
        )
    }

    /// Reads the bundle that contains `path`, if there is one.
    public static func read(containing path: String) -> BundleInfo? {
        guard let bundlePath = enclosingBundlePath(of: path) else { return nil }
        return read(bundlePath: bundlePath)
    }
}
