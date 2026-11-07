import SwiftUI
import AppKit

/// One panel being dragged by its header: where the pointer is, where the panel
/// would land if it were let go, and the key that cancels it.
///
/// Kept apart from the region view on purpose. The region holds this in `@State`
/// — which keeps it alive without watching it — and only the overlay observes
/// it, so every move of the pointer redraws a highlight and a small ghost, and
/// not the browser, the files list and the terminals beside them.
///
/// The drag is a `DragGesture` on the header rather than SwiftUI's
/// `draggable` / `dropDestination`. The web view and the terminal register
/// their own drag types and can swallow a drop meant for SwiftUI; a gesture that
/// began on the header keeps receiving the pointer wherever it goes, whatever
/// is underneath.
final class DockDragModel: ObservableObject {
    /// The panel being dragged, or nil when no drag is under way.
    @Published private(set) var dragging: SidePanel?
    /// Where the pointer is, in the region's own coordinates.
    @Published private(set) var pointer = CGPoint.zero
    /// Where the panel would land if it were released here.
    @Published private(set) var target: DockDropTarget?
    /// The picture of that: the part of the region to light up.
    @Published private(set) var highlight: DockRect?
    /// The dragged panel's own rectangle, which is dimmed while it is away.
    @Published private(set) var source: DockRect?

    private var frames = DockFrames(leaves: [], dividers: [])
    private var region = DockRect(x: 0, y: 0, width: 0, height: 0)
    /// Escape was pressed during this drag. The mouse is still down, and the
    /// gesture goes on reporting until it is let go; none of that is acted on.
    private var cancelled = false
    private var keyMonitor: Any?

    deinit {
        removeKeyMonitor()
    }

    /// The pointer moved with `panel`'s header held, at `point` in the region's
    /// own coordinates. The first call starts the drag.
    func update(panel: SidePanel, at point: CGPoint, frames: DockFrames, region: DockRect) {
        guard !cancelled else { return }
        if dragging == nil {
            dragging = panel
            installKeyMonitor()
        }
        self.frames = frames
        self.region = region
        pointer = point
        let landing = DockLayout.dropTarget(
            at: DockPoint(x: Double(point.x), y: Double(point.y)),
            dragging: panel.rawValue,
            in: frames,
            region: region
        )
        target = landing
        highlight = landing.flatMap { DockLayout.dropHighlight(for: $0, in: frames, region: region) }
        source = frames.rect(of: panel.rawValue)
    }

    /// The pointer was let go at `point`. Ends the drag, and says where the panel
    /// landed — nil when it was cancelled, or was let go over nothing.
    func finish(at point: CGPoint) -> (panel: SidePanel, target: DockDropTarget)? {
        defer { reset() }
        guard !cancelled, let panel = dragging else { return nil }
        guard let landing = DockLayout.dropTarget(
            at: DockPoint(x: Double(point.x), y: Double(point.y)),
            dragging: panel.rawValue,
            in: frames,
            region: region
        ) else { return nil }
        return (panel, landing)
    }

    /// Back to no drag at all, whatever state it was in. Also what the region
    /// does when it goes away mid-drag, when no release will ever be reported
    /// and the key monitor would otherwise be left swallowing Escape.
    func reset() {
        removeKeyMonitor()
        cancelled = false
        clearPicture()
    }

    /// Escape: drops the picture and the monitor now, and ignores the rest of
    /// this drag. The next one starts afresh, once `finish` has seen the mouse
    /// released.
    private func cancel() {
        removeKeyMonitor()
        cancelled = true
        clearPicture()
    }

    /// Only what is set is cleared. A `@Published` property announces every
    /// assignment, equal or not, and `reset` is called as a view goes away,
    /// when a change nobody needs to hear about is a warning about publishing
    /// during a view update.
    private func clearPicture() {
        if dragging != nil { dragging = nil }
        if target != nil { target = nil }
        if highlight != nil { highlight = nil }
        if source != nil { source = nil }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 53 is Escape. It is swallowed only while a drag is under way, so
            // it reaches the terminal and everything else the rest of the time.
            guard event.keyCode == 53, let self else { return event }
            self.cancel()
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }
}
