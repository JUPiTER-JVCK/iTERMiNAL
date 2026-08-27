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
    func start(_ configuration: TerminalLaunchConfiguration)
    func send(text: String)
    func apply(_ appearance: TerminalAppearance)
    func terminate()
}
