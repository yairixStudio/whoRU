import AppKit
import OSLog
import SwiftUI
import UserNotifications
import WhoRUCore
import WhoRUMac

/// `log stream --predicate 'subsystem == "com.yairixstudio.whoru"'` shows what the app sees.
let log = Logger(subsystem: WhoRUMac.bundleIdentifier, category: "app")

private struct SettingsOpener: View {
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Color.clear.onAppear { openSettings() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate?

    let model = AppModel()
    private var statusItem: StatusItemController?
    private var watcher: AXDialogWatcher?
    private var panels: [String: CompanionPanel] = [:]
    private var closeTimers: [String: Task<Void, Never>] = [:]
    private var historyWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var permissionTimer: Timer?

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppLog.shared.configure(directory: AppModel.logDirectory)
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        AppLog.shared.info("app", "whoRU \(version) (\(build)) launched on macOS \(ProcessInfo.processInfo.operatingSystemVersionString) from \(Bundle.main.bundlePath) · accessibility \(AccessibilityPermission.isGranted ? "granted" : "not granted") · args \(CommandLine.arguments.dropFirst().joined(separator: " "))")
        model.applyLaunchAtLogin()
        statusItem = StatusItemController(model: model)
        warmUpPanel()
        if !model.settings.onboardingCompleted || !AccessibilityPermission.isGranted || CommandLine.arguments.contains("--onboarding") {
            showOnboarding()
        }
        startWatcherIfPossible()
        // `open whoRU.app --args --scan <path>` opens a standalone panel at once (development, screenshots).
        let args = CommandLine.arguments
        if args.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.showSettings() }
        }
        if args.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.triggerDemoPrompt() }
        }
        if let index = args.firstIndex(of: "--scan"), index + 1 < args.count {
            let service = args.firstIndex(of: "--service").flatMap { $0 + 1 < args.count ? PermissionService(shortName: args[$0 + 1]) : nil } ?? .other
            scanManually((args[index + 1] as NSString).expandingTildeInPath, service: service)
        }
        // Accessibility can be granted while we run; pick it up without a restart.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let granted = AccessibilityPermission.isGranted
                if granted != self.model.accessibilityGranted {
                    self.model.accessibilityGranted = granted
                    AppLog.shared.info("app", "accessibility \(granted ? "granted" : "revoked")")
                }
                if granted { self.startWatcherIfPossible() }
                self.statusItem?.updateIcon()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Builds one panel offscreen at launch so that fonts, symbols, the glass
    /// material and the SwiftUI runtime are warm when the first dialog appears.
    private func warmUpPanel() {
        let prompt = PermissionPrompt(title: "", requesterName: "whoRU", service: .other, requestPhrase: "")
        let session = ScanSession(id: "warm-up", dialog: nil, prompt: prompt, rawTitle: "")
        let panel = CompanionPanel(session: session, model: model)
        panel.setFrame(NSRect(x: -10_000, y: -10_000, width: CompanionPanel.width, height: 150), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { panel.orderOut(nil) }
    }

    // MARK: Watching

    func startWatcherIfPossible() {
        guard watcher == nil, AccessibilityPermission.isGranted else { return }
        let watcher = AXDialogWatcher()
        do {
            try watcher.start()
        } catch {
            return
        }
        self.watcher = watcher
        model.watcherRunning = true
        log.info("watcher started")
        AppLog.shared.info("app", "watcher started")
        Task { [weak self] in
            for await event in watcher.events {
                await MainActor.run { self?.handle(event) }
            }
        }
    }

    private func handle(_ event: DialogEvent) {
        switch event {
        case .appeared(let dialog):
            log.info("dialog appeared: \(dialog.title, privacy: .public) at \(dialog.frame.x, privacy: .public),\(dialog.frame.y, privacy: .public)")
            guard model.settings.showNextToDialogs, !model.isPaused else { return }
            let session = model.startScan(for: dialog)
            guard model.settings.isEnabled(session.prompt.service) else {
                model.dismiss(session)
                return
            }
            let panel = CompanionPanel(session: session, model: model)
            panel.place(besideDialog: dialog.frame)
            panel.fadeIn()
            panels[dialog.id] = panel
            AppLog.shared.info("app", "panel shown for “\(session.prompt.requesterName)” · \(session.prompt.service.shortName) at \(Int(panel.frame.minX)),\(Int(panel.frame.minY))")
        case .moved(let id, let frame):
            panels[id]?.place(besideDialog: frame)
        case .closed(let id):
            log.info("dialog closed: \(id, privacy: .public)")
            guard let panel = panels[id] else { return }
            let session = panel.session
            session.dialogClosed = true
            // The user answered; the panel goes with the dialog. A conversation
            // in progress keeps it, as a normal window.
            if session.chatActive {
                panel.becomeStandaloneWindow()
                panels[id] = nil
                return
            }
            scheduleClose(id: id, after: 0.35)
        }
    }

    private func scheduleClose(id: String, after seconds: Double) {
        closeTimers[id]?.cancel()
        closeTimers[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, let panel = self.panels[id] else { return }
            if panel.session.chatActive {
                panel.becomeStandaloneWindow()
                self.panels[id] = nil
                return
            }
            let session = panel.session
            panel.fadeOut { [weak self] in
                Task { @MainActor in
                    self?.panels[id] = nil
                    self?.model.dismiss(session)
                }
            }
        }
    }

    // MARK: Manual scan

    func showManualScan() {
        let open = NSOpenPanel()
        open.canChooseFiles = true
        open.canChooseDirectories = true
        open.allowsMultipleSelection = false
        open.treatsFilePackagesAsDirectories = false
        open.message = "Choose an app or program. whoRU checks who made it and whether it is what it claims: signature, notarization, origin, location. It is not a virus scan."
        open.prompt = "Check"
        NSApp.activate(ignoringOtherApps: true)
        guard open.runModal() == .OK, let url = open.url else { return }
        scanManually(url.path)
    }

    func scanManually(_ path: String, service: PermissionService = .other) {
        let session = model.startManualScan(path: path, service: service)
        let panel = CompanionPanel(session: session, model: model)
        panel.placeStandalone()
        panel.fadeIn()
        panels[session.id] = panel
    }

    func showPanel(for session: ScanSession) {
        if let panel = panels[session.id] {
            panel.orderFrontRegardless()
            return
        }
        let panel = CompanionPanel(session: session, model: model)
        if let dialog = session.dialog, !session.dialogClosed {
            panel.place(besideDialog: dialog.frame)
        } else {
            panel.placeStandalone()
        }
        panel.fadeIn()
        panels[session.id] = panel
    }

    // MARK: Windows

    func showHistory() {
        if historyWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 540), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "History"
            window.titlebarAppearsTransparent = false
            window.contentView = NSHostingView(rootView: HistoryView(model: model))
            window.center()
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("whoRU.history")
            historyWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    /// Opens the SwiftUI Settings scene from AppKit code. The only public way
    /// in is the `openSettings` environment action, which needs a view, so a
    /// zero-size window hosts one for a moment.
    private var settingsOpener: NSWindow?

    func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        let window = NSWindow(contentRect: NSRect(x: -1000, y: -1000, width: 1, height: 1), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0
        window.contentView = NSHostingView(rootView: SettingsOpener())
        window.orderFront(nil)
        settingsOpener = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.settingsOpener?.close()
            self?.settingsOpener = nil
        }
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 540), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.contentView = NSHostingView(rootView: OnboardingView(model: model, finish: { [weak self] in
                self?.onboardingWindow?.close()
            }))
            window.center()
            window.isReleasedWhenClosed = false
            onboardingWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Demo

    /// Triggers a real permission dialog for whoRU itself, so the panel appears
    /// next to a genuine prompt. Requires a bundle identifier (a built .app).
    ///
    /// The file access must happen off the main thread: macOS blocks the
    /// calling thread until the user answers, and a blocked main thread would
    /// freeze the app, including the watcher that shows the panel.
    func triggerDemoPrompt() {
        let bundleID = Bundle.main.bundleIdentifier
        Task.detached(priority: .userInitiated) {
            if let bundleID {
                _ = try? await Command.run("/usr/bin/tccutil", ["reset", "SystemPolicyDownloadsFolder", bundleID], timeout: .seconds(5))
            }
            // Touching Downloads is what makes macOS ask.
            if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                _ = try? FileManager.default.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil)
            }
        }
    }
}
