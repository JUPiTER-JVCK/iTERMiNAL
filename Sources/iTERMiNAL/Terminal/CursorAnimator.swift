import AppKit

/// Puts a `CursorAnimation` on SwiftTerm's cursor.
///
/// SwiftTerm draws the cursor as a layer-backed view of its own (`CaretView`) and
/// offers one motion for it, a plain blink. Its type is internal to the package,
/// so it is found by name among the terminal's subviews, and the animation is
/// added to its layer — an opacity animation, which is all a cursor's look
/// needs, kept apart from SwiftTerm's by its own key.
///
/// What this cannot reach: with the GPU renderer SwiftTerm draws the cursor
/// itself in a shader and there is no layer to animate, so nothing here does
/// anything then (the engine does not ask). And if a later SwiftTerm names the
/// view differently, `caretLayer` finds nothing and the cursor simply keeps its
/// plain look.
///
/// SwiftTerm removes every animation from the caret's layer whenever its
/// style or focus changes, and says nothing. A half-second check puts this
/// one back, and takes it off while the terminal is not the one being typed
/// in: an unfocused terminal draws a hollow cursor that should not pulse.
final class CursorAnimator {
    private static let animationKey = "iTERMiNAL.cursorAnimation"

    private weak var host: NSView?
    private(set) var animation: CursorAnimation = .none
    private var timer: Timer?

    init(host: NSView) {
        self.host = host
    }

    deinit {
        timer?.invalidate()
    }

    /// Starts, changes or stops the animation. Safe to call with what is
    /// already set.
    func set(_ animation: CursorAnimation) {
        let changed = animation != self.animation
        self.animation = animation
        if animation == .none {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.refresh()
            }
            // Common modes, so it keeps going while a menu is open or a seam is
            // being dragged.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        if changed { caretLayer()?.removeAnimation(forKey: Self.animationKey) }
        refresh()
    }

    /// Makes the layer match what should be happening now: animating when there
    /// is an animation, the terminal is the one being typed in, and Reduce
    /// Motion is off; plain otherwise.
    func refresh() {
        guard let layer = caretLayer() else { return }
        guard let loop = animation.loop, isTypedInto, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            layer.removeAnimation(forKey: Self.animationKey)
            return
        }
        guard layer.animation(forKey: Self.animationKey) == nil else { return }
        let keyframes = CAKeyframeAnimation(keyPath: "opacity")
        keyframes.values = loop.values.map { NSNumber(value: $0) }
        keyframes.keyTimes = loop.times.map { NSNumber(value: $0) }
        keyframes.duration = loop.duration
        keyframes.calculationMode = .linear
        keyframes.repeatCount = .infinity
        layer.add(keyframes, forKey: Self.animationKey)
    }

    #if SCREENSHOTS
    /// The capture mode's runner has no window that is ever key — the app is
    /// never active there — so a scene that wants to see an animation run says
    /// so here. Compiled out of every shipped build.
    static var assumeTypedInto = false
    #endif

    /// Whether the terminal is the one receiving the keys: in the front window,
    /// and its first responder.
    private var isTypedInto: Bool {
        #if SCREENSHOTS
        if Self.assumeTypedInto { return host?.window != nil }
        #endif
        guard let host, let window = host.window else { return false }
        return window.isKeyWindow && window.firstResponder === host
    }

    private func caretLayer() -> CALayer? {
        host?.subviews.first { NSStringFromClass(type(of: $0)).hasSuffix(".CaretView") }?.layer
    }
}
