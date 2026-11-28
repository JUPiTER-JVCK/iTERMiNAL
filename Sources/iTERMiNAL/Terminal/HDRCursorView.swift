import AppKit
import Metal
import QuartzCore

/// A block cursor that flashes above SDR white ("flash HDR") on displays with EDR headroom.
///
/// - Works only inside iTERMiNAL's own windows: EDR is opted into per CAMetalLayer the app creates.
///   The Dock is drawn by macOS, so it can't show HDR.
/// - On displays without headroom (e.g. most external SDR monitors, MacBook Air), it falls back
///   automatically to normal brightness, because the boost is clamped to the screen's headroom.
/// - No shaders: each frame just clears the drawable to the cursor color.
final class HDRCursorView: NSView {

    /// Brightness of the lit cursor as a multiple of SDR white. Clamped to the display's headroom.
    /// 2–3 reads as a glow; much higher is glaring next to text.
    var peak: Double = 2.5

    /// Phosphor green #2BFF5E expressed in *linear* sRGB (the layer uses an extended linear space).
    var color: (r: Double, g: Double, b: Double) = (0.024, 1.0, 0.112)

    /// Seconds per on/off phase.
    var interval: TimeInterval = 0.55

    private let device = MTLCreateSystemDefaultDevice()
    private lazy var queue = device?.makeCommandQueue()
    private var timer: Timer?
    private var lit = true

    private var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func makeBackingLayer() -> CALayer {
        let l = CAMetalLayer()
        l.device = device
        l.pixelFormat = .rgba16Float                       // half-float: allows values > 1.0
        l.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        l.wantsExtendedDynamicRangeContent = true          // the EDR opt-in
        l.isOpaque = false
        l.framebufferOnly = true
        l.cornerRadius = 2
        l.masksToBounds = true
        return l
    }

    /// The cursor sits over the cell the terminal is drawing in: a click on it
    /// is a click in the terminal, to place a selection or focus it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() } else { start() }
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        metalLayer?.contentsScale = scale
        metalLayer?.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        render()
    }

    /// Start blinking. Respects System Settings › Accessibility › Display › Reduce motion.
    func start() {
        timer?.invalidate()
        lit = true
        render()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.lit.toggle()
                self.render()
            }
        }
    }

    /// Stop blinking and leave the cursor lit.
    func stop() {
        timer?.invalidate()
        timer = nil
        lit = true
        render()
    }

    // MARK: Drawing

    private func render() {
        guard let metalLayer, let queue, let drawable = metalLayer.nextDrawable() else { return }

        // Current headroom. It's 1.0 until EDR content is on screen, then macOS raises it.
        // Re-reading every tick picks that up, plus brightness changes.
        let headroom = Double(window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
        let k = lit ? min(peak, max(headroom, 1)) : 0

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: color.r * k, green: color.g * k, blue: color.b * k, alpha: lit ? 1 : 0)

        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}
