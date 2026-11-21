import SwiftUI

/// Dragging a terminal between Spaces in the sidebar.
///
/// Built on a `DragGesture` and the rows' own frames rather than SwiftUI's
/// `draggable` / `dropDestination`, for the reason the dock's drag is
/// (`DockDragModel`): the rows are `Button`s, which take the mouse-down, so a
/// drag that starts on one may never begin. A gesture added beside the button
/// still sees the pointer, wherever it goes.

/// Where a drop would land: in `space`, before the tab `before`, or last when
/// that is nil.
struct SidebarDropSlot: Equatable {
    /// How the slot is shown while a terminal is over it.
    enum Mark: Equatable {
        case lineAbove, lineBelow, outline, none
    }

    var space: UUID
    var before: UUID?
    var mark: Mark
}

/// A terminal's row in the list, which can be dropped on to split with it.
struct SidebarJoin: Equatable {
    /// The terminal the dragged one would be put beside.
    var session: UUID
    /// The tab that terminal is in, so a terminal is not offered a split with
    /// the tab it is already part of.
    var tab: UUID
}

/// A row's place in the list and what a drop on it means: its `slot` at the
/// edge, and — for a terminal's row — joining it in the middle.
struct SidebarSlotFrame: Equatable {
    var frame: CGRect
    var slot: SidebarDropSlot
    var join: SidebarJoin?
    /// Which edge of the row `slot` is the zone for.
    var edgeAtTop: Bool
}

/// Where a terminal would end up if let go now.
enum SidebarLanding: Equatable {
    /// In a Space, at a place in its list.
    case slot(SidebarDropSlot)
    /// Beside another terminal, in its tab, as a split.
    case join(session: UUID)
}

struct SidebarSlotFramesKey: PreferenceKey {
    static var defaultValue: [SidebarSlotFrame] = []
    static func reduce(value: inout [SidebarSlotFrame], nextValue: () -> [SidebarSlotFrame]) {
        value.append(contentsOf: nextValue())
    }
}

enum SidebarDrag {
    /// The list's own coordinates: rows report their frames in it and the drag
    /// reports the pointer in it, so scrolling moves neither out of step.
    static let space = "sidebarList"
}

extension View {
    /// Reports this row's frame, and what a drop on it means, to the list. A nil
    /// slot reports nothing.
    ///
    /// With `join` the row is a terminal: the edge of it nearest `slot` keeps
    /// meaning that slot — where the terminal goes in the list — and the rest of
    /// it means a split with that terminal.
    func reportsDropSlot(
        _ slot: SidebarDropSlot?,
        join: SidebarJoin? = nil,
        edgeAtTop: Bool = true
    ) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SidebarSlotFramesKey.self,
                    value: slot.map {
                        [SidebarSlotFrame(
                            frame: proxy.frame(in: .named(SidebarDrag.space)),
                            slot: $0,
                            join: join,
                            edgeAtTop: edgeAtTop
                        )]
                    } ?? []
                )
            }
        )
    }
}

/// The terminal being dragged: what it is called, where the pointer is, and the
/// slot it would land in if let go here.
final class SidebarDragModel: ObservableObject {
    /// The dragged terminal's name; nil when nothing is being dragged.
    @Published private(set) var title: String?
    @Published private(set) var pointer = CGPoint.zero
    @Published private(set) var landing: SidebarLanding?
    /// The row the pointer is over, which is what the landing is drawn on.
    @Published private(set) var slotFrame = CGRect.zero

    /// Kept current by the list; not published, since a row's frame changing is
    /// not something to redraw for.
    var frames: [SidebarSlotFrame] = []

    /// The terminal's id, or a tab's own for a tab with none.
    private var dragged: UUID?

    /// The share of a terminal's row, at the edge nearest its slot, that still
    /// means "put it here in the list". The rest means "split with it".
    private static let edgeShare: CGFloat = 0.3

    /// The pointer moved with `id` held, at `point` in the list's coordinates.
    /// `tab` is the tab it is dragged out of.
    func changed(terminal id: UUID, from tab: UUID, title: String, at point: CGPoint) {
        dragged = id
        self.title = title
        pointer = point
        // Rows are stacked, so the height alone says which one the pointer is
        // over — it still counts when it has strayed off to the side.
        guard let hit = frames.first(where: { point.y >= $0.frame.minY && point.y < $0.frame.maxY }) else {
            landing = nil
            slotFrame = .zero
            return
        }
        slotFrame = hit.frame
        guard let join = hit.join else {
            landing = .slot(hit.slot)
            return
        }
        let zone = hit.frame.height * Self.edgeShare
        let inEdge = hit.edgeAtTop
            ? point.y < hit.frame.minY + zone
            : point.y >= hit.frame.maxY - zone
        if inEdge {
            landing = .slot(hit.slot)
        } else if join.tab == tab {
            // Over a terminal of its own tab: nothing to join.
            landing = nil
        } else {
            landing = .join(session: join.session)
        }
    }

    /// The pointer was let go: do what it was over.
    func ended(store: WorkspaceStore) {
        let id = dragged
        let result = landing
        dragged = nil
        title = nil
        landing = nil
        guard let id, let result else { return }
        switch result {
        case .slot(let slot):
            guard let space = store.workspaces.first(where: { $0.id == slot.space }) else { return }
            let target = slot.before.flatMap { before in space.tabs.first { $0.id == before } }
            store.moveDragged(id, before: target, in: space)
        case .join(let session):
            store.splitTerminal(id, beside: session)
        }
    }
}

/// The ghost that follows the pointer and the mark at the slot it is over.
/// Never takes a click: it sits on top of the rows it describes.
struct SidebarDragOverlay: View {
    @ObservedObject var model: SidebarDragModel
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let title = model.title {
                switch model.landing {
                case .slot(let slot):
                    mark(for: slot.mark, in: model.slotFrame)
                case .join:
                    // The whole row lit, not a line: it is not between two
                    // rows but onto one.
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(settings.accentColor.opacity(0.18))
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(settings.accentColor, lineWidth: 1.5)
                        )
                        .frame(width: max(model.slotFrame.width - 16, 0), height: model.slotFrame.height)
                        .offset(x: model.slotFrame.minX + 8, y: model.slotFrame.minY)
                case nil:
                    EmptyView()
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.regularMaterial))
                    .overlay(Capsule().strokeBorder(settings.accentColor.opacity(0.6), lineWidth: 1))
                    .fixedSize()
                    .offset(x: model.pointer.x + 12, y: model.pointer.y + 8)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func mark(for mark: SidebarDropSlot.Mark, in frame: CGRect) -> some View {
        switch mark {
        case .lineAbove:
            line(width: frame.width, x: frame.minX, y: frame.minY - 1)
        case .lineBelow:
            line(width: frame.width, x: frame.minX, y: frame.maxY - 1)
        case .outline:
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(settings.accentColor, lineWidth: 1.5)
                .frame(width: max(frame.width - 16, 0), height: frame.height)
                .offset(x: frame.minX + 8, y: frame.minY)
        case .none:
            EmptyView()
        }
    }

    private func line(width: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Rectangle()
            .fill(settings.accentColor)
            .frame(width: max(width - 16, 0), height: 2)
            .offset(x: x + 8, y: y)
    }
}
