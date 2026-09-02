import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog
import WhoRUCore

private let log = Logger(subsystem: WhoRUMac.bundleIdentifier, category: "watcher")

/// Watches for permission dialogs and reports each new one's text and frame.
///
/// It does not depend on knowing which system process draws the dialog, which
/// changes between macOS versions: the on-screen window list (no permission
/// needed) reveals every new window with its owner, layer and bounds; small,
/// alert-shaped windows are then read through the Accessibility API and kept
/// only when their text parses as a permission prompt. Reads only; never
/// presses anything.
public final class AXDialogWatcher: DialogWatcher, @unchecked Sendable {
    public let events: AsyncStream<DialogEvent>
    private let continuation: AsyncStream<DialogEvent>.Continuation

    /// Processes known to draw permission prompts. Windows from these are
    /// always inspected, whatever their size.
    public let bundleIdentifiers: Set<String>
    private let pollInterval: TimeInterval
    private let parser = PromptParser()

    private struct Tracked {
        var id: String
        var pid: pid_t
        var frame: Rect
    }

    private var tracked: [Int: Tracked] = [:]      // by window number
    private var ignored: Set<Int> = []              // windows inspected and found not to be prompts
    private var pollTimer: Timer?
    private var started = false
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    static let ignoredOwners: Set<String> = ["Window Server", "Dock", "WindowManager", "Wallpaper", "Notification Center", "Control Center", "Spotlight", "SystemUIServer", "MenuBarAgent"]

    public init(bundleIdentifiers: Set<String> = ["com.apple.UserNotificationCenter", "com.apple.CoreServicesUIAgent", "com.apple.SecurityAgent"], pollInterval: TimeInterval = 0.15) {
        self.bundleIdentifiers = bundleIdentifiers
        self.pollInterval = pollInterval
        var cont: AsyncStream<DialogEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        continuation = cont
    }

    public var isAuthorized: Bool { AXIsProcessTrusted() }

    // MARK: Lifecycle

    /// Must be called on the main thread: the poll timer lives on the main run loop.
    public func start() throws {
        guard !started else { return }
        guard isAuthorized else { throw WatcherError.notAuthorized }
        dispatchPrecondition(condition: .onQueue(.main))
        started = true
        // AX calls can block when the target app is busy; never wait long on the main thread.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        // Windows already on screen are not new, except prompts from known
        // dialog processes: a dialog that was open before we started still counts.
        for info in Self.onScreenWindows() where !isKnownPromptProcess(info.pid) { ignored.insert(info.number) }
        schedulePoll()
        log.info("polling the window list every \(Int(self.pollInterval * 1000), privacy: .public) ms")
    }

