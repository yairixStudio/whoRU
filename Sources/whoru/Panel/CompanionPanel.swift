import AppKit
import Observation
import QuartzCore
import SwiftUI
import WhoRUCore
import WhoRUMac

/// Drives the appear and dismiss motion of a panel, the way system panels
/// move: a short spring in, scaling from the edge that faces the dialog, and
/// a quick fade-and-shrink out.
@MainActor
@Observable
final class PanelPresentation {
    var visible = false
    /// Where the panel grows from: the edge facing the dialog.
    var anchor: UnitPoint = .topLeading
}

/// The glass panel next to the dialog. Non-activating so Enter still reaches
/// the dialog's default button; floats above system dialogs; follows the
/// dialog; never shows an Allow button of its own.
@MainActor
final class CompanionPanel: NSPanel {
    static let width: CGFloat = 300
    static let maxHeight: CGFloat = 600
    static let gap: CGFloat = 12

    let session: ScanSession
    let presentation = PanelPresentation()
    private var hosting: NSHostingView<CompanionRoot>!
    private var dialogFrame: Rect?
    private var userOffset: CGPoint?
    private var contentHeight: CGFloat = 150
    private var displayLink: CADisplayLink?
    private var followedWindow: Int?

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
        displaysWhenScreenProfileChanges = false
        NotificationCenter.default.addObserver(self, selector: #selector(didMove), name: NSWindow.didMoveNotification, object: self)

        let root = CompanionRoot(session: session, model: model, presentation: presentation, onHeight: { [weak self] height in
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
        let target = targetFrame(besideDialog: frame, height: currentHeight)
        presentation.anchor = target.minX >= Self.appKitRect(frame).maxX ? .topLeading : .topTrailing
        apply(target)
    }

    private var currentHeight: CGFloat { min(contentHeight, Self.maxHeight) }

    /// Where the panel goes for a given dialog frame. Candidates in order:
    /// where the user last put it, right, left, below, above. The first one
    /// that stays on screen without covering the dialog wins; the panel must
    /// never hide the buttons it is explaining.
    private func targetFrame(besideDialog frame: Rect, height: CGFloat) -> NSRect {
        guard let screen = screenContaining(frame) ?? NSScreen.main else { return self.frame }
        let dialog = Self.appKitRect(frame)
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let size = NSSize(width: Self.width, height: height)
        let keepOut = dialog.insetBy(dx: -Self.gap / 2, dy: -Self.gap / 2)

        var candidates: [NSRect] = []
        if let userOffset {
            candidates.append(NSRect(origin: NSPoint(x: dialog.maxX + userOffset.x, y: dialog.maxY + userOffset.y - height), size: size))
        }
        let right = NSRect(x: dialog.maxX + Self.gap, y: dialog.maxY - height, width: size.width, height: size.height)
        let left = NSRect(x: dialog.minX - Self.gap - Self.width, y: dialog.maxY - height, width: size.width, height: size.height)
        let below = NSRect(x: dialog.midX - Self.width / 2, y: dialog.minY - Self.gap - height, width: size.width, height: size.height)
        let above = NSRect(x: dialog.midX - Self.width / 2, y: dialog.maxY + Self.gap, width: size.width, height: size.height)
        let rightRoom = visible.maxX - dialog.maxX
        let leftRoom = dialog.minX - visible.minX
        candidates += rightRoom >= leftRoom ? [right, left, below, above] : [left, right, below, above]

        for candidate in candidates {
            // Slide vertically to stay on screen; that never causes overlap on the sides.
            var rect = candidate
            rect.origin.y = max(visible.minY, min(rect.origin.y, visible.maxY - height))
            if visible.contains(rect), !rect.intersects(keepOut) { return rect }
        }
        // Nothing fits cleanly (tiny screen): clamp the preferred side on screen.
        var rect = candidates.first ?? right
        rect.origin.x = max(visible.minX, min(rect.origin.x, visible.maxX - Self.width))
        rect.origin.y = max(visible.minY, min(rect.origin.y, visible.maxY - height))
        return rect
    }

    // MARK: Following a dragged dialog

    /// Reads the dialog's bounds once per display refresh and moves the panel
    /// with `setFrameOrigin`, which changes position only: no layout, no
    /// redraw, no event queue in between. This is what makes a drag feel
    /// attached rather than towed.
    func follow(windowID: Int) {
        stopFollowing()
        followedWindow = windowID
        guard let view = contentView else { return }
        let link = view.displayLink(target: self, selector: #selector(followTick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stopFollowing() {
        displayLink?.invalidate()
        displayLink = nil
        followedWindow = nil
    }

    var isFollowing: Bool { displayLink != nil }

    @objc private func followTick() {
        guard let followedWindow, let bounds = AXDialogWatcher.bounds(ofWindow: followedWindow) else { return }
        guard bounds != dialogFrame else { return }
        dialogFrame = bounds
        let target = targetFrame(besideDialog: bounds, height: currentHeight)
        repositioning = true
        if target.size == frame.size {
            setFrameOrigin(target.origin)
        } else {
            setFrame(target, display: true)
        }
        repositioning = false
    }

    /// For a panel with no dialog to sit next to (a manual scan, the last
    /// scan reopened from the menu): where the user last left such a panel,
    /// else the top-right of the main screen.
    func placeStandalone() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        presentation.anchor = .top
        var rect = NSRect(x: visible.maxX - Self.width - 16, y: visible.maxY - currentHeight - 16, width: Self.width, height: currentHeight)
        if let topLeft = Self.standaloneTopLeft, NSScreen.screens.contains(where: { $0.visibleFrame.contains(topLeft) }) {
            rect.origin = NSPoint(x: topLeft.x, y: topLeft.y - currentHeight)
        }
        apply(rect)
    }

    /// Moves the panel from code. Distinguishes our own placement from the
    /// user dragging it, which `didMove` records.
    private func apply(_ rect: NSRect) {
        repositioning = true
        setFrame(rect, display: true)
        repositioning = false
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
            apply(targetFrame(besideDialog: dialogFrame, height: clamped))
        } else {
            var frame = self.frame
            let top = frame.maxY
            frame.size.height = clamped
            frame.origin.y = top - clamped
            apply(frame)
        }
    }

    // MARK: Dragging

    /// The panel can be dragged from its header and its top rows (a
    /// `WindowDragGesture` in the content) and from any background (the
    /// window's own background-move). Both end up here.
    private var repositioning = false
    /// Where the user last left a panel that had no dialog next to it: top-left corner.
    private static var standaloneTopLeft: NSPoint?

    /// A move while the mouse button is down, and not made by our own
    /// placement, is the user dragging: remember where they put it, relative
    /// to the dialog, or on its own when there is none.
    @objc private func didMove(_ note: Notification) {
        guard !repositioning, NSEvent.pressedMouseButtons & 1 != 0 else { return }
        if let dialogFrame, !session.dialogClosed {
            let dialog = Self.appKitRect(dialogFrame)
            userOffset = CGPoint(x: frame.minX - dialog.maxX, y: frame.maxY - dialog.maxY)
        } else {
            Self.standaloneTopLeft = NSPoint(x: frame.minX, y: frame.maxY)
        }
    }

    // MARK: Appearance

    /// Shows the panel: the window is on screen at once, and the content
    /// springs in from the dialog's edge (fade + scale), or just fades when
    /// Reduce Motion is on.
    func fadeIn() {
        alphaValue = 1
        presentation.visible = false
        orderFrontRegardless()
        DispatchQueue.main.async { [presentation] in
            presentation.visible = true
        }
    }

    /// Hides it: content fades and shrinks slightly, then the window goes away.
    func fadeOut(completion: (() -> Void)? = nil) {
        stopFollowing()
        presentation.visible = false
        let delay = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.15 : 0.2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.orderOut(nil)
            completion?()
        }
    }

