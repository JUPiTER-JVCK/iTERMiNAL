import AppKit

/// One entry the app adds to a terminal's right-click menu, beneath the
/// editing ones. Plain data on purpose: whoever supplies it knows about tabs
/// and panes, and the view that shows it has no business knowing either.
struct TerminalMenuAction {
    var title: String
    /// Shown beside the title. The menu bar is what makes the key work; this
    /// only tells the person it exists.
    var key: String = ""
    var modifiers: NSEvent.ModifierFlags = .command
    var perform: () -> Void
}

/// A menu item that runs a closure, for menus built the moment they open.
///
/// It is its own target, so nothing outside has to stay alive for it to work:
/// the menu holds the item, and the item holds what it does.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(ActionMenuItem.run), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() {
        handler()
    }
}

/// What a right-click in a terminal shows.
///
/// SwiftTerm answers the left mouse button and nothing else — it has no
/// `rightMouseDown` and sets no `menu` — so a right-click used to do nothing at
/// all. That also means a program with mouse reporting switched on never sees
/// the right button, so there is nothing here to take from it.
///
/// The menu is built each time it opens, because what it can do depends on the
/// moment: Copy needs a selection, and the pane items only make sense for a
/// terminal that is a pane.
enum TerminalContextMenu {
    @MainActor
    static func make(for terminal: InstrumentedTerminalView, actions: [TerminalMenuAction]) -> NSMenu {
        let menu = NSMenu(title: "Terminal")
        // The system adds its own entries to a context menu for a view that takes
        // text input — an "AutoFill" submenu showed up under the first real
        // menu taken of this one — and none of them has a meaning in a terminal.
        menu.allowsContextMenuPlugIns = false

        // The editing items are SwiftTerm's own, aimed at the terminal itself
        // rather than "whatever is first responder": a right-click does not
        // move focus, and Paste must land where the click did. SwiftTerm
        // validates all of them, so Copy is greyed out without a selection.
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), key: "c", target: terminal))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), key: "v", target: terminal))
        menu.addItem(item("Select All", #selector(NSResponder.selectAll(_:)), key: "a", target: terminal))

        menu.addItem(.separator())

        // SwiftTerm's own find bar, which it opens for this action and tag.
        let find = item("Find…", #selector(NSResponder.performTextFinderAction(_:)), key: "", target: terminal)
        find.tag = NSTextFinder.Action.showFindInterface.rawValue
        menu.addItem(find)

        // Only the history above the screen goes: what is on it stays, so
        // this is safe with a program running.
        menu.addItem(ActionMenuItem("Clear Scrollback") { [weak terminal] in
            terminal?.clearScrollback()
        })

        if !actions.isEmpty {
            menu.addItem(.separator())
            for action in actions {
                menu.addItem(ActionMenuItem(action.title, key: action.key, modifiers: action.modifiers, handler: action.perform))
            }
        }
        return menu
    }

    @MainActor
    private static func item(_ title: String, _ action: Selector, key: String, target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = .command }
        item.target = target
        return item
    }
}
