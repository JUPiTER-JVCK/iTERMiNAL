import Foundation

/// Where a tab lands when it is dragged to another place in the sidebar.
/// Foundation only, so the order it makes is checked off a Mac;
/// `WorkspaceStore.moveTab` applies it to a workspace's tabs.
enum TabOrder {
    /// `ids` with `id` placed just before `target`, or last when `target` is nil
    /// or is not in the list.
    ///
    /// `id` may already be in the list — a tab moved within its workspace — or
    /// not — a tab arriving from another one; either way it appears exactly once
    /// in the result. Dropping a tab on itself changes nothing.
    static func placing(_ id: UUID, before target: UUID?, in ids: [UUID]) -> [UUID] {
        guard target != id else { return ids }
        var result = ids.filter { $0 != id }
        if let target, let index = result.firstIndex(of: target) {
            result.insert(id, at: index)
        } else {
            result.append(id)
        }
        return result
    }
}
