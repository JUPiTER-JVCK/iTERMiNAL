import SwiftUI
import AppKit

// A sheet that goes away when you click the window behind it.
//
// A popover does this by itself. A sheet does not: macOS keeps the window it
// hangs from from taking clicks, and only beeps. For a sheet that is only
// there to be looked at — the command palette, the shortcut list, a page's
// source — that is the wrong way round, so these ask to be dismissed instead.
//
// Not put on a sheet with a form in it. A click that closes it would throw away
// what was typed.

extension View {
    /// Closes the sheet this is inside when the window it hangs from is clicked.
    func dismissOnOutsideClick() -> some View {
        modifier(DismissOnOutsideClick())
    }
}

private struct DismissOnOutsideClick: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.background(OutsideClickWatcher { dismiss() })
    }
}

/// Listens, while the sheet it is in is up, for a mouse-down in the window the
/// sheet hangs from.
private struct OutsideClickWatcher: NSViewRepresentable {
    let onOutsideClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = Watcher()
        view.onOutsideClick = onOutsideClick
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? Watcher)?.onOutsideClick = onOutsideClick
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? Watcher)?.stop()
    }

    private final class Watcher: NSView {
        var onOutsideClick: () -> Void = {}
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            // The sheet's own window, once this is in it. Nil on the way out.
            guard let sheet = window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self, weak sheet] event in
                guard let self, let sheet,
                      let parent = sheet.sheetParent,
                      event.window === parent else { return event }
                // After this event, not in the middle of it: the dismissal
                // changes the very state the window is being drawn from.
                DispatchQueue.main.async { self.onOutsideClick() }
                // Taken, so the window behind does not also beep or act on it.
                return nil
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit { stop() }
    }
}
