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
        default: break
        }
        return aliases
    }
}

/// How the window groups what it lists, in the order it lists it.
enum ShortcutSection: CaseIterable, Hashable {
    case general, tabsAndPanes, panels, terminal, composer, http, palette, macOS

    var title: String {
        switch self {
        case .general: return "General"
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
    private static let printed: Set<Character> = ["⌃", "⌥", "⇧", "⌘", "↩", "⇥", "↑", "↓", "←", "→"]

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
        ShortcutEntry("palette.open", "Command palette", [ShortcutChord("k", cmd), ShortcutChord("p", cmd)], in: .general,
                      detail: "Search every action, including the ones with no shortcut"),
        ShortcutEntry("shortcuts.open", "Keyboard shortcuts", [ShortcutChord("/", cmd)], in: .general,
                      detail: "This list. Type to search; esc closes it"),
        ShortcutEntry("settings.open", "Settings", [ShortcutChord(",", cmd)], in: .general, .system),
        ShortcutEntry("tasks.open", "Task manager", [ShortcutChord("t", [option, cmd])], in: .general,
                      detail: "Every shell this app is running"),
        ShortcutEntry("sidebar.toggle", "Show or hide the sidebar", [ShortcutChord("s", [control, cmd])], in: .general),

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
        ShortcutEntry("tool.superfile", "superfile", [ShortcutChord("s", [option, cmd])], in: .panels,
                      detail: "Opening starts it; closing ends it"),
        ShortcutEntry("tool.btop", "btop", [ShortcutChord("p", [option, cmd])], in: .panels,
                      detail: "Opening starts it; closing ends it"),

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
