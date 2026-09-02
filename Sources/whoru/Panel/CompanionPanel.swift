import AppKit
import SwiftUI
import WhoRUCore

/// The glass panel next to the dialog. Non-activating so Enter still reaches
/// the dialog's default button; floats above system dialogs; follows the
/// dialog; never shows an Allow button of its own.
@MainActor
final class CompanionPanel: NSPanel {
    static let width: CGFloat = 300
    static let maxHeight: CGFloat = 600
    static let gap: CGFloat = 12

    let session: ScanSession
    private var hosting: NSHostingView<CompanionRoot>!
    private var dialogFrame: Rect?
    private var userOffset: CGPoint?
    private var contentHeight: CGFloat = 150

    init(session: ScanSession, model: AppModel) {
        self.session = session
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 150),
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
        // Resizes happen every animation frame while content grows; keep them cheap.
        displaysWhenScreenProfileChanges = false

        let root = CompanionRoot(session: session, model: model, onHeight: { [weak self] height in
            self?.updateHeight(height)
        }, onClose: { [weak self] in
            self?.fadeOut()
        })
        hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }

    // MARK: Placement

    /// Places the panel beside the dialog, on the side with more room, top
    /// edges aligned. Called for every move of the dialog, so it must be
    /// instant: no animation, one frame update.
    func place(besideDialog frame: Rect) {
        dialogFrame = frame
        setFrame(targetFrame(besideDialog: frame, height: currentHeight), display: true)
    }

    private var currentHeight: CGFloat { min(contentHeight, Self.maxHeight) }

    private func targetFrame(besideDialog frame: Rect, height: CGFloat) -> NSRect {
        guard let screen = screenContaining(frame) ?? NSScreen.main else { return self.frame }
        let dialogAppKit = Self.appKitRect(frame)
        let visible = screen.visibleFrame
        var x: CGFloat
        var y: CGFloat
        if let userOffset {
            x = dialogAppKit.maxX + userOffset.x
            y = dialogAppKit.maxY + userOffset.y - height
        } else {
            let rightRoom = visible.maxX - dialogAppKit.maxX
            let leftRoom = dialogAppKit.minX - visible.minX
            x = (rightRoom >= Self.width + Self.gap * 2 || rightRoom >= leftRoom)
                ? dialogAppKit.maxX + Self.gap
                : dialogAppKit.minX - Self.gap - Self.width
            y = dialogAppKit.maxY - height
        }
        x = max(visible.minX + 8, min(x, visible.maxX - Self.width - 8))
        y = max(visible.minY + 8, min(y, visible.maxY - height - 8))
        return NSRect(x: x, y: y, width: Self.width, height: height)
    }

    /// For manual scans with no dialog: top-right of the main screen.
    func placeStandalone() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        setFrame(NSRect(x: visible.maxX - Self.width - 16, y: visible.maxY - currentHeight - 16, width: Self.width, height: currentHeight), display: true)
    }

    private static func appKitRect(_ frame: Rect) -> NSRect {
        // AX and the window list use a top-left origin on the primary display; AppKit uses bottom-left.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: frame.x, y: primaryHeight - frame.y - frame.height, width: frame.width, height: frame.height)
    }

    private func screenContaining(_ frame: Rect) -> NSScreen? {
        let rect = Self.appKitRect(frame)
        let point = NSPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(point) }
    }

    /// The content reports its natural height on every layout pass, including
    /// each frame of an expanding disclosure. The window follows immediately,
    /// keeping its top edge fixed, so the content is never taller than the window.
    private func updateHeight(_ height: CGFloat) {
        let clamped = min(max(height.rounded(.up), 120), Self.maxHeight)
        guard clamped != contentHeight else { return }
        contentHeight = clamped
        if let dialogFrame, !session.dialogClosed {
            setFrame(targetFrame(besideDialog: dialogFrame, height: clamped), display: true)
        } else {
            var frame = self.frame
            let top = frame.maxY
            frame.size.height = clamped
            frame.origin.y = top - clamped
            setFrame(frame, display: true)
        }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        // Remember where the user put it relative to the dialog.
        if let dialogFrame {
            let dialogAppKit = Self.appKitRect(dialogFrame)
            userOffset = CGPoint(x: frame.minX - dialogAppKit.maxX, y: frame.maxY - dialogAppKit.maxY)
        }
    }

    // MARK: Appearance

    func fadeIn() {
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.15 : 0.25
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

/// Root view: measures the content's natural height and shows a scroll view
/// only when it would not fit the panel's maximum height.
struct CompanionRoot: View {
    let session: ScanSession
    let model: AppModel
    let onHeight: (CGFloat) -> Void
    let onClose: () -> Void

    @State private var naturalHeight: CGFloat = 150

    var body: some View {
        ScrollView(.vertical, showsIndicators: naturalHeight > CompanionPanel.maxHeight) {
            CompanionView(session: session, model: model, onClose: onClose)
                .frame(width: CompanionPanel.width)
                .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.height } action: { height in
                    naturalHeight = height
                    onHeight(height)
                }
        }
        .scrollDisabled(naturalHeight <= CompanionPanel.maxHeight)
        .frame(width: CompanionPanel.width, height: min(naturalHeight, CompanionPanel.maxHeight))
    }
}
