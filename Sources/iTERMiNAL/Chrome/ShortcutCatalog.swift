import Foundation

// The one list of what the keyboard does in this app.
//
// Settings, the sidebar's ? button and the README each kept a list of their
// own, written by hand, and none of them was complete: the menus bound about
// thirty shortcuts and the longest list showed seventeen. This is the list they
// all read now, and the one the Keyboard Shortcuts window shows.
//
// It cannot see the menus, so a test does: scripts/input-logic-check parses
// every `.keyboardShortcut(` in the sources and fails if one is missing here,
// or if an entry here marked `.bound` is no longer in the code. The README's
// shortcut table is checked the same way. What is not checked is marked as such
// (`.system`, `.view`) and is listed by hand.
//
// Foundation only, so that test can compile it without Xcode.

/// A key combination, written the way a menu binds it.
struct ShortcutChord: Hashable {
    /// The keys held down. `description`s below put them in the order macOS
    /// writes them: ⌃ ⌥ ⇧ ⌘.
    struct Modifiers: OptionSet, Hashable {
        let rawValue: Int
        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)
    }

    /// The key pressed with them.
    enum Key: Hashable {
        /// One character, lower-cased: "t", "+", "/".
        case character(Character)
        case `return`, tab, escape, up, down, left, right
        /// Keys the bundled tools use that the app's own shortcuts do not.
        /// `backspace` is the key a Mac labels delete (⌫); `forwardDelete`
        /// is ⌦ (fn-delete on a laptop).
        case space, backspace, forwardDelete, pageUp, pageDown, home, end
        /// F1, F2…
        case function(Int)
    }

    let key: Key
    let modifiers: Modifiers

    init(_ key: Key, _ modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    init(_ character: Character, _ modifiers: Modifiers = []) {
        self.init(.character(Character(character.lowercased())), modifiers)
    }

    /// One string per key cap: ["⇧", "⌘", "N"].
    var symbols: [String] {
        var symbols: [String] = []
        if modifiers.contains(.control) { symbols.append("⌃") }
        if modifiers.contains(.option) { symbols.append("⌥") }
        if modifiers.contains(.shift) { symbols.append("⇧") }
        if modifiers.contains(.command) { symbols.append("⌘") }
        switch key {
        case .character(let character): symbols.append(String(character).uppercased())
        case .return: symbols.append("↩")
        case .tab: symbols.append("⇥")
        case .escape: symbols.append("esc")
        case .up: symbols.append("↑")
        case .down: symbols.append("↓")
        case .left: symbols.append("←")
        case .right: symbols.append("→")
        case .space: symbols.append("Space")
        case .backspace: symbols.append("⌫")
        case .forwardDelete: symbols.append("⌦")
        case .pageUp: symbols.append("⇞")
        case .pageDown: symbols.append("⇟")
        case .home: symbols.append("↖")
        case .end: symbols.append("↘")
        case .function(let number): symbols.append("F\(number)")
        }
        return symbols
    }

    /// The keys as one string: "⇧⌘N".
    var display: String { symbols.joined() }

    /// The keys in words, for a screen reader: ["Shift", "Command", "N"].
    var words: [String] {
        var words: [String] = []
        if modifiers.contains(.control) { words.append("Control") }
        if modifiers.contains(.option) { words.append("Option") }
        if modifiers.contains(.shift) { words.append("Shift") }
        if modifiers.contains(.command) { words.append("Command") }
        switch key {
        case .character(let character):
            switch character {
            case "+": words.append("Plus")
            case "-": words.append("Minus")
            case "/": words.append("Slash")
            case ",": words.append("Comma")
            default: words.append(String(character).uppercased())
            }
        case .return: words.append("Return")
        case .tab: words.append("Tab")
        case .escape: words.append("Escape")
        case .up: words.append("Up Arrow")
        case .down: words.append("Down Arrow")
        case .left: words.append("Left Arrow")
        case .right: words.append("Right Arrow")
        case .space: words.append("Space")
        case .backspace: words.append("Delete")
        case .forwardDelete: words.append("Forward Delete")
        case .pageUp: words.append("Page Up")
        case .pageDown: words.append("Page Down")
        case .home: words.append("Home")
        case .end: words.append("End")
        case .function(let number): words.append("F\(number)")
        }
        return words
    }

    /// What a person might type to find it, beyond what is printed on it:
    /// "cmd", "alt", "enter".
    fileprivate var aliases: [String] {
        var aliases: [String] = []
        if modifiers.contains(.control) { aliases.append("ctrl") }
        if modifiers.contains(.option) { aliases.append(contentsOf: ["alt", "opt"]) }
        if modifiers.contains(.command) { aliases.append("cmd") }
        switch key {
        case .return: aliases.append("enter")
        case .escape: aliases.append("esc")
        case .backspace: aliases.append("backspace")
        case .forwardDelete: aliases.append("del")
        case .pageUp: aliases.append("pgup")
        case .pageDown: aliases.append("pgdown")
        default: break
        }
        return aliases
    }
}

