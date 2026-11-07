import SwiftUI
import AppKit

// A click anywhere in a panel makes it the panel in front.
//
// "In front" is what a panel opened next goes beside, and what the region's
// headers dim the others against. Only a header's tap, opening a panel, and a
// tool's terminal taking focus used to set it, so a click in the browser, Files,
// Notes or the HTTP client changed nothing, and the next panel opened beside
// whichever one had been touched last by one of those.
//
// SwiftUI gestures cannot do this. The browser is a web view and a tool is a
// terminal, both AppKit views that take the mouse themselves, and a gesture on a
// SwiftUI parent never hears of a click inside them. So each panel carries an
// invisible AppKit view behind it, filling its rectangle, and one monitor on the
// app's mouse-downs asks which of those rectangles the click fell in. The monitor
// only listens: the event goes on to whatever was clicked, untouched.

/// An invisible view that fills one panel's rectangle, so a click can be matched
/// to the panel it landed in.
///
/// It lives behind the panel and answers no hit tests, so it never takes a click
/// from anything. It records itself in `DockLeafMarkers` for the monitor to find.
final class DockLeafMarkerView: NSView {
    var panel: SidePanel

    init(panel: SidePanel) {
        self.panel = panel
        super.init(frame: .zero)
        DockLeafMarkers.all.add(self)
    }

    required init?(coder: NSCoder) {
        fatalError("DockLeafMarkerView is made in code")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Every marker that is alive, held weakly: a panel leaving the region lets go of
/// its marker, which drops out of this on its own.
enum DockLeafMarkers {
    static let all = NSHashTable<DockLeafMarkerView>.weakObjects()

    /// The panel whose rectangle `event` landed in, or nil when it landed in none:
    /// outside the region, in another window such as a menu's popover, or on a
    /// panel that is out of sight.
    ///
    /// Both the marker's rectangle and the event's position are in the window's
    /// own coordinates, so nothing here depends on how SwiftUI lays its views out.
    static func panel(under event: NSEvent) -> SidePanel? {
        guard let window = event.window else { return nil }
        for marker in all.allObjects where marker.window === window && !marker.isHiddenOrHasHiddenAncestor {
            let area = marker.convert(marker.bounds, to: nil)
            if area.contains(event.locationInWindow) { return marker.panel }
        }
        return nil
    }
}

/// Puts a `DockLeafMarkerView` behind a panel.
struct DockLeafMarker: NSViewRepresentable {
    let panel: SidePanel

    func makeNSView(context: Context) -> DockLeafMarkerView {
        DockLeafMarkerView(panel: panel)
    }

    func updateNSView(_ view: DockLeafMarkerView, context: Context) {
        view.panel = panel
    }
}

/// Listens for mouse-downs while the region is on screen, and says which panel
/// each fell in.
///
/// The monitor is not installed while the region is away, so it costs nothing
/// then, and it is removed with the region rather than left to listen for a view
/// that has gone.
final class DockClickFocus {
    private var monitor: Any?

    /// Starts listening. `clicked` is told the panel of each mouse-down that falls
    /// in one, on the main thread, before the click reaches what was clicked.
    func start(_ clicked: @escaping (SidePanel) -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { event in
            if let panel = DockLeafMarkers.panel(under: event) {
                clicked(panel)
            }
            // Never consumed: the click still goes where it was aimed.
            return event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    deinit {
        stop()
    }
}
