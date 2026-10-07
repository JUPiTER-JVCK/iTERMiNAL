import SwiftUI
import AppKit

/// Frameless window chrome: the app's own surfaces run to the top edge and the
/// system title bar is reduced to the three traffic-light buttons floating over
/// them.
///
/// `.windowStyle(.hiddenTitleBar)` gets part of the way — it hides the title and
/// makes the bar transparent — but the window still keeps a title-bar-height
/// safe area that SwiftUI insets content below, so the result is a blank strip
/// above the sidebar and the top strip. These constants and the configurator
/// below remove that strip and put the responsibility for clearing the traffic
/// lights on the views that sit under them.
enum WindowChrome {
    /// Height of the region the traffic lights occupy, measured from the top of
    /// the content view. Anything a view puts in this band is drawn under
    /// floating buttons, so views inset past it instead.
    static let titleBarHeight: CGFloat = 28

    /// Width to keep clear on the leading edge for the three buttons, with
    /// breathing room after the last one.
    static let trafficLightWidth: CGFloat = 78

    /// Height of the window's one top bar. The traffic lights float over its
    /// leading end and everything else in it clears them sideways — padding
    /// down past them would leave an empty strip above the bar's own content.
    static let topBarHeight: CGFloat = 44

    /// Width of the icon rail down the left edge, under the top bar.
    static let railWidth: CGFloat = 56

    /// Width of the workspaces panel, docked beside the content or floating
    /// over it.
    static let panelWidth: CGFloat = 284

    /// The least the rail keeps clear below its last icon. The content card
    /// can be set flush to the window edge (Appearance → Workspace frame), but
    /// the dock button above it should not sit on the edge with it.
    static let railBottomInset: CGFloat = 6

    /// Applies the frameless configuration to a window.
    ///
    /// Safe to call repeatedly: every step is idempotent, which matters because
    /// `updateNSView` runs on every layout pass and a window is not attached
    /// yet when the view is first made.
    static func apply(to window: NSWindow?) {
        guard let window else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // The hairline under the title bar is the last visible trace of it.
        window.titlebarSeparatorStyle = .none
        // Deliberately off. With no title bar to grab, the app's own chrome has
        // to be draggable — but that is `WindowDragArea`'s job, on the top bar,
        // the rail and the settings headers, not the whole window's. Turned on,
        // every SwiftUI `DragGesture` in the app moved the window along with
        // itself: SwiftUI's hosting view reports "background" for them, so
        // dragging the composer card, or a panel's resize seam, dragged the
        // entire application instead.
        window.isMovableByWindowBackground = false
    }
}

/// A transparent region that drags the window, standing in for the title bar
/// that is no longer there.
///
/// The only thing that moves the window by dragging: the window is not
/// movable by its background (see `WindowChrome.apply`), because that also
/// moved it under every SwiftUI drag handle. Driving the drag loop from
/// `mouseDown` here puts the movable part exactly where this view is, and
/// nowhere else.
///
/// Used as a `.background`, behind content that has hit-testing switched off.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else {
                super.mouseDown(with: event)
                return
            }
            guard event.clickCount < 2 else {
                performDoubleClickAction(on: window)
                return
            }
            window.performDrag(with: event)
        }

        /// System Settings → Desktop & Dock lets the user say what a
        /// double-click on a title bar does. A custom title bar that always
        /// zoomed would ignore that choice.
        private func performDoubleClickAction(on window: NSWindow) {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "None": break
            case "Minimize": window.performMiniaturize(nil)
            default: window.performZoom(nil)
            }
        }
    }
}

/// Configures the window hosting this view, and paints nothing.
///
/// Used as a `.background`, so it never affects layout.
private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // `window` is nil until the view is in the hierarchy; the next runloop
        // turn is the first moment there is anything to configure.
        DispatchQueue.main.async { WindowChrome.apply(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { WindowChrome.apply(to: nsView.window) }
    }
}

extension FrameFontDesign {
    /// The SwiftUI design this choice stands for. Nil for System, which leaves
    /// the text as it was drawn rather than forcing a design on it.
    var design: Font.Design? {
        switch self {
        case .system: return nil
        case .rounded: return .rounded
        case .serif: return .serif
        case .monospaced: return .monospaced
        }
    }
}

extension View {
    /// Makes the hosting window frameless and lets this view draw into the
    /// title bar band.
    ///
    /// Views that would land under the traffic lights are responsible for
    /// insetting themselves — see `WindowChrome.titleBarHeight` and
    /// `trafficLightWidth`.
    func framelessWindow() -> some View {
        background(WindowChromeConfigurator())
            .ignoresSafeArea(.container, edges: .top)
    }
}
