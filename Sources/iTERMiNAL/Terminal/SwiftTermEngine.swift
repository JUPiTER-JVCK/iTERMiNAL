import AppKit
import SwiftTerm

/// TerminalEngine backed by SwiftTerm's LocalProcessTerminalView (a PTY-run
/// child process with full VT100/xterm emulation).
///
/// Focus tracking comes from two places: a local mouse-down monitor for
/// clicks, and the `send` override on `InstrumentedTerminalView` for typing.
final class SwiftTermEngine: TerminalEngine {
    weak var delegate: TerminalEngineDelegate?
    var onFocusGained: (() -> Void)?
    /// Called (debounced) when the terminal repaints — used for API activity
    /// events.
    var onActivity: (() -> Void)?
    /// Called for BEL / OSC 9 / OSC 777 attention requests.
    var onAttention: ((TerminalAttention) -> Void)?
    /// Called when the user clicks a link in the terminal.
    var onLinkActivated: ((String) -> Void)?
    /// Called with each command line the shell is given.
    var onCommand: ((String) -> Void)?

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

    /// PID of the shell running in the PTY, or 0 when nothing is running.
    /// Used to read the shell's working directory straight from the kernel,
    /// which is the only way to track `cd` in a shell that doesn't emit OSC 7.
    var shellPID: pid_t { terminalView.process?.shellPid ?? 0 }

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
        terminalView.onCommand = { [weak self] command in
            self?.onCommand?(command)
        }
        terminalView.onAttention = { [weak self] attention in
            self?.onAttention?(attention)
        }
        terminalView.installAttentionOSCHandlers()

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

    /// Everything the terminal still holds — the retained scrollback plus the
    /// current screen — so a closed session can be reopened showing what was
    /// on it.
    ///
    /// Buffer rows are absolute over the whole circular buffer, with row 0 the
    /// oldest line still retained, so reading from 0 to the bottom of the
    /// viewport covers the scrollback too. `buffer.lines.count` is internal to
    /// SwiftTerm, but `yDisp` plus the row count reaches the same last line
    /// through public API.
    func captureScrollback(maxBytes: Int) -> String {
        let terminal = terminalView.getTerminal()
        let cols = terminal.cols
        let rows = terminal.rows
        guard cols > 0, rows > 0 else { return "" }
        // Deliberately past the end: SwiftTerm clamps the end row to the last
        // line it holds, so this reaches the true bottom of the buffer. Using
        // the display offset instead would truncate everything below the
        // viewport whenever the session was closed while scrolled up — losing
        // exactly the newest output.
        let text = terminal.getText(
            start: Position(col: 0, row: 0),
            end: Position(col: cols - 1, row: Int.max)
        )
        return Self.trimmedToBytes(text, maxBytes: maxBytes)
    }

    /// Keeps the last `maxBytes` of UTF-8, cut on a character boundary.
    ///
    /// Truncating by `Character` count could not honour a byte cap: one
    /// grapheme can be many scalars, so a "quarter of the cap" in characters
    /// still encodes to well over it.
    static func trimmedToBytes(_ text: String, maxBytes: Int) -> String {
        var bytes = Array(text.utf8)
        guard bytes.count > maxBytes else { return text }
        // The tail is what matters: the end of a session is what you want back.
        bytes = Array(bytes.suffix(maxBytes))
        // A byte-aligned cut can land mid-sequence; skip continuation bytes so
        // what remains is decodable.
        var start = 0
        while start < bytes.count, bytes[start] & 0xC0 == 0x80 { start += 1 }
        return String(decoding: bytes[start...], as: UTF8.self)
    }

    /// Writes text to the display without sending it to the shell.
    func display(text: String) {
        terminalView.feed(text: text)
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
