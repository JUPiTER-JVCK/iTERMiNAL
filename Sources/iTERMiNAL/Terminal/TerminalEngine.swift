import AppKit

/// What a terminal session needs to launch its child process.
struct TerminalLaunchConfiguration {
    var executable: String
    var args: [String]
    var execName: String?
    var environment: [String]
    var initialDirectory: String?
}

/// Visual properties the UI pushes into the terminal view whenever the theme
/// or settings change.
struct TerminalAppearance: Equatable {
    var font: NSFont
    var background: NSColor
    var foreground: NSColor
    var backgroundAlpha: CGFloat
}

protocol TerminalEngineDelegate: AnyObject {
    func engineTitleChanged(_ title: String)
    func engineDirectoryChanged(_ directory: String?)
    func engineProcessTerminated(exitCode: Int32?)
}

/// Abstraction over the terminal emulation backend. The app talks only to
/// this protocol so the SwiftTerm implementation can later be swapped for
/// another engine (e.g. libghostty) without touching the UI layer.
protocol TerminalEngine: AnyObject {
    var view: NSView { get }
    var delegate: TerminalEngineDelegate? { get set }
    var onFocusGained: (() -> Void)? { get set }
    /// Debounced "the terminal repainted" signal, used for API activity events.
    var onActivity: (() -> Void)? { get set }
    /// A link the user clicked inside the terminal.
    var onLinkActivated: ((String) -> Void)? { get set }

    func start(_ configuration: TerminalLaunchConfiguration)
    func send(text: String)
    func apply(_ appearance: TerminalAppearance)
    func applyPalette(_ colors: [PaletteColor])

    /// Requests GPU-accelerated rendering; returns whether it is actually
    /// active afterwards, so callers can report a fallback to the CPU path.
    @discardableResult
    func setGPUAcceleration(_ enabled: Bool) -> Bool

    /// Plain text of the visible screen, used by the local API's capture
    /// command so scripts can read what a pane is showing.
    func captureVisibleText() -> String

    func terminate()
}