/// How the window groups what it lists, in the order it lists it.
enum ShortcutSection: CaseIterable, Hashable {
    case general, tools, btop, superfile, tabsAndPanes, panels, terminal, composer, http, palette, macOS

    var title: String {
        switch self {
        case .general: return "General"
        case .tools: return "Tools"
        case .btop: return "Inside btop"
        case .superfile: return "Inside superfile"
        case .tabsAndPanes: return "Tabs and panes"
        case .panels: return "Panels"
        case .terminal: return "Terminal"
        case .composer: return "Composer"
        case .http: return "HTTP client and site explorer"
        case .palette: return "Command palette"
        case .macOS: return "macOS"
        }
    }
}

struct ShortcutEntry: Identifiable, Hashable {
    /// How far to trust an entry.
    enum Source: Hashable {
        /// Bound with `.keyboardShortcut` somewhere in the sources — and
        /// checked against them by the test, in both directions.
        case bound
        /// Provided by macOS for any app, and listed by hand.
        case system
        /// A key a view handles itself (Return in a field, ↑ in the composer),
        /// listed by hand. These are plain keys, so they cannot clash with a
        /// menu's ⌘ shortcuts, which win wherever they are bound.
        case view
        /// A key the program in a tool panel reads itself while that panel is
        /// in front: btop's or superfile's, from its own help for the version
        /// bundled (scripts/tools.env), listed by hand. The app never sees
        /// them, so btop and superfile may each use a key the other does, and
        /// a menu's ⌘ shortcut still wins, as it does over a view's keys.
        case tool
    }

    let id: String
    let title: String
    let detail: String?
    let chords: [ShortcutChord]
    let section: ShortcutSection
    let source: Source

    /// The words a search looks through, lower-cased: the title, the detail,
    /// the section, and the keys in words and by their other names.
    fileprivate let searchWords: [String]

    init(
        _ id: String,
        _ title: String,
        _ chords: [ShortcutChord],
        in section: ShortcutSection,
        _ source: Source = .bound,
        detail: String? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.chords = chords
        self.section = section
        self.source = source
        var parts = [title, detail ?? "", section.title]
        for chord in chords {
            parts.append(chord.words.joined(separator: " "))
            parts.append(chord.aliases.joined(separator: " "))
        }
        searchWords = parts.joined(separator: " ").lowercased()
            .split(whereSeparator: { $0 == " " })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    /// Keys as they are printed on a cap, and so what someone who pastes or
    /// types a shortcut into the search box is typing.
    private static let printed: Set<Character> = ["⌃", "⌥", "⇧", "⌘", "↩", "⇥", "↑", "↓", "←", "→", "⌫", "⌦", "⇞", "⇟", "↖", "↘"]

    /// Whether one search term finds this entry.
    ///
    /// A term made of printed keys ("⌘d") must be in how some chord prints, so
    /// it finds ⇧⌘D too. Any other term has to start a word — "split" finds
    /// "Split down", "term" finds "Terminal", and a lone "w" finds the keys
    /// that are W and the words that begin with it, not every word that has a
    /// w somewhere inside.
    fileprivate func matches(term: String) -> Bool {
        if term.contains(where: { Self.printed.contains($0) }) {
            return chords.contains { $0.display.lowercased().contains(term) }
        }
        return searchWords.contains { $0.hasPrefix(term) }
    }
}

/// One section's entries, as the window draws them.
struct ShortcutGroup: Identifiable {
    let section: ShortcutSection
    let entries: [ShortcutEntry]
    var id: ShortcutSection { section }
}

enum ShortcutCatalog {
    private static let cmd = ShortcutChord.Modifiers.command
    private static let shift = ShortcutChord.Modifiers.shift
    private static let option = ShortcutChord.Modifiers.option
    private static let control = ShortcutChord.Modifiers.control

