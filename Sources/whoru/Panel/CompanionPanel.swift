import AppKit
import SwiftUI
import WhoRUCore

/// The glass panel next to the dialog. Non-activating so Enter still reaches
/// the dialog's default button; floats above system dialogs; follows the
/// dialog; never shows an Allow button of its own.
@MainActor
final class CompanionPanel: NSPanel {
    static let width: CGFloat = 300
    static let maxHeight: CGFloat = 560
    static let gap: CGFloat = 12

    let session: ScanSession
    private var hosting: NSHostingView<CompanionRoot>!
    private var dialogFrame: Rect?
    private var userOffset: CGPoint?
    private var contentHeight: CGFloat = 160

    init(session: ScanSession, model: AppModel) {
        self.session = session
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 160),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        animationBehavior = .none
        isReleasedWhenClosed = false

        let root = CompanionRoot(session: session, model: model, onHeight: { [weak self] height in
            self?.updateHeight(height)
        }, onClose: { [weak self] in
            self?.fadeOut()
        })
        hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        contentView = hosting
    }

    // MARK: Placement

    /// Places the panel beside the dialog, on the side with more room, top edges aligned.
    func place(besideDialog frame: Rect, animated: Bool) {
        dialogFrame = frame
        guard let screen = screenContaining(frame) ?? NSScreen.main else { return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        // AX coordinates are top-left origin; AppKit is bottom-left of the primary screen.
        let dialogAppKit = NSRect(x: frame.x, y: primaryHeight - frame.y - frame.height, width: frame.width, height: frame.height)
        let visible = screen.visibleFrame
        let height = min(contentHeight, Self.maxHeight)
        var x: CGFloat
        let rightRoom = visible.maxX - dialogAppKit.maxX
        let leftRoom = dialogAppKit.minX - visible.minX
        if rightRoom >= Self.width + Self.gap * 2 || rightRoom >= leftRoom {
            x = dialogAppKit.maxX + Self.gap
        } else {
            x = dialogAppKit.minX - Self.gap - Self.width
        }
        x = max(visible.minX + 8, min(x, visible.maxX - Self.width - 8))
        var y = dialogAppKit.maxY - height
        y = max(visible.minY + 8, min(y, visible.maxY - height - 8))
        if let userOffset {
            x = dialogAppKit.maxX + userOffset.x
            y = dialogAppKit.maxY + userOffset.y - height
        }
        let target = NSRect(x: x, y: y, width: Self.width, height: height)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().setFrame(target, display: true)
            }
        } else {
            setFrame(target, display: true)
        }
    }

    /// For manual scans with no dialog: top-right of the main screen.
    func placeStandalone() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let height = min(contentHeight, Self.maxHeight)
        setFrame(NSRect(x: visible.maxX - Self.width - 16, y: visible.maxY - height - 16, width: Self.width, height: height), display: true)
    }

    private func screenContaining(_ frame: Rect) -> NSScreen? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let point = NSPoint(x: frame.x + frame.width / 2, y: primaryHeight - frame.y - frame.height / 2)
        return NSScreen.screens.first { $0.frame.contains(point) }
    }

    private func updateHeight(_ height: CGFloat) {
        let clamped = min(max(height, 120), Self.maxHeight)
        guard abs(clamped - contentHeight) > 0.5 else { return }
        contentHeight = clamped
        // Keep the top edge where it is.
        var frame = self.frame
        let top = frame.maxY
        frame.size.height = clamped
        frame.origin.y = top - clamped
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
            animator().setFrame(frame, display: true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        // Remember where the user put it relative to the dialog.
        if let dialogFrame {
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let dialogAppKit = NSRect(x: dialogFrame.x, y: primaryHeight - dialogFrame.y - dialogFrame.height, width: dialogFrame.width, height: dialogFrame.height)
            userOffset = CGPoint(x: frame.minX - dialogAppKit.maxX, y: frame.maxY - dialogAppKit.maxY)
        }
    }

    // MARK: Appearance

    func fadeIn() {
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.2 : 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    func fadeOut(completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
            completion?()
        })
    }

    /// When the dialog closes mid-conversation the panel stays, as a normal window.
    func becomeStandaloneWindow() {
        styleMask.insert(.titled)
        styleMask.insert(.closable)
        styleMask.insert(.miniaturizable)
        styleMask.remove(.nonactivatingPanel)
        title = session.subject?.displayName ?? session.prompt.requesterName
        titlebarAppearsTransparent = true
        titleVisibility = .visible
        level = .floating
        isFloatingPanel = false
        collectionBehavior = [.moveToActiveSpace]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Root view: injects the session and reports its natural height.
struct CompanionRoot: View {
    let session: ScanSession
    let model: AppModel
    let onHeight: (CGFloat) -> Void
    let onClose: () -> Void

    var body: some View {
        CompanionView(session: session, model: model, onClose: onClose)
            .frame(width: CompanionPanel.width)
            .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.height } action: { height in
                onHeight(height)
            }
    }
}
