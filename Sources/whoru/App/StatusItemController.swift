import AppKit
import Foundation
import WhoRUCore

/// The menu-bar item, done the classic way: an NSStatusItem with an NSMenu.
/// It opens on the first click on every Space and its icon can carry a badge.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let item: NSStatusItem
    private let menu = NSMenu()
    private var refreshTimer: Timer?

    init(model: AppModel) {
        self.model = model
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.button?.image = Self.icon(paused: false)
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "whoRU"
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        rebuild()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateIcon() }
        }
    }

    func updateIcon() {
        item.button?.image = Self.icon(paused: model.isPaused)
        item.button?.toolTip = model.isPaused ? "whoRU · paused" : "whoRU"
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild()
    }

    private func rebuild() {
        menu.removeAllItems()

        if let last = model.lastSession {
            let name = last.subject?.displayName ?? last.prompt.requesterName
            let title = last.displayedHeadline.map { "\(name): \($0.title)" } ?? "\(name): checking…"
            let entry = NSMenuItem(title: title, action: #selector(showLast), keyEquivalent: "")
            entry.target = self
            entry.image = NSImage(systemSymbolName: last.presentation.symbol, accessibilityDescription: nil)
            menu.addItem(entry)
            menu.addItem(.separator())
        }

        add("History…", #selector(showHistory), key: "h", modifiers: [.command, .option])
        add("Check an App or File…", #selector(checkFile), key: "")
        let test = add("Show a Test Dialog", #selector(testDialog), key: "")
        test.isEnabled = model.accessibilityGranted
        if model.isPaused {
            add("Resume Watching", #selector(resume), key: "")
        } else {
            add("Pause for an Hour", #selector(pause), key: "")
        }
        menu.addItem(.separator())

        let status = NSMenuItem(title: model.accessibilityGranted ? model.engineDescription : "Accessibility permission needed", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        add("Setup Assistant…", #selector(setup), key: "")
        add("Settings…", #selector(settings), key: ",", modifiers: [.command])
        menu.addItem(.separator())
        add("Quit whoRU", #selector(quit), key: "q", modifiers: [.command])
    }

    @discardableResult
    private func add(_ title: String, _ action: Selector, key: String, modifiers: NSEvent.ModifierFlags = []) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.keyEquivalentModifierMask = modifiers
        entry.target = self
        menu.addItem(entry)
        return entry
    }

    // MARK: Actions

    @objc private func showLast() {
        if let last = model.lastSession { AppDelegate.shared?.showPanel(for: last) }
    }

    @objc private func showHistory() { AppDelegate.shared?.showHistory() }
    @objc private func checkFile() { AppDelegate.shared?.showManualScan() }
    @objc private func testDialog() { AppDelegate.shared?.triggerDemoPrompt() }
    @objc private func setup() { AppDelegate.shared?.showOnboarding() }
    @objc private func settings() { AppDelegate.shared?.showSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func pause() {
        model.pausedUntil = Date().addingTimeInterval(3600)
        AppLog.shared.info("app", "paused for an hour")
        updateIcon()
    }

    @objc private func resume() {
        model.pausedUntil = nil
        AppLog.shared.info("app", "resumed")
        updateIcon()
    }

    // MARK: Icon

    /// A template image: the symbol alone, or dimmed with a small pause badge.
    static func icon(paused: Bool) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        guard let base = NSImage(systemSymbolName: "person.fill.questionmark", accessibilityDescription: "whoRU")?.withSymbolConfiguration(config) else { return nil }
        guard paused, let badge = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 7, weight: .black)) else {
            base.isTemplate = true
            return base
        }
        let size = NSSize(width: base.size.width + 4, height: base.size.height)
        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(in: NSRect(origin: .zero, size: base.size), from: .zero, operation: .sourceOver, fraction: 0.45)
            let badgeRect = NSRect(x: rect.maxX - badge.size.width, y: 0, width: badge.size.width, height: badge.size.height)
            // Punch a small halo so the badge stays legible over the dimmed symbol.
            if let context = NSGraphicsContext.current {
                let previous = context.compositingOperation
                context.compositingOperation = .destinationOut
                NSColor.black.setFill()
                NSBezierPath(ovalIn: badgeRect.insetBy(dx: -1.5, dy: -1.5)).fill()
                context.compositingOperation = previous
            }
            badge.draw(in: badgeRect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "whoRU, paused"
        return image
    }
}