    static let all: [ShortcutEntry] = [
        // MARK: General
        ShortcutEntry("palette.open", "Command palette", [ShortcutChord("k", cmd)], in: .general,
                      detail: "Search every action, including the ones with no shortcut"),
        ShortcutEntry("shortcuts.open", "Keyboard shortcuts", [ShortcutChord("/", cmd)], in: .general,
                      detail: "This list. Type to search; esc closes it"),
        ShortcutEntry("settings.open", "Settings", [ShortcutChord(",", cmd)], in: .general, .system),
        ShortcutEntry("tasks.open", "Task manager", [ShortcutChord("t", [option, cmd])], in: .general,
                      detail: "Every shell this app is running"),
        ShortcutEntry("sidebar.toggle", "Show or hide the sidebar", [ShortcutChord("s", [control, cmd])], in: .general),

        // MARK: Tools
        // The two programs that come with the app, near the top so they are
        // found without scrolling. Each runs in a panel of its own.
        ShortcutEntry("tool.btop", "btop", [ShortcutChord("p", [option, cmd])], in: .tools,
                      detail: "Resource monitor, in a panel. Opening starts it; closing ends it. Its own keys are under Inside btop"),
        ShortcutEntry("tool.btop.full", "btop in full view", [ShortcutChord("p", [option, shift, cmd])], in: .tools,
                      detail: "The same, across the whole content area"),
        ShortcutEntry("tool.superfile", "superfile", [ShortcutChord("s", [option, cmd])], in: .tools,
                      detail: "File manager, in a panel. Opening starts it; closing ends it. Its own keys are under Inside superfile"),
        ShortcutEntry("tool.superfile.full", "superfile in full view", [ShortcutChord("s", [option, shift, cmd])], in: .tools,
                      detail: "The same, across the whole content area"),

        // MARK: Inside btop
        // btop 1.4.7's own help (F1 in btop; `help_text` in its src/btop_menu.cpp
        // at the commit scripts/tools.env pins), minus the two mouse lines. btop's
        // keys are built in: no setting changes them.
        ShortcutEntry("btop.menu", "Main menu", [ShortcutChord(.escape), ShortcutChord("m")], in: .btop, .tool,
                      detail: "Opens or closes it"),
        ShortcutEntry("btop.help", "Help", [ShortcutChord(.function(1)), ShortcutChord("?"), ShortcutChord("h")], in: .btop, .tool,
                      detail: "btop's own list of these keys"),
        ShortcutEntry("btop.options", "Options", [ShortcutChord(.function(2)), ShortcutChord("o")], in: .btop, .tool),
        ShortcutEntry("btop.quit", "Quit btop", [ShortcutChord("q"), ShortcutChord("c", control)], in: .btop, .tool,
                      detail: "The panel then says it ended and offers Restart"),
        ShortcutEntry("btop.sleep", "Sleep, and put it in the background", [ShortcutChord("z", control)], in: .btop, .tool),
        ShortcutEntry("btop.reload", "Reload the config file", [ShortcutChord("r", control)], in: .btop, .tool),
        ShortcutEntry("btop.presetNext", "Next view preset", [ShortcutChord("p")], in: .btop, .tool),
        ShortcutEntry("btop.presetPrevious", "Previous view preset", [ShortcutChord("p", shift)], in: .btop, .tool),
        ShortcutEntry("btop.cpu", "Show or hide the CPU box", [ShortcutChord("1")], in: .btop, .tool),
        ShortcutEntry("btop.mem", "Show or hide the memory box", [ShortcutChord("2")], in: .btop, .tool),
        ShortcutEntry("btop.net", "Show or hide the network box", [ShortcutChord("3")], in: .btop, .tool),
        ShortcutEntry("btop.proc", "Show or hide the process box", [ShortcutChord("4")], in: .btop, .tool),
        ShortcutEntry("btop.gpu", "Show or hide the GPU box", [ShortcutChord("5")], in: .btop, .tool),
        ShortcutEntry("btop.disks", "Disks view in the memory box", [ShortcutChord("d")], in: .btop, .tool,
                      detail: "On or off"),
        ShortcutEntry("btop.diskIO", "Disk I/O mode, with big graphs", [ShortcutChord("i")], in: .btop, .tool,
                      detail: "On or off"),
        ShortcutEntry("btop.timer", "Update more or less often", [ShortcutChord("+"), ShortcutChord("-")], in: .btop, .tool,
                      detail: "100 ms each press"),
        ShortcutEntry("btop.netDevice", "Previous or next network device", [ShortcutChord("b"), ShortcutChord("n")], in: .btop, .tool),
        ShortcutEntry("btop.netReset", "Reset the totals for the network device", [ShortcutChord("z")], in: .btop, .tool,
                      detail: "On or off"),
        ShortcutEntry("btop.netAuto", "Auto scaling for the network graphs", [ShortcutChord("a")], in: .btop, .tool,
                      detail: "On or off"),
        ShortcutEntry("btop.netSync", "Synced scaling for the network graphs", [ShortcutChord("y")], in: .btop, .tool,
                      detail: "On or off"),
        ShortcutEntry("btop.select", "Move through the process list", [ShortcutChord(.up), ShortcutChord(.down)], in: .btop, .tool,
                      detail: "Or click a process"),
        ShortcutEntry("btop.page", "A page up or down the process list", [ShortcutChord(.pageUp), ShortcutChord(.pageDown)], in: .btop, .tool),
        ShortcutEntry("btop.ends", "First or last page of the process list", [ShortcutChord(.home), ShortcutChord(.end)], in: .btop, .tool),
        ShortcutEntry("btop.details", "Details of the selected process", [ShortcutChord(.return)], in: .btop, .tool),
        ShortcutEntry("btop.sortColumn", "Sort by the previous or next column", [ShortcutChord(.left), ShortcutChord(.right)], in: .btop, .tool),
        ShortcutEntry("btop.sortReverse", "Reverse the sort order", [ShortcutChord("r")], in: .btop, .tool),
        ShortcutEntry("btop.filter", "Filter the processes", [ShortcutChord("f"), ShortcutChord("/")], in: .btop, .tool,
                      detail: "Start with ! for a regular expression"),
        ShortcutEntry("btop.clearFilter", "Clear the filter", [ShortcutChord(.forwardDelete)], in: .btop, .tool),
        ShortcutEntry("btop.follow", "Follow the selected process", [ShortcutChord("f", shift)], in: .btop, .tool),
        ShortcutEntry("btop.pause", "Pause the process list", [ShortcutChord("u")], in: .btop, .tool),
        ShortcutEntry("btop.perCore", "Per-core CPU use of processes", [ShortcutChord("c")], in: .btop, .tool,
                      detail: "On or off"),
        ShortcutEntry("btop.memMode", "Memory display mode in the process box", [ShortcutChord("%")], in: .btop, .tool),
        ShortcutEntry("btop.tree", "Tree view of the processes", [ShortcutChord("e")], in: .btop, .tool,
                      detail: "On or off"),
        ShortcutEntry("btop.treeAll", "Expand or collapse every process", [ShortcutChord("e", shift)], in: .btop, .tool,
                      detail: "In tree view"),
        ShortcutEntry("btop.expand", "Expand or collapse the selected process", [ShortcutChord(.space), ShortcutChord("+"), ShortcutChord("-")],
                      in: .btop, .tool, detail: "In tree view; + and − with a process selected"),
        ShortcutEntry("btop.children", "Expand or collapse its children", [ShortcutChord("c", shift)], in: .btop, .tool,
                      detail: "Of the selected process"),
        ShortcutEntry("btop.terminate", "Terminate the selected process", [ShortcutChord("t")], in: .btop, .tool,
                      detail: "SIGTERM, 15"),
        ShortcutEntry("btop.kill", "Kill the selected process", [ShortcutChord("k")], in: .btop, .tool,
                      detail: "SIGKILL, 9"),
        ShortcutEntry("btop.signal", "Send a signal to the selected process", [ShortcutChord("s")], in: .btop, .tool,
                      detail: "Pick one, or type its number"),
        ShortcutEntry("btop.nice", "Change the selected process's nice value", [ShortcutChord("n", shift)], in: .btop, .tool),

        // MARK: Inside superfile
        // superfile 1.6.0's default hotkeys (src/superfile_config/hotkeys.toml at
        // its v1.6.0 tag), described as superfile's hotkey list does
        // (superfile.dev/list/hotkey-list). The app does not change them; a
        // hotkeys.toml of your own in superfile's config folder does.
        ShortcutEntry("superfile.help", "Help", [ShortcutChord("?")], in: .superfile, .tool,
                      detail: "superfile's full hotkey list"),
        ShortcutEntry("superfile.confirm", "Open the selected item", [ShortcutChord(.return), ShortcutChord(.right), ShortcutChord("l")],
                      in: .superfile, .tool),
        ShortcutEntry("superfile.quit", "Quit typing, a dialog, or superfile", [ShortcutChord("q"), ShortcutChord(.escape)],
                      in: .superfile, .tool),
        ShortcutEntry("superfile.cdQuit", "Quit, and cd to the current folder", [ShortcutChord("q", shift)], in: .superfile, .tool,
                      detail: "The panel runs superfile without a shell, so here it only quits"),
        ShortcutEntry("superfile.up", "Up", [ShortcutChord(.up), ShortcutChord("k")], in: .superfile, .tool),
        ShortcutEntry("superfile.down", "Down", [ShortcutChord(.down), ShortcutChord("j")], in: .superfile, .tool),
        ShortcutEntry("superfile.pageUp", "Page up", [ShortcutChord(.pageUp)], in: .superfile, .tool),
        ShortcutEntry("superfile.pageDown", "Page down", [ShortcutChord(.pageDown)], in: .superfile, .tool),
        ShortcutEntry("superfile.parent", "Back to the parent folder", [ShortcutChord("h"), ShortcutChord(.left), ShortcutChord(.backspace)],
                      in: .superfile, .tool),
        ShortcutEntry("superfile.search", "Search", [ShortcutChord("/")], in: .superfile, .tool,
                      detail: "Opens or closes the search bar"),
        ShortcutEntry("superfile.dotFiles", "Show or hide dot files", [ShortcutChord(".")], in: .superfile, .tool),
        ShortcutEntry("superfile.pin", "Pin or unpin the folder in the sidebar", [ShortcutChord("p", shift)], in: .superfile, .tool),
        ShortcutEntry("superfile.newPanel", "New file panel", [ShortcutChord("n")], in: .superfile, .tool),
        ShortcutEntry("superfile.split", "Split the file panel", [ShortcutChord("n", shift)], in: .superfile, .tool),
        ShortcutEntry("superfile.closePanel", "Close the file panel", [ShortcutChord("w")], in: .superfile, .tool),
        ShortcutEntry("superfile.nextPanel", "Next file panel", [ShortcutChord(.tab), ShortcutChord("l", shift)], in: .superfile, .tool),
        ShortcutEntry("superfile.previousPanel", "Previous file panel", [ShortcutChord(.left, shift), ShortcutChord("h", shift)],
                      in: .superfile, .tool),
        ShortcutEntry("superfile.preview", "Show or hide the preview panel", [ShortcutChord("f")], in: .superfile, .tool),
        ShortcutEntry("superfile.footer", "Show or hide the footer", [ShortcutChord("f", shift)], in: .superfile, .tool),
        ShortcutEntry("superfile.sort", "Sort options", [ShortcutChord("o")], in: .superfile, .tool),
        ShortcutEntry("superfile.reverseSort", "Reverse the sort", [ShortcutChord("r", shift)], in: .superfile, .tool),
        ShortcutEntry("superfile.sidebar", "Focus the sidebar", [ShortcutChord("s")], in: .superfile, .tool),
        ShortcutEntry("superfile.processBar", "Focus the process bar", [ShortcutChord("p")], in: .superfile, .tool),
        ShortcutEntry("superfile.metadata", "Focus the metadata panel", [ShortcutChord("m")], in: .superfile, .tool),
        ShortcutEntry("superfile.mode", "Selection mode or normal mode", [ShortcutChord("v")], in: .superfile, .tool),
        ShortcutEntry("superfile.selectAll", "Select every item in the panel", [ShortcutChord("a", shift)], in: .superfile, .tool,
                      detail: "In selection mode"),
        ShortcutEntry("superfile.selectUp", "Select upward from the cursor", [ShortcutChord(.up, shift), ShortcutChord("k", shift)],
                      in: .superfile, .tool, detail: "In selection mode"),
        ShortcutEntry("superfile.selectDown", "Select downward from the cursor", [ShortcutChord(.down, shift), ShortcutChord("j", shift)],
                      in: .superfile, .tool, detail: "In selection mode"),
        ShortcutEntry("superfile.create", "Create a file or folder", [ShortcutChord("n", control)], in: .superfile, .tool,
                      detail: "End the name with / for a folder"),
        ShortcutEntry("superfile.rename", "Rename", [ShortcutChord("r", control)], in: .superfile, .tool),
        ShortcutEntry("superfile.copy", "Copy the selected items", [ShortcutChord("c", control)], in: .superfile, .tool,
                      detail: "To superfile's clipboard"),
        ShortcutEntry("superfile.cut", "Cut the selected items", [ShortcutChord("x", control)], in: .superfile, .tool),
        ShortcutEntry("superfile.paste", "Paste into this panel", [ShortcutChord("v", control), ShortcutChord("w", control)],
                      in: .superfile, .tool),
        ShortcutEntry("superfile.delete", "Delete the selected items", [ShortcutChord("d", control), ShortcutChord(.forwardDelete)],
                      in: .superfile, .tool),
        ShortcutEntry("superfile.deleteForever", "Delete permanently", [ShortcutChord("d", shift)], in: .superfile, .tool),
        ShortcutEntry("superfile.copyPath", "Copy the path of the current or selected items", [ShortcutChord("p", control)],
                      in: .superfile, .tool),
        ShortcutEntry("superfile.copyFolder", "Copy the current folder's path", [ShortcutChord("c")], in: .superfile, .tool),
        ShortcutEntry("superfile.extract", "Extract an archive", [ShortcutChord("e", control)], in: .superfile, .tool),
        ShortcutEntry("superfile.compress", "Zip a file or folder", [ShortcutChord("a", control)], in: .superfile, .tool),
        ShortcutEntry("superfile.edit", "Open the file in your editor", [ShortcutChord("e")], in: .superfile, .tool),
        ShortcutEntry("superfile.editFolder", "Open the folder in your editor", [ShortcutChord("e", shift)], in: .superfile, .tool),
        ShortcutEntry("superfile.shellPrompt", "Prompt, in shell mode", [ShortcutChord(":")], in: .superfile, .tool),
        ShortcutEntry("superfile.spfPrompt", "Prompt, in superfile mode", [ShortcutChord(">")], in: .superfile, .tool),
        ShortcutEntry("superfile.zoxide", "Jump with zoxide", [ShortcutChord("z")], in: .superfile, .tool,
                      detail: "Needs zoxide, and zoxide_support turned on in superfile's config; it is off by default"),

        // MARK: Tabs and panes
        ShortcutEntry("tab.new", "New terminal tab", [ShortcutChord("t", cmd)], in: .tabsAndPanes),
        ShortcutEntry("workspace.new", "New workspace", [ShortcutChord("n", [shift, cmd])], in: .tabsAndPanes),
        ShortcutEntry("split.right", "Split right", [ShortcutChord("d", cmd)], in: .tabsAndPanes),
        ShortcutEntry("split.down", "Split down", [ShortcutChord("d", [shift, cmd])], in: .tabsAndPanes),
        ShortcutEntry("split.browser", "Split with browser", [ShortcutChord("b", [shift, cmd])], in: .tabsAndPanes),
        ShortcutEntry("pane.close", "Close pane", [ShortcutChord("w", [shift, cmd])], in: .tabsAndPanes),
        ShortcutEntry("tab.close", "Close tab", [ShortcutChord("w", [control, cmd])], in: .tabsAndPanes),

        // MARK: Panels
        ShortcutEntry("dock.toggle", "Terminal dock", [ShortcutChord("j", cmd)], in: .panels,
                      detail: "Show or hide the dock along the bottom"),
        ShortcutEntry("panel.browser", "Browser panel", [ShortcutChord("b", [option, cmd])], in: .panels),
        ShortcutEntry("panel.files", "Files panel", [ShortcutChord("f", [option, cmd])], in: .panels),
        ShortcutEntry("panel.notes", "Notes panel", [ShortcutChord("n", [option, cmd])], in: .panels),
        ShortcutEntry("panel.http", "HTTP client panel", [ShortcutChord("r", [option, cmd])], in: .panels),

        // MARK: Terminal
        ShortcutEntry("font.bigger", "Bigger text", [ShortcutChord("+", cmd)], in: .terminal),
        ShortcutEntry("font.smaller", "Smaller text", [ShortcutChord("-", cmd)], in: .terminal),
        ShortcutEntry("font.reset", "Actual size", [ShortcutChord("0", cmd)], in: .terminal),
        ShortcutEntry("edit.copy", "Copy", [ShortcutChord("c", cmd)], in: .terminal, .system,
                      detail: "The selected text"),
        ShortcutEntry("edit.paste", "Paste", [ShortcutChord("v", cmd)], in: .terminal, .system),

        // MARK: Composer
        ShortcutEntry("composer.focus", "Focus the composer", [ShortcutChord("r", [shift, cmd])], in: .composer),
        ShortcutEntry("composer.collapse", "Minimise or expand the composer", [ShortcutChord("m", [shift, cmd])], in: .composer),
        ShortcutEntry("composer.explain", "Explain the last output", [ShortcutChord("e", [option, cmd])], in: .composer,
                      detail: "Asks the assistant about what the composer's terminal last printed; runs nothing"),
        ShortcutEntry("composer.fix", "Suggest a fix", [ShortcutChord("x", [option, cmd])], in: .composer,
                      detail: "The same, for an error; it is shown, never run"),
        ShortcutEntry("composer.run", "Run the command", [ShortcutChord(.return)], in: .composer, .view,
                      detail: "In the composer's input"),
        ShortcutEntry("composer.newline", "New line in the command", [ShortcutChord(.return, shift), ShortcutChord(.return, option)],
                      in: .composer, .view),
        ShortcutEntry("composer.recall", "Earlier or later commands", [ShortcutChord(.up), ShortcutChord(.down)],
                      in: .composer, .view, detail: "From a one-line command"),
        ShortcutEntry("composer.accept", "Take the grey suggestion", [ShortcutChord(.right), ShortcutChord(.tab)],
                      in: .composer, .view, detail: "With the caret at the end of the line"),
        ShortcutEntry("composer.complete", "Complete a file name", [ShortcutChord(.tab)], in: .composer, .view,
                      detail: "Fills in what the candidates share, then lists the rest"),
        ShortcutEntry("composer.history", "Search history", [ShortcutChord("r", control)], in: .composer, .view),
        ShortcutEntry("composer.dismiss", "Wave the suggestion away", [ShortcutChord(.escape)], in: .composer, .view),
        ShortcutEntry("suggestions.move", "Move through a suggestion list", [ShortcutChord(.up), ShortcutChord(.down)],
                      in: .composer, .view),
        ShortcutEntry("suggestions.choose", "Put the choice in the input", [ShortcutChord(.return), ShortcutChord(.tab)],
                      in: .composer, .view, detail: "It is not run"),
        ShortcutEntry("suggestions.close", "Close a suggestion list", [ShortcutChord(.escape)], in: .composer, .view),

        // MARK: HTTP client and site explorer
        ShortcutEntry("http.send", "Send the request", [ShortcutChord(.return, cmd)], in: .http,
                      detail: "From anywhere in the HTTP client"),
        ShortcutEntry("http.sendField", "Send from the address field", [ShortcutChord(.return)], in: .http, .view),
        ShortcutEntry("http.history", "Load the selected request from history", [ShortcutChord(.return)], in: .http, .view),
        ShortcutEntry("explorer.run", "Run a command at the explorer's prompt", [ShortcutChord(.return)], in: .http, .view),
        ShortcutEntry("explorer.recall", "Earlier or later line at the prompt", [ShortcutChord(.up), ShortcutChord(.down)],
                      in: .http, .view),
        ShortcutEntry("explorer.complete", "Complete a command or path", [ShortcutChord(.tab)], in: .http, .view),
        ShortcutEntry("explorer.cancel", "Cancel what is running, or clear the line", [ShortcutChord(.escape)], in: .http, .view),

        // MARK: Command palette
        ShortcutEntry("palette.move", "Move through the results", [ShortcutChord(.up), ShortcutChord(.down)], in: .palette, .view),
        ShortcutEntry("palette.run", "Run the selected action", [ShortcutChord(.return)], in: .palette, .view),
        ShortcutEntry("palette.close", "Close the palette", [ShortcutChord(.escape)], in: .palette, .view),

        // MARK: macOS
        ShortcutEntry("app.hide", "Hide iTERMiNAL", [ShortcutChord("h", cmd)], in: .macOS, .system),
        ShortcutEntry("window.minimize", "Minimise the window", [ShortcutChord("m", cmd)], in: .macOS, .system),
        ShortcutEntry("window.close", "Close the window", [ShortcutChord("w", cmd)], in: .macOS, .system),
        ShortcutEntry("app.quit", "Quit iTERMiNAL", [ShortcutChord("q", cmd)], in: .macOS, .system),
    ]

    /// The sections that have something to show, each with its entries, in
    /// order — all of them for an empty query. A query is words, and an entry
    /// must match every one (see `ShortcutEntry.matches(term:)`): "shift
    /// split" finds Split down and Split with browser, "alt" every ⌥ shortcut.
    static func groups(matching query: String) -> [ShortcutGroup] {
        let terms = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        return ShortcutSection.allCases.compactMap { section in
            let entries = all.filter { entry in
                entry.section == section && terms.allSatisfy { entry.matches(term: $0) }
            }
            return entries.isEmpty ? nil : ShortcutGroup(section: section, entries: entries)
        }
    }
}
