import SwiftUI
import AppKit
import SwiftTerm

/// Bridges a session's AppKit terminal view into SwiftUI, keeping appearance
/// in sync with settings and routing keyboard focus to the focused pane.
struct TerminalHostView: NSViewRepresentable {
    let session: TerminalSession
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSView {
        session.startIfNeeded()
        session.applyStyling(settings: settings, darkMode: colorScheme == .dark)
        let view = session.engine.view
        let sessionID = session.id
        DispatchQueue.main.async {
            if WorkspaceStore.shared.focusedSessionID == sessionID {
                view.window?.makeFirstResponder(view)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        session.applyStyling(settings: settings, darkMode: colorScheme == .dark)
        let sessionID = session.id
        DispatchQueue.main.async {
            guard WorkspaceStore.shared.focusedSessionID == sessionID,
                  let window = nsView.window,
                  window.firstResponder !== nsView else { return }
            // Claim focus only from the window itself or another terminal —
            // never from a text field the user is typing in (composer, URL bar).
            let responder = window.firstResponder
            guard responder === window || responder is LocalProcessTerminalView else { return }
            window.makeFirstResponder(nsView)
        }
    }
}
