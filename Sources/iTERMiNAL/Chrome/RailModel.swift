import Foundation

/// One button on the left rail.
///
/// Foundation-only, like the other pure logic in this app, so what can be
/// pinned and how pinning behaves is checked in CI rather than by clicking.
///
/// Everything but the first two opens a panel on the right. Those cases are
/// named with the raw value of the `SidePanel` they open, so `SidePanel` and
/// this list can't disagree about which is which, and `SidePanel` takes its
/// title and icon from here.
enum RailItem: String, CaseIterable, Identifiable {
    /// Home, the landing page. Still named `.terminal` from when it only
    /// switched the detail column back to the terminal surface.
    case terminal, workspaces
    case browser, files, notes, http, bytes
    case tasks, automations, skills, cheatsheet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .terminal: return "Home"
        case .workspaces: return "Spaces"
        case .browser: return "Browser"
        case .files: return "Files"
        case .notes: return "Notes"
        case .http: return "HTTP Client"
        case .bytes: return "Bytes"
        case .tasks: return "Tasks"
        case .automations: return "Automations"
        case .skills: return "Skills"
        case .cheatsheet: return "Cheatsheet"
        }
    }

    /// An SF Symbol name.
    var icon: String {
        switch self {
        case .terminal: return "house"
        case .workspaces: return "rectangle.stack"
        case .browser: return "globe"
        case .files: return "folder"
        case .notes: return "note.text"
        case .http: return "arrow.up.arrow.down"
        case .bytes: return "number.square"
        case .tasks: return "list.bullet.rectangle"
        case .automations: return "clock"
        case .skills: return "book"
        case .cheatsheet: return "text.book.closed"
        }
    }

    /// Whether a person can pin it to the rail or take it off. The first
    /// two are how you get anywhere at all — to the Home page, to your
    /// tabs — so they are always there (connecting to another machine is the
    /// globe's menu, bottom right); the rest live
    /// behind the rail's "···" menu until pinned.
    var isPinnable: Bool {
        switch self {
        case .terminal, .workspaces: return false
        case .browser, .files, .notes, .http, .bytes,
             .tasks, .automations, .skills, .cheatsheet: return true
        }
    }

    /// Whether it opens a panel in the trailing region, which is every item
    /// that can be pinned. Home and Spaces act on the window itself.
    var opensPanel: Bool { isPinnable }

    static let fixed: [RailItem] = allCases.filter { !$0.isPinnable }
    static let pinnable: [RailItem] = allCases.filter(\.isPinnable)

    /// Tasks carries a live badge of running shells, which is worth having in
    /// view, and the five panels that were a toggle away in the panels menu are
    /// one click away here; the rest wait behind "···" until someone wants
    /// them there.
    static let defaultPinned: [RailItem] = [.tasks, .browser, .files, .notes, .http, .bytes]

    /// What a build that had the rail but not the panel buttons offered to
    /// pin. Someone who kept its rail as it was has not seen the five new
    /// buttons, so `RailPins.addingPanelButtons` gives them to that rail once.
    static let panelButtons: [RailItem] = [.browser, .files, .notes, .http, .bytes]
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

    /// The stored pins with the panel buttons added after them, for a rail
    /// saved by a build that did not have those buttons. Run once, not on every
    /// launch, so a button taken off afterwards stays off. What was stored
    /// keeps its order, and nothing is added twice.
    static func addingPanelButtons(to raw: [String]) -> [String] {
        let kept = decode(raw)
        return encode(kept + RailItem.panelButtons.filter { !kept.contains($0) })
    }

    /// Pins `item` after the others, or unpins it. An item that can't be
    /// pinned leaves the list as it was.
    static func toggled(_ item: RailItem, in pins: [RailItem]) -> [RailItem] {
        guard item.isPinnable else { return pins }
        if pins.contains(item) { return pins.filter { $0 != item } }
        return pins + [item]
    }
}
