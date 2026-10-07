import Foundation

/// One destination on the left rail.
///
/// Foundation-only, like the other pure logic in this app, so what can be
/// pinned and how pinning behaves is checked in CI rather than by clicking.
enum RailItem: String, CaseIterable, Identifiable {
    case terminal, workspaces, connections, tasks, automations, skills

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .workspaces: return "Workspaces"
        case .connections: return "Connect"
        case .tasks: return "Tasks"
        case .automations: return "Automations"
        case .skills: return "Skills"
        }
    }

    /// An SF Symbol name.
    var icon: String {
        switch self {
        case .terminal: return "house"
        case .workspaces: return "rectangle.stack"
        case .connections: return "network"
        case .tasks: return "list.bullet.rectangle"
        case .automations: return "clock"
        case .skills: return "book"
        }
    }

    /// Whether a person can pin it to the rail or take it off. The first
    /// three are how you get anywhere at all — back to the terminal, to your
    /// tabs, to another machine — so they are always there; the rest live
    /// behind the rail's "···" menu until pinned.
    var isPinnable: Bool {
        switch self {
        case .terminal, .workspaces, .connections: return false
        case .tasks, .automations, .skills: return true
        }
    }

    static let fixed: [RailItem] = allCases.filter { !$0.isPinnable }
    static let pinnable: [RailItem] = allCases.filter(\.isPinnable)

    /// Tasks carries a live badge of running shells, which is worth having in
    /// view; the other two are placeholder pages.
    static let defaultPinned: [RailItem] = [.tasks]
}

/// Reading and changing the stored list of pinned items.
enum RailPins {
    /// What was stored, made safe to use: unknown values (an item a newer
    /// build had and this one doesn't), items that can't be pinned, and
    /// repeats are dropped; what's left keeps its stored order.
    static func decode(_ raw: [String]) -> [RailItem] {
        var seen = Set<RailItem>()
        return raw
            .compactMap { RailItem(rawValue: $0) }
            .filter { $0.isPinnable && seen.insert($0).inserted }
    }

    static func encode(_ items: [RailItem]) -> [String] {
        items.map(\.rawValue)
    }

    /// Pins `item` after the others, or unpins it. An item that can't be
    /// pinned leaves the list as it was.
    static func toggled(_ item: RailItem, in pins: [RailItem]) -> [RailItem] {
        guard item.isPinnable else { return pins }
        if pins.contains(item) { return pins.filter { $0 != item } }
        return pins + [item]
    }
}
