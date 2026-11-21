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

/// A row's place in the list and the slot a drop on it means.
struct SidebarSlotFrame: Equatable {
    var frame: CGRect
    var slot: SidebarDropSlot
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
    /// Reports this row's frame, and the slot a drop on it means, to the list.
    /// A nil slot reports nothing.
    func reportsDropSlot(_ slot: SidebarDropSlot?) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: SidebarSlotFramesKey.self,
                    value: slot.map {
                        [SidebarSlotFrame(frame: proxy.frame(in: .named(SidebarDrag.space)), slot: $0)]
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
    @Published private(set) var slot: SidebarDropSlot?
    @Published private(set) var slotFrame = CGRect.zero

    /// Kept current by the list; not published, since a row's frame changing is
    /// not something to redraw for.
    var frames: [SidebarSlotFrame] = []

    /// The terminal's id, or a tab's own for a tab with none.
    private var dragged: UUID?

    /// The pointer moved with `id` held, at `point` in the list's coordinates.
    func changed(terminal id: UUID, title: String, at point: CGPoint) {
        dragged = id
        self.title = title
        pointer = point
        // Rows are stacked, so the height alone says which one the pointer is
        // over — it still counts when it has strayed off to the side.
        let hit = frames.first { point.y >= $0.frame.minY && point.y < $0.frame.maxY }
        slot = hit?.slot
        slotFrame = hit?.frame ?? .zero
    }

    /// The pointer was let go: move the terminal if it is over a slot.
    func ended(store: WorkspaceStore) {
        let id = dragged
        let landing = slot
        dragged = nil
        title = nil
        slot = nil
        guard let id, let landing,
              let space = store.workspaces.first(where: { $0.id == landing.space }) else { return }
        let target = landing.before.flatMap { before in space.tabs.first { $0.id == before } }
        store.moveDragged(id, before: target, in: space)
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
                if let slot = model.slot {
                    mark(for: slot.mark, in: model.slotFrame)
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
