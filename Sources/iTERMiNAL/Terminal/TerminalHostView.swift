import SwiftUI
import AppKit
import SwiftTerm

/// Bridges a session's AppKit terminal view into SwiftUI, keeping appearance
/// in sync with settings and routing keyboard focus to the focused pane.
struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> TerminalContainerView {
        session.startIfNeeded()
        session.applyStyling(settings: settings, darkMode: colorScheme == .dark)
        let terminal = session.engine.view
        let container = TerminalContainerView(terminal: terminal)
        let sessionID = session.id
        DispatchQueue.main.async {
            if WorkspaceStore.shared.focusedSessionID == sessionID {
                terminal.window?.makeFirstResponder(terminal)
            }
        }
        return container
    }

    func updateNSView(_ nsView: TerminalContainerView, context: Context) {
        session.applyStyling(settings: settings, darkMode: colorScheme == .dark)
        nsView.syncBackground()
        let terminal = nsView.terminal
        let sessionID = session.id
        DispatchQueue.main.async {
            guard WorkspaceStore.shared.focusedSessionID == sessionID,
                  let window = terminal.window,
                  window.firstResponder !== terminal else { return }
            // Claim focus only from the window itself or another terminal —
            // never from a text field the user is typing in (composer, URL bar).
            let responder = window.firstResponder
            guard responder === window || responder is LocalProcessTerminalView else { return }
            window.makeFirstResponder(terminal)
        }
    }
}

/// Hosts the terminal with breathing room around it.
///
/// SwiftTerm has no padding API, and insetting in SwiftUI would show the pane
/// background in the gap whenever a terminal theme's background differs from
/// the app's. Painting the container in the terminal's own background colour
/// keeps the inset invisible whatever theme is picked.
///
/// This is also where SwiftTerm's scrollbar gets hidden: it builds a `.legacy`
/// NSScroller and keeps it permanently visible, which draws a hard line down
/// the right edge. The property is private, so it is found by type. Wheel,
/// trackpad and keyboard scrolling are unaffected — only dragging the bar.
final class TerminalContainerView: NSView {
    let terminal: NSView

    private static let inset = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 4)

    init(terminal: NSView) {
        self.terminal = terminal
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(terminal)
        hideScroller()
        syncBackground()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        let inset = Self.inset
        terminal.frame = NSRect(
            x: inset.left,
            y: inset.bottom,
            width: max(0, bounds.width - inset.left - inset.right),
            height: max(0, bounds.height - inset.top - inset.bottom)
        )
    }

    /// Matches the padding to whatever the terminal is currently painting.
    func syncBackground() {
        hideScroller()
        guard let terminalView = terminal as? TerminalView else { return }
        layer?.backgroundColor = terminalView.nativeBackgroundColor.cgColor
    }

    private func hideScroller() {
        for scroller in terminal.subviews.compactMap({ $0 as? NSScroller }) {
            scroller.isHidden = true
        }
    }
}
