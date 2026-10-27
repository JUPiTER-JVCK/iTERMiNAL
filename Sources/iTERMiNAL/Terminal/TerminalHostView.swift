import SwiftUI
import AppKit
import SwiftTerm

/// Bridges a session's AppKit terminal view into SwiftUI, keeping appearance
/// in sync with settings and routing keyboard focus to the focused pane.
struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> TerminalContainerView {
        session.startIfNeeded()
        session.applyStyling(settings: settings, darkMode: colorScheme == .dark)
        let terminal = session.engine.view
        let container = TerminalContainerView(terminal: terminal)
        let sessionID = session.id
        DispatchQueue.main.async {
            if WorkspaceStore.shared.focusedSessionID == sessionID {
                terminal.window?.makeFirstResponder(terminal)
            }
        }
        return container
    }

    func updateNSView(_ nsView: TerminalContainerView, context: Context) {
        session.applyStyling(settings: settings, darkMode: colorScheme == .dark)
        nsView.syncBackground()
        let terminal = nsView.terminal
        let sessionID = session.id
        // Cheap synchronous filter before the hop. This method runs on every
        // layout pass, so during a resize it was queuing a block per frame per
        // terminal just to discover there was nothing to do. The hop still
        // happens in the case it exists for — the view not being in a window
        // yet — because that is exactly when `window` is nil and neither test
        // below short-circuits.
        if WorkspaceStore.shared.focusedSessionID != sessionID { return }
        if let window = terminal.window, window.firstResponder === terminal { return }
        DispatchQueue.main.async {
            guard WorkspaceStore.shared.focusedSessionID == sessionID,
                  let window = terminal.window,
                  window.firstResponder !== terminal else { return }
            // Claim focus only from the window itself or another terminal —
            // never from a text field the user is typing in (composer, URL bar).
            let responder = window.firstResponder
            guard responder === window || responder is LocalProcessTerminalView else { return }
            window.makeFirstResponder(terminal)
        }
    }
}

/// Whether a panel or dock seam is being dragged right now.
///
/// While one is, terminals keep the size they had and catch up once, when the
/// drag ends. Resizing them live was what made the side panel stutter: every
/// few points of travel changed the column count, and SwiftTerm answers each
/// change by reflowing its buffer and sending the program SIGWINCH. A shell
/// shrugs that off, but btop and superfile redraw their entire screen on
/// every one — tens of kilobytes of escape sequences, parsed on the main
/// thread, many times a second, for as long as the drag lasted.
enum SeamDrag {
    private(set) static var isActive = false
    static let didEnd = Notification.Name("iTERMiNAL.SeamDragDidEnd")

    static func begin() {
        isActive = true
    }

    static func end() {
        guard isActive else { return }
        isActive = false
        NotificationCenter.default.post(name: didEnd, object: nil)
    }
}

/// Hosts the terminal with breathing room around it.
///
/// SwiftTerm has no padding API, and insetting in SwiftUI would show the pane
/// background in the gap whenever a terminal theme's background differs from
/// the app's. Painting the container in the terminal's own background colour
/// keeps the inset invisible whatever theme is picked.
///
/// It is also what keeps a seam drag smooth — see `SeamDrag`. During one the
/// terminal holds its size: growing, the container's own background fills
/// the new space, in the terminal's colour, so it reads as the same surface;
/// shrinking, the container clips. Either way the program sees one resize, at
/// the end, instead of one per frame.
///
/// This is also where SwiftTerm's scrollbar gets hidden: it builds a `.legacy`
/// NSScroller and keeps it permanently visible, which draws a hard line down
/// the right edge. The property is private, so it is found by type. Wheel,
/// trackpad and keyboard scrolling are unaffected — only dragging the bar.
final class TerminalContainerView: NSView {
    let terminal: NSView

