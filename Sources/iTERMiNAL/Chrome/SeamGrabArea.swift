import SwiftUI
import AppKit

/// The strip a seam is grabbed by, as a real AppKit view.
///
/// Terminals and the browser are AppKit views, and an AppKit view takes a click
/// before any SwiftUI gesture behind or above it hears of it. A transparent
/// SwiftUI rectangle widened past the seam therefore only worked where it lay
/// over bare surface — the few points of the gap itself, or a single pixel for
/// a hairline — and the part reaching over a pane did nothing. This view is
/// an AppKit view too, laid over the panes either side, so the whole strip takes
/// the mouse, and the cursor rect, tooltip and double-click come with it.
struct SeamGrabArea: NSViewRepresentable {
    /// True for a seam between side-by-side panes, dragged left and right.
    let horizontal: Bool
    var help: String = ""
    let onHover: (Bool) -> Void
    /// Distance travelled along the seam's axis since the mouse went down,
    /// positive towards the right or the bottom. Every event of a drag.
    let onChange: (CGFloat) -> Void
    /// The same, once, when the button comes up after a drag.
    let onEnd: (CGFloat) -> Void
    let onReset: () -> Void

    func makeNSView(context: Context) -> SeamGrabNSView {
        let view = SeamGrabNSView()
        configure(view)
        return view
    }

    func updateNSView(_ view: SeamGrabNSView, context: Context) {
        configure(view)
    }

    private func configure(_ view: SeamGrabNSView) {
        view.horizontal = horizontal
        view.toolTip = help.isEmpty ? nil : help
        view.onHover = onHover
        view.onChange = onChange
        view.onEnd = onEnd
        view.onReset = onReset
    }
}

final class SeamGrabNSView: NSView {
    var horizontal = true {
        didSet {
            guard horizontal != oldValue else { return }
            window?.invalidateCursorRects(for: self)
        }
    }
    var onHover: (Bool) -> Void = { _ in }
    var onChange: (CGFloat) -> Void = { _ in }
    var onEnd: (CGFloat) -> Void = { _ in }
    var onReset: () -> Void = {}

    /// Where the button went down, in window coordinates; nil between drags.
    private var origin: NSPoint?
    /// Set once the pointer has moved a point or more, so a plain click, or the
    /// first click of a double-click, starts nothing.
    private var dragging = false

    private var area: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The window is frameless and movable by its background, which would turn
    /// a drag on this strip into a drag of the window.
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var cursor: NSCursor { horizontal ? .resizeLeftRight : .resizeUpDown }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        area = next
    }

    override func mouseEntered(with event: NSEvent) {
        cursor.set()
        onHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        // Not while dragging: the pointer leaves the strip as the seam moves
        // under it, and the cursor should stay a resize cursor until release.
        guard origin == nil else { return }
        NSCursor.arrow.set()
        onHover(false)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            origin = nil
            dragging = false
            onReset()
            return
        }
        origin = event.locationInWindow
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin else { return }
        let travel = translation(from: origin, to: event)
        if !dragging {
            guard abs(travel) >= 1 else { return }
            dragging = true
        }
        cursor.set()
        onChange(travel)
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            origin = nil
            dragging = false
        }
        guard let origin, dragging else { return }
        onEnd(translation(from: origin, to: event))
        // The pointer may have been released away from the strip.
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if !inside {
            NSCursor.arrow.set()
            onHover(false)
        }
    }

    /// Window coordinates run up the screen, SwiftUI's down it: flip the
    /// vertical so a drag towards the bottom is positive in both.
    private func translation(from start: NSPoint, to event: NSEvent) -> CGFloat {
        let now = event.locationInWindow
        return horizontal ? now.x - start.x : start.y - now.y
    }
}
