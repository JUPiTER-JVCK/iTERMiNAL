import AppKit
import SwiftTerm

/// TerminalEngine backed by SwiftTerm's LocalProcessTerminalView (a PTY-run
/// child process with full VT100/xterm emulation).
///
/// Focus tracking: SwiftTerm's `becomeFirstResponder` is public but not open,
/// so instead of subclassing, a local mouse-down monitor reports clicks that
/// land inside this engine's view — that's what drives the app's notion of
/// the focused pane.
final class SwiftTermEngine: TerminalEngine {
    weak var delegate: TerminalEngineDelegate?
    var onFocusGained: (() -> Void)?

    private let terminalView: LocalProcessTerminalView
    private var started = false
    private var lastAppearance: TerminalAppearance?
    private var lastPalette: [PaletteColor]?
    private var lastGPURequest: Bool?
    private var clickMonitor: Any?

    /// True when SwiftTerm's Metal renderer is actually driving this view.
    private(set) var isGPUAccelerated = false

    var view: NSView { terminalView }

    init(options: TerminalOptions) {
        terminalView = LocalProcessTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400),
            font: nil,
            options: options
        )
        terminalView.processDelegate = self

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
            self?.delegate?.engineProcessTerminated(exitCode: exitCode)
        }
    }
}