    private static let inset = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 4)

    private var dragEndObserver: NSObjectProtocol?

    /// The frost under a see-through terminal. Nil while the background is
    /// solid, so a terminal at 100% costs nothing extra.
    private var backdrop: NSVisualEffectView?

    init(terminal: NSView) {
        self.terminal = terminal
        super.init(frame: .zero)
        wantsLayer = true
        // A terminal held at its old size while a seam narrows this view has
        // to be cut off at the edge, not drawn over the panel beside it.
        layer?.masksToBounds = true
        addSubview(terminal)
        hideScroller()
        syncBackground()
        dragEndObserver = NotificationCenter.default.addObserver(
            forName: SeamDrag.didEnd, object: nil, queue: .main
        ) { [weak self] _ in
            // The layout pass that follows sees no drag in flight, so it
            // applies the size the seam settled on.
            self?.needsLayout = true
        }
    }

    deinit {
        if let dragEndObserver {
            NotificationCenter.default.removeObserver(dragEndObserver)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The frameless window is movable by its background, which would otherwise
    /// make a drag across the terminal move the window instead of selecting
    /// text. SwiftTerm's view consumes its own mouse events, but the inset this
    /// container draws around it does not — so the answer has to come from
    /// here, covering both.
    override var mouseDownCanMoveWindow: Bool { false }

    /// A right-click in the padding around the terminal gets the terminal's
    /// menu, not nothing: from the person's side the padding is part of it.
    override func menu(for event: NSEvent) -> NSMenu? {
        terminal.menu(for: event)
    }

    override func layout() {
        super.layout()
        // A terminal that has never been sized is sized now, drag or not: it
        // has no old size to hold, and a zero frame shows nothing at all.
        if SeamDrag.isActive, !terminal.frame.isEmpty {
            scheduleCatchUp()
            return
        }
        applyTerminalFrame()
    }

    private func applyTerminalFrame() {
        let inset = Self.inset
        let frame = NSRect(
            x: inset.left,
            y: inset.bottom,
            width: max(0, bounds.width - inset.left - inset.right),
            height: max(0, bounds.height - inset.top - inset.bottom)
        )
        // Setting an unchanged frame is not free: SwiftTerm redraws on it.
        if terminal.frame != frame {
            terminal.frame = frame
        }
    }

    /// A drag that pauses gets the terminal caught up without waiting for the
    /// mouse to be released, so holding a seam still shows the real layout.
    /// Each layout pass during the drag pushes this back; it only fires once
    /// the seam has been still for a moment.
    private func scheduleCatchUp() {
        NSObject.cancelPreviousPerformRequests(
            withTarget: self, selector: #selector(catchUp), object: nil
        )
        perform(#selector(catchUp), with: nil, afterDelay: 0.15)
    }

    @objc private func catchUp() {
        applyTerminalFrame()
    }

    /// Matches the padding to whatever the terminal is currently painting, and
    /// puts a frosted copy of the desktop under it while it is see-through.
    func syncBackground() {
        hideScroller()
        guard let terminalView = terminal as? TerminalView else { return }
        layer?.backgroundColor = terminalView.nativeBackgroundColor.cgColor
        syncBackdrop(
            translucent: BackgroundOpacity.isTranslucent(Double(terminalView.backgroundOpacity)),
            background: terminalView.nativeBackgroundColor
        )
    }

    /// What a see-through terminal shows through to.
    ///
    /// SwiftTerm paints the terminal's background at the opacity it is given,
    /// but the app's own surfaces sit beneath this view — the content card, the
    /// panel behind it — and every one of them is opaque, so on its own a lower
    /// opacity only mixed the terminal's colour with the app's. A
    /// behind-window effect view does not blend with what is under it in the
    /// window: it shows the desktop behind the window, blurred, in its own
    /// rectangle — which is this one, so only the terminals become see-through
    /// and the bars, panels and sheets stay solid.
    private func syncBackdrop(translucent: Bool, background: NSColor) {
        guard translucent else {
            backdrop?.removeFromSuperview()
            backdrop = nil
            return
        }
        let view: NSVisualEffectView
        if let existing = backdrop {
            view = existing
        } else {
            view = BackdropView(frame: bounds)
            view.autoresizingMask = [.width, .height]
            view.blendingMode = .behindWindow
            // Always drawn: the default dims it with the window, and a terminal
            // that changes look when you click another window is not the point.
            view.state = .active
            view.material = .underWindowBackground
            addSubview(view, positioned: .below, relativeTo: terminal)
            backdrop = view
        }
        let dark = BackgroundOpacity.prefersDarkBackdrop(background: Self.rgb(of: background))
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if view.appearance != appearance {
            view.appearance = appearance
        }
    }

    /// `color` as 0xRRGGBB in sRGB. A colour that has no sRGB form reads as
    /// black, which is what an unreadable terminal background is best taken as.
    private static func rgb(of color: NSColor) -> UInt32 {
        guard let srgb = color.usingColorSpace(.sRGB) else { return 0 }
        func byte(_ component: CGFloat) -> UInt32 {
            UInt32((min(max(component, 0), 1) * 255).rounded())
        }
        return (byte(srgb.redComponent) << 16) | (byte(srgb.greenComponent) << 8) | byte(srgb.blueComponent)
    }

    private func hideScroller() {
        for scroller in terminal.subviews.compactMap({ $0 as? NSScroller }) {
            scroller.isHidden = true
        }
    }
}

/// The effect view under a see-through terminal. Takes no clicks: the padding
/// ring it sits behind has to answer them — its right-click menu, and a mouse
/// down that must not drag the window — and an `NSVisualEffectView` would
/// otherwise answer first, with its own idea of both.
private final class BackdropView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
