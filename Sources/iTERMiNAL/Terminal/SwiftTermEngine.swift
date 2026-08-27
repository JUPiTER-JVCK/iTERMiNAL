import AppKit
import SwiftTerm

/// SwiftTerm subclass that reports keyboard focus so the app can track which
/// pane splits, composer input, and file-panel "follow" actions apply to.
final class FocusReportingTerminalView: LocalProcessTerminalView {
    var onFocusGained: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocusGained?()
        }
        return accepted
    }
}

/// TerminalEngine backed by SwiftTerm's LocalProcessTerminalView (a PTY-run
/// child process with full VT100/xterm emulation).
final class SwiftTermEngine: TerminalEngine {
    weak var delegate: TerminalEngineDelegate?

    private let terminalView: FocusReportingTerminalView
    private var started = false
    private var lastAppearance: TerminalAppearance?

    var view: NSView { terminalView }

    var onFocusGained: (() -> Void)? {
        get { terminalView.onFocusGained }
        set { terminalView.onFocusGained = newValue }
    }

    init(options: TerminalOptions) {
        terminalView = FocusReportingTerminalView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400),
            font: nil,
            options: options
        )
        terminalView.processDelegate = self
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