    /// When the dialog closes mid-conversation the panel stays, as a normal window.
    func becomeStandaloneWindow() {
        stopFollowing()
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

/// Root view: measures the content's natural height, shows a scroll view
/// only when it would not fit the panel's maximum height, and plays the
/// appear and dismiss motion.
struct CompanionRoot: View {
    let session: ScanSession
    let model: AppModel
    let presentation: PanelPresentation
    let onHeight: (CGFloat) -> Void
    let onClose: () -> Void

    @State private var contentHeight: CGFloat = 120
    @State private var headerHeight: CGFloat = 30
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
    private var total: CGFloat { headerHeight + contentHeight }
    private var scrolls: Bool { total > CompanionPanel.maxHeight }

    var body: some View {
        VStack(spacing: 0) {
            CompanionHeader(session: session, onClose: onClose)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    headerHeight = height
                    onHeight(height + contentHeight)
                }
            ScrollView(.vertical, showsIndicators: scrolls) {
                CompanionView(session: session, model: model, onClose: onClose)
                    .frame(width: CompanionPanel.width)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        contentHeight = height
                        onHeight(headerHeight + height)
                    }
            }
            .scrollDisabled(!scrolls)
        }
        .frame(width: CompanionPanel.width, height: min(total, CompanionPanel.maxHeight))
        .clipShape(shape)
        .glassEffect(.regular, in: shape)
        .overlay {
            if contrast == .increased {
                shape.stroke(.separator, lineWidth: 1)
            }
        }
        .opacity(presentation.visible ? 1 : 0)
        .scaleEffect(presentation.visible || reduceMotion ? 1 : 0.94, anchor: presentation.anchor)
        .animation(presentation.visible
                   ? (reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.32, bounce: 0.18))
                   : .easeOut(duration: reduceMotion ? 0.15 : 0.18),
                   value: presentation.visible)
    }
}
