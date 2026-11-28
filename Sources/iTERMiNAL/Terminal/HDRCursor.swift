import AppKit

/// Lays an `HDRCursorView` over SwiftTerm's block cursor, on a display that has
/// room above white to flash it in.
///
/// SwiftTerm draws the cursor as a layer-backed view of its own (`CaretView`;
/// see `CursorAnimator`). Its type is internal to the package, so it is found
/// by name among the terminal's subviews and the overlay follows its frame.
/// The overlay only ever covers the cursor — it is clear in its off phase, so
/// the cursor SwiftTerm draws shows through then — and a click passes through
/// it.
///
/// It is there only when all of these hold, and taken away the moment one stops:
///   - it is switched on, the cursor is a block, and the CPU renderer is in use
///     (with the GPU renderer there is no caret layer, as in `CursorAnimator`);
///   - the terminal is the one being typed in (an unfocused one draws a hollow
///     cursor that should not flash);
///   - Reduce Motion is off;
///   - the display can show more than SDR white. Without that the overlay would
///     only be a second, plain blink on top of the cursor, so the cursor is
///     left as it was.
///
/// The cursor's cell is covered while the flash is lit, so a character under it
/// is hidden for that half of the blink.
final class HDRCursor {
    private weak var host: NSView?
    private var overlay: HDRCursorView?
    private var timer: Timer?
    private var enabled = false
    private weak var observedCaret: NSView?
    private var frameObserver: NSObjectProtocol?

    /// The cursor's color, which the flash follows.
    var color: NSColor = .white {
        didSet { overlay?.color = Self.linear(color) }
    }

    init(host: NSView) {
        self.host = host
    }

    deinit {
        timer?.invalidate()
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        overlay?.removeFromSuperview()
    }

    /// Switches it on or off. Safe to call with what is already set.
    func set(enabled: Bool) {
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        if enabled {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.refresh()
            }
            // Common modes, so it keeps going while a menu is open or a seam is
            // being dragged.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
        }
        refresh()
    }

    /// Makes the overlay match what should be there now.
    func refresh() {
        guard enabled, let host, let caret = caretView(), isWanted(in: host, caret: caret) else {
            remove()
            return
        }
        follow(caret)
        let view: HDRCursorView
        if let overlay {
            view = overlay
        } else {
            view = HDRCursorView(frame: caret.frame)
            view.color = Self.linear(color)
            overlay = view
        }
        if view.superview !== host {
            host.addSubview(view, positioned: .above, relativeTo: nil)
        }
        if view.frame != caret.frame { view.frame = caret.frame }
    }

    private func remove() {
        overlay?.removeFromSuperview()
        overlay = nil
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        frameObserver = nil
        observedCaret = nil
    }

    /// Moves the overlay the moment the cursor moves, not at the next half
    /// second: the caret view posts a notification when its frame changes.
    private func follow(_ caret: NSView) {
        guard observedCaret !== caret else { return }
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        caret.postsFrameChangedNotifications = true
        observedCaret = caret
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: caret, queue: .main
        ) { [weak self] _ in
            self?.refresh()
        }
    }

    private func isWanted(in host: NSView, caret: NSView) -> Bool {
        guard let window = host.window, window.isKeyWindow, window.firstResponder === host,
              !caret.isHidden, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let screen = window.screen else { return false }
        return screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1
    }

    private func caretView() -> NSView? {
        host?.subviews.first { NSStringFromClass(type(of: $0)).hasSuffix(".CaretView") }
    }

    /// An sRGB color as the linear components `HDRCursorView` takes.
    static func linear(_ color: NSColor) -> (r: Double, g: Double, b: Double) {
        let c = color.usingColorSpace(.sRGB) ?? .white
        func lin(_ v: CGFloat) -> Double {
            let v = Double(v)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return (lin(c.redComponent), lin(c.greenComponent), lin(c.blueComponent))
    }
}
