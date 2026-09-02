import AppKit
import Observation
import SwiftUI
import WhoRUCore

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
        setFrame(target, display: true)
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
        presentation.anchor = .top
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
        presentation.visible = false
        let delay = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.15 : 0.2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.orderOut(nil)
            completion?()
        }
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
