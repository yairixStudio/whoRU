import AppKit
import ApplicationServices
import Foundation
import WhoRUCore

/// Watches the process that draws permission dialogs and reports each new
/// window's text and frame. Uses only the public Accessibility API: it reads,
/// it never presses anything.
public final class AXDialogWatcher: DialogWatcher, @unchecked Sendable {
    public let events: AsyncStream<DialogEvent>
    private let continuation: AsyncStream<DialogEvent>.Continuation

    /// Processes whose windows are permission dialogs. `UserNotificationCenter`
    /// draws TCC prompts; the list is configurable for future macOS versions.
    public let bundleIdentifiers: Set<String>
    private let pollInterval: TimeInterval

    private var observers: [pid_t: AXObserver] = [:]
    private var knownWindows: [String: (element: AXUIElement, pid: pid_t)] = [:]
    private var workspaceTokens: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    private var started = false

    public init(bundleIdentifiers: Set<String> = ["com.apple.UserNotificationCenter"], pollInterval: TimeInterval = 0.3) {
        self.bundleIdentifiers = bundleIdentifiers
        self.pollInterval = pollInterval
        var cont: AsyncStream<DialogEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        continuation = cont
    }

    public var isAuthorized: Bool { AXIsProcessTrusted() }

    // MARK: Lifecycle

    /// Must be called on the main thread: observers attach to the main run loop.
    public func start() throws {
        guard !started else { return }
        guard isAuthorized else { throw WatcherError.notAuthorized }
        dispatchPrecondition(condition: .onQueue(.main))
        started = true
        let center = NSWorkspace.shared.notificationCenter
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.consider(app)
        })
        workspaceTokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.detach(pid: app.processIdentifier)
        })
        for app in NSWorkspace.shared.runningApplications { consider(app) }
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    public func stop() {
        started = false
        pollTimer?.invalidate()
        pollTimer = nil
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceTokens.removeAll()
        for pid in Array(observers.keys) { detach(pid: pid) }
    }

    // MARK: Attaching to the dialog process

    private func consider(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier, bundleIdentifiers.contains(id) else { return }
        attach(pid: app.processIdentifier)
    }

    private func attach(pid: pid_t) {
        guard observers[pid] == nil else { return }
        var observer: AXObserver?
        let status = AXObserverCreate(pid, axCallback, &observer)
        guard status == .success, let observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let app = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(observer, app, kAXWindowCreatedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
        // Windows that already exist when we attach.
        for window in windows(of: pid) { handleWindow(window, pid: pid) }
    }

    private func detach(pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        for (id, entry) in knownWindows where entry.pid == pid {
            knownWindows[id] = nil
            continuation.yield(.closed(id: id))
        }
    }

    // MARK: Windows

    fileprivate func handleNotification(_ name: String, element: AXUIElement) {
        switch name {
        case kAXWindowCreatedNotification:
            if let pid = pid(of: element) { handleWindow(element, pid: pid) }
        case kAXUIElementDestroyedNotification:
            if let id = knownWindows.first(where: { CFEqual($0.value.element, element) })?.key {
                knownWindows[id] = nil
                continuation.yield(.closed(id: id))
            }
        case kAXMovedNotification, kAXResizedNotification:
            if let id = knownWindows.first(where: { CFEqual($0.value.element, element) })?.key, let frame = frame(of: element) {
                continuation.yield(.moved(id: id, frame: frame))
            }
        default:
            break
        }
    }

    private func handleWindow(_ window: AXUIElement, pid: pid_t) {
        guard !knownWindows.values.contains(where: { CFEqual($0.element, window) }) else { return }
        guard let frame = frame(of: window) else { return }
        let id = "\(pid)-\(CFHash(window))-\(Int(Date().timeIntervalSince1970 * 1000))"
        knownWindows[id] = (window, pid)
        if let observer = observers[pid] {
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, refcon)
            AXObserverAddNotification(observer, window, kAXMovedNotification as CFString, refcon)
            AXObserverAddNotification(observer, window, kAXResizedNotification as CFString, refcon)
        }
        let texts = staticTexts(in: window)
        let buttons = buttonTitles(in: window)
        let (title, body) = Self.pickTitleAndBody(texts)
        continuation.yield(.appeared(DialogInstance(id: id, pid: pid, frame: frame, title: title, body: body, buttons: buttons)))
    }

    /// Polling fallback for the case where AX notifications are late or missing.
    private func poll() {
        for pid in observers.keys {
            let current = windows(of: pid)
            for window in current { handleWindow(window, pid: pid) }
            for (id, entry) in knownWindows where entry.pid == pid {
                if !current.contains(where: { CFEqual($0, entry.element) }) {
                    knownWindows[id] = nil
                    continuation.yield(.closed(id: id))
                }
            }
        }
    }

    // MARK: AX helpers

    private func windows(of pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    private func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    private func frame(of element: AXUIElement) -> Rect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else { return nil }
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

    private func staticTexts(in element: AXUIElement, depth: Int = 0) -> [String] {
        guard depth < 8 else { return [] }
        var texts: [String] = []
        if attribute(kAXRoleAttribute, of: element) == kAXStaticTextRole, let value = attribute(kAXValueAttribute, of: element), !value.isEmpty {
            texts.append(value)
        }
        for child in children(of: element) { texts += staticTexts(in: child, depth: depth + 1) }
        return texts
    }

    private func buttonTitles(in element: AXUIElement, depth: Int = 0) -> [String] {
        guard depth < 8 else { return [] }
        var titles: [String] = []
        if attribute(kAXRoleAttribute, of: element) == kAXButtonRole, let title = attribute(kAXTitleAttribute, of: element), !title.isEmpty {
            titles.append(title)
        }
        for child in children(of: element) { titles += buttonTitles(in: child, depth: depth + 1) }
        return titles
    }

    /// The title is the text that names a requester; the body is the next one.
    static func pickTitleAndBody(_ texts: [String]) -> (String, String?) {
        let parser = PromptParser()
        if let index = texts.firstIndex(where: { parser.parse(title: $0) != nil }) {
            let body = texts.dropFirst(index + 1).first
            return (texts[index], body)
        }
        return (texts.first ?? "", texts.dropFirst().first)
    }
}

public enum WatcherError: Error, CustomStringConvertible {
    case notAuthorized
    public var description: String { "Accessibility permission not granted" }
}

private func axCallback(observer: AXObserver, element: AXUIElement, notification: CFString, refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let watcher = Unmanaged<AXDialogWatcher>.fromOpaque(refcon).takeUnretainedValue()
    watcher.handleNotification(notification as String, element: element)
}