    /// Idle: the configured interval. While a dialog is on screen: fast, so the
    /// panel follows a dragged dialog at animation rate.
    private func schedulePoll() {
        pollTimer?.invalidate()
        let interval = tracked.isEmpty ? pollInterval : 1.0 / 60.0
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    public func stop() {
        started = false
        pollTimer?.invalidate()
        pollTimer = nil
        for (number, entry) in tracked {
            tracked[number] = nil
            continuation.yield(.closed(id: entry.id))
        }
    }

    // MARK: Polling

    struct WindowInfo {
        var number: Int
        var pid: pid_t
        var owner: String
        var layer: Int
        var frame: Rect
    }

    static func onScreenWindows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { w in
            guard let number = w[kCGWindowNumber as String] as? Int,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let bounds = w[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
                  let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double else { return nil }
            return WindowInfo(
                number: number, pid: pid,
                owner: w[kCGWindowOwnerName as String] as? String ?? "",
                layer: w[kCGWindowLayer as String] as? Int ?? 0,
                frame: Rect(x: x, y: y, width: width, height: height)
            )
        }
    }

    private func poll() {
        guard started else { return }
        if !AXIsProcessTrusted() {
            log.error("Accessibility permission was revoked; stopping")
            AppLog.shared.error("watcher", "Accessibility permission revoked; watcher stopped")
            stop()
            return
        }
        let hadTracked = !tracked.isEmpty
        let current = Self.onScreenWindows()
        let currentNumbers = Set(current.map(\.number))

        // Closed and moved.
        for (number, entry) in tracked {
            guard let info = current.first(where: { $0.number == number }) else {
                tracked[number] = nil
                log.info("window \(number, privacy: .public) gone")
                AppLog.shared.info("watcher", "prompt window \(number) closed")
                continuation.yield(.closed(id: entry.id))
                continue
            }
            if info.frame != entry.frame {
                tracked[number]?.frame = info.frame
                continuation.yield(.moved(id: entry.id, frame: info.frame))
            }
        }
        ignored = ignored.intersection(currentNumbers)

        // New.
        for info in current where tracked[info.number] == nil && !ignored.contains(info.number) {
            guard info.pid != ownPID, !Self.ignoredOwners.contains(info.owner) else { ignored.insert(info.number); continue }
            guard isCandidate(info) else { ignored.insert(info.number); continue }
            inspect(info)
        }

        if hadTracked != !tracked.isEmpty { schedulePoll() }
    }

    /// Cheap pre-filter so only alert-shaped windows are read through AX.
    private func isCandidate(_ info: WindowInfo) -> Bool {
        if let bundle = NSRunningApplication(processIdentifier: info.pid)?.bundleIdentifier, bundleIdentifiers.contains(bundle) { return true }
        if info.layer > 0 { return true }
        return info.frame.width >= 200 && info.frame.width <= 760 && info.frame.height >= 80 && info.frame.height <= 640
    }

    private func inspect(_ info: WindowInfo) {
        let started = Date()
        let known = isKnownPromptProcess(info.pid)
        guard let window = axWindow(pid: info.pid, matching: info.frame) else {
            // Not exposed through AX (yet). Try again on the next poll a few times, then give up.
            retries[info.number, default: 0] += 1
            if retries[info.number, default: 0] > 6 {
                retries[info.number] = nil
                log.info("window \(info.number, privacy: .public) of \(info.owner, privacy: .public) (layer \(info.layer, privacy: .public)) exposes no AX window")
                AppLog.shared.warn("watcher", "window \(info.number) of \(info.owner) (layer \(info.layer), \(Int(info.frame.width))×\(Int(info.frame.height))) exposes no AX window")
                if known {
                    // Still worth showing: the panel explains that the text could not be read.
                    emit(info, title: "", body: nil, buttons: [], started: started)
                } else {
                    ignored.insert(info.number)
                }
            }
            return
        }
        retries[info.number] = nil
        let texts = staticTexts(in: window)
        let buttons = buttonTitles(in: window)
        guard let index = texts.firstIndex(where: { parser.parse(title: $0) != nil }) else {
            log.info("window \(info.number, privacy: .public) of \(info.owner, privacy: .public): \(texts.count, privacy: .public) texts, \(buttons.count, privacy: .public) buttons, no prompt pattern matched: \(texts.joined(separator: " | "), privacy: .public)")
            if known {
                AppLog.shared.warn("watcher", "window of \(info.owner) had no recognizable prompt text (\(texts.count) texts): \(texts.joined(separator: " | ").prefix(200))")
            }
            if known {
                emit(info, title: texts.first ?? "", body: texts.dropFirst().first, buttons: buttons, started: started)
            } else {
                ignored.insert(info.number)
            }
            return
        }
        emit(info, title: texts[index], body: texts.dropFirst(index + 1).first, buttons: buttons, started: started)
    }

    private func isKnownPromptProcess(_ pid: pid_t) -> Bool {
        guard let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
        return bundleIdentifiers.contains(bundle)
    }

    private func emit(_ info: WindowInfo, title: String, body: String?, buttons: [String], started: Date) {
        let id = "\(info.pid)-\(info.number)"
        tracked[info.number] = Tracked(id: id, pid: info.pid, frame: info.frame)
        log.info("prompt in \(info.owner, privacy: .public) (pid \(info.pid, privacy: .public)) read in \(Int(Date().timeIntervalSince(started) * 1000), privacy: .public) ms: \(title, privacy: .public)")
        AppLog.shared.info("watcher", "prompt in \(info.owner) (pid \(info.pid), window \(info.number), layer \(info.layer)) read in \(elapsedMs(since: started)) ms: \(title.isEmpty ? "(no text)" : title)")
        continuation.yield(.appeared(DialogInstance(id: id, pid: info.pid, frame: info.frame, title: title, body: body, buttons: buttons)))
    }

    private var retries: [Int: Int] = [:]

    // MARK: AX helpers

    /// The AX window of `pid` whose frame matches, or the element under the
    /// window's centre as a fallback for processes that do not list windows.
    private func axWindow(pid: pid_t, matching frame: Rect) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        if status == .success, let windows = value as? [AXUIElement] {
            for window in windows {
                if let f = self.frame(of: window), abs(f.x - frame.x) < 6, abs(f.y - frame.y) < 6, abs(f.width - frame.width) < 6 {
                    return window
                }
            }
            if windows.count == 1 { return windows[0] }
            log.info("pid \(pid, privacy: .public): \(windows.count, privacy: .public) AX windows, none at \(Int(frame.x), privacy: .public),\(Int(frame.y), privacy: .public)")
        } else {
            log.info("pid \(pid, privacy: .public): AXWindows unavailable (AXError \(status.rawValue, privacy: .public))")
        }
        for name in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var single: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, name as CFString, &single) == .success, let single, CFGetTypeID(single) == AXUIElementGetTypeID() {
                return (single as! AXUIElement)
            }
        }
        // Fallback: hit-test a few points inside the window and walk up to its window element.
        let systemWide = AXUIElementCreateSystemWide()
        let points = [
            CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2),
            CGPoint(x: frame.x + frame.width / 2, y: frame.y + 24),
            CGPoint(x: frame.x + 24, y: frame.y + frame.height - 24),
        ]
        for point in points {
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success, var element = hit else { continue }
            var owner: pid_t = 0
            guard AXUIElementGetPid(element, &owner) == .success, owner == pid else { continue }
            var hops = 0
            while hops < 12 {
                hops += 1
                let role = attribute(kAXRoleAttribute, of: element)
                if role == kAXWindowRole || role == kAXSheetRole { return element }
                var window: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &window) == .success, let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
                    return (window as! AXUIElement)
                }
                var parent: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success, let p = parent, CFGetTypeID(p) == AXUIElementGetTypeID() else { break }
                element = p as! AXUIElement
            }
            return element
        }
        return nil
    }

    private func frame(of element: AXUIElement) -> Rect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else { return nil }
        guard CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point), AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return Rect(x: point.x, y: point.y, width: size.width, height: size.height)
    }

    private func attribute(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    private func staticTexts(in element: AXUIElement) -> [String] {
        var texts: [String] = []
        var budget = 400
        func walk(_ node: AXUIElement, depth: Int) {
            guard depth < 10, budget > 0 else { return }
            budget -= 1
            let role = attribute(kAXRoleAttribute, of: node)
            if role == kAXStaticTextRole, let value = attribute(kAXValueAttribute, of: node), !value.isEmpty {
                texts.append(value)
            }
            for child in children(of: node) { walk(child, depth: depth + 1) }
        }
        walk(element, depth: 0)
        return texts
    }

    private func buttonTitles(in element: AXUIElement) -> [String] {
        var titles: [String] = []
        var budget = 400
        func walk(_ node: AXUIElement, depth: Int) {
            guard depth < 10, budget > 0 else { return }
            budget -= 1
            if attribute(kAXRoleAttribute, of: node) == kAXButtonRole, let title = attribute(kAXTitleAttribute, of: node), !title.isEmpty {
                titles.append(title)
            }
            for child in children(of: node) { walk(child, depth: depth + 1) }
        }
        walk(element, depth: 0)
        return titles
    }
}

public enum WatcherError: Error, CustomStringConvertible {
    case notAuthorized
    public var description: String { "Accessibility permission not granted" }
}
