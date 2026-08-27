import AppKit
import SwiftTerm

/// LocalProcessTerminalView subclass that reports what the app needs to know.
///
/// Only methods SwiftTerm declares `open` are overridden — `send`,
/// `rangeChanged`, and `requestOpenLink`. Other delegate methods on this class
/// (`sizeChanged`, `setTerminalTitle`, and `becomeFirstResponder` on the view)
/// are `public` but not `open`, so they cannot be overridden from outside the
/// module; those signals come through `processDelegate` and a mouse monitor
/// instead.
final class InstrumentedTerminalView: LocalProcessTerminalView {
    var onActivity: (() -> Void)?
    var onInput: (() -> Void)?
    var onLink: ((String) -> Void)?

    /// The keystroke path — `super` writes the bytes to the PTY, so it must
    /// always run first.
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        super.send(source: source, data: data)
        onInput?()
    }

    /// Fires whenever the terminal repaints a row range: the closest thing
    /// SwiftTerm offers to an "output happened" signal without a byte hook.
    override func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        super.rangeChanged(source: source, startY: startY, endY: endY)
        onActivity?()
    }

    /// Clicking a link opens it in the app's own browser pane when a handler
    /// is installed, instead of bouncing the user out to Safari.
    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let onLink {
            onLink(link)
        } else {
            super.requestOpenLink(source: source, link: link, params: params)
        }
    }
}

/// TerminalEngine backed by SwiftTerm's LocalProcessTerminalView (a PTY-run
/// child process with full VT100/xterm emulation).
///
/// Focus tracking comes from two places: a local mouse-down monitor for
/// clicks, and the `send` override above for typing.
final class SwiftTermEngine: TerminalEngine {
    weak var delegate: TerminalEngineDelegate?
    var onFocusGained: (() -> Void)?
    /// Called (debounced) when the terminal repaints — used for API activity
    /// events.
    var onActivity: (() -> Void)?
    /// Called when the user clicks a link in the terminal.
    var onLinkActivated: ((String) -> Void)?

    private let terminalView: InstrumentedTerminalView
    private var started = false
    private var lastAppearance: TerminalAppearance?
    private var lastPalette: [PaletteColor]?
    private var lastGPURequest: Bool?
    private var clickMonitor: Any?
    private var lastActivityAt = Date.distantPast

    /// True when SwiftTerm's Metal renderer is actually driving this view.
    private(set) var isGPUAccelerated = false

    var view: NSView { terminalView }

    init(options: TerminalOptions) {
        terminalView = InstrumentedTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400),
            font: nil,
            options: options
        )
        terminalView.processDelegate = self

        terminalView.onInput = { [weak self] in
            self?.onFocusGained?()
        }
        terminalView.onLink = { [weak self] link in
            self?.onLinkActivated?(link)
        }
        terminalView.onActivity = { [weak self] in
            self?.noteActivity()
        }

        clickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            self?.reportFocusIfClickLands(event)
            return event
        }
    }

    deinit {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
    }

    /// Coalesces repaint callbacks into at most one event every 250ms.
    /// SwiftTerm gives no promise about which queue this arrives on, so the
    /// bus itself does the main-queue hop and drops the event when nobody is
    /// subscribed.
    private func noteActivity() {
        guard let onActivity else { return }
        let now = Date()
        guard now.timeIntervalSince(lastActivityAt) > 0.25 else { return }
        lastActivityAt = now
        onActivity()
    }

    private func reportFocusIfClickLands(_ event: NSEvent) {
        guard let window = terminalView.window,
              event.window === window else { return }
        let point = terminalView.convert(event.locationInWindow, from: nil)
        if terminalView.bounds.contains(point) {
            onFocusGained?()
        }
    }

    func start(_ configuration: TerminalLaunchConfiguration) {
        guard !started else { return }
        started = true
        terminalView.startProcess(
            executable: configuration.executable,
            args: configuration.args,
            environment: configuration.environment,
            execName: configuration.execName,
            currentDirectory: configuration.initialDirectory
        )
    }

    func send(text: String) {
        terminalView.send(txt: text)
    }

    func apply(_ appearance: TerminalAppearance) {
        // SwiftUI re-applies on every render; only touch the view on change.
        guard appearance != lastAppearance else { return }
        lastAppearance = appearance
        terminalView.font = appearance.font
        terminalView.nativeForegroundColor = appearance.foreground
        let alpha = max(0.5, min(1.0, appearance.backgroundAlpha))
        terminalView.nativeBackgroundColor = appearance.background.withAlphaComponent(alpha)
        terminalView.caretColor = appearance.foreground
    }

    func applyPalette(_ colors: [PaletteColor]) {
        guard colors.count == 16, colors != lastPalette else { return }
        lastPalette = colors
        terminalView.installColors(colors.map {
            SwiftTerm.Color(red8: $0.red, green8: $0.green, blue8: $0.blue)
        })
        // installColors resets the native fore/background, so push the
        // current appearance back in afterwards.
        if let appearance = lastAppearance {
            lastAppearance = nil
            apply(appearance)
        }
    }

    @discardableResult
    func setGPUAcceleration(_ enabled: Bool) -> Bool {
        guard enabled != lastGPURequest else { return isGPUAccelerated }
        lastGPURequest = enabled
        do {
            try terminalView.setUseMetal(enabled)
            isGPUAccelerated = terminalView.isUsingMetalRenderer
        } catch {
            // Metal is unavailable or failed to initialize — SwiftTerm stays
            // on the CoreGraphics path, which is a correct fallback.
            NSLog("GPU rendering unavailable, using CPU renderer: \(error.localizedDescription)")
            isGPUAccelerated = false
        }
        return isGPUAccelerated
    }

    func captureVisibleText() -> String {
        let terminal = terminalView.getTerminal()
        let cols = terminal.cols
        let rows = terminal.rows
        guard cols > 0, rows > 0 else { return "" }
        return terminal.getText(
            start: Position(col: 0, row: 0),
            end: Position(col: cols - 1, row: rows - 1)
        )
    }

    func terminate() {
        terminalView.terminate()
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}

extension SwiftTermEngine: LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        // The view manages its own grid; nothing to forward.
    }

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        onMain { [weak self] in
            self?.delegate?.engineTitleChanged(title)
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        onMain { [weak self] in
            self?.delegate?.engineDirectoryChanged(directory)
        }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        onMain { [weak self] in
            // Clear the start guard so a dropped session can be reconnected
            // in place without rebuilding the view.
            self?.started = false
            self?.delegate?.engineProcessTerminated(exitCode: exitCode)
        }
    }
}
