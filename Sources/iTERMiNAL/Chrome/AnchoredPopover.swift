import AppKit
import SwiftUI

/// A popover that AppKit shows from the view this is the background of, on
/// the edge asked for, in place of SwiftUI's `.popover`.
///
/// SwiftUI's `arrowEdge` is a hint: the quick reference's full list, wanted
/// above its line at the bottom of the window, opened below it and off the
/// screen whichever edge was named. `NSPopover` is given the edge in the
/// anchor's own coordinates, keeps to it while the popover fits on that side
/// of the screen, and moves to the other side only when it does not.
///
/// What is shown this way is hosted on its own, so it does not inherit
/// SwiftUI's environment from here: whatever it reads from it, the caller
/// passes on. A click outside or Escape closes it, as a popover does.
struct AnchoredPopover<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    /// The side of the anchor the popover sits on.
    var edge: Edge = .top
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { PassThroughView() }

    func updateNSView(_ view: NSView, context: Context) {
        let binding = $isPresented
        context.coordinator.onClose = {
            if binding.wrappedValue { binding.wrappedValue = false }
        }
        context.coordinator.update(
            wanted: isPresented, content: AnyView(content()), anchor: view, edge: edge
        )
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.update(wanted: false, content: nil, anchor: view, edge: .top)
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        /// Called once the popover has closed, however it was closed.
        var onClose: (() -> Void)?
        private var popover: NSPopover?
        private var host: NSHostingController<AnyView>?
        private var wanted = false
        private var latest: AnyView?
        private var showPending = false

        func update(wanted: Bool, content: AnyView?, anchor: NSView, edge: Edge) {
            self.wanted = wanted
            if let content { latest = content }
            if let popover, popover.isShown {
                if wanted, let content {
                    host?.rootView = content
                } else if !wanted {
                    popover.close()
                }
                return
            }
            guard wanted, !showPending else { return }
            // On the next turn of the run loop, not inside SwiftUI's update.
            showPending = true
            DispatchQueue.main.async { [weak self, weak anchor] in
                guard let self else { return }
                self.showPending = false
                guard self.wanted, self.popover == nil, let anchor, anchor.window != nil,
                      let content = self.latest else {
                    if self.wanted { self.onClose?() }
                    return
                }
                let host = NSHostingController(rootView: content)
                host.sizingOptions = .preferredContentSize
                let popover = NSPopover()
                popover.behavior = .transient
                popover.animates = true
                popover.contentViewController = host
                popover.delegate = self
                self.host = host
                self.popover = popover
                popover.show(
                    relativeTo: anchor.bounds, of: anchor,
                    preferredEdge: Self.rectEdge(edge, flipped: anchor.isFlipped)
                )
            }
        }

        func popoverDidClose(_ notification: Notification) {
            popover = nil
            host = nil
            onClose?()
        }

        /// `edge` as AppKit names it in a view's own coordinates: y grows
        /// upward unless the view is flipped.
        static func rectEdge(_ edge: Edge, flipped: Bool) -> NSRectEdge {
            switch edge {
            case .top: return flipped ? .minY : .maxY
            case .bottom: return flipped ? .maxY : .minY
            case .leading: return .minX
            case .trailing: return .maxX
            }
        }
    }
}

/// The anchor: it only marks where the popover points, and takes no clicks
/// from what it sits behind.
private final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
