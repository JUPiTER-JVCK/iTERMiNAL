import Foundation

// What to press in the text editors people run in a terminal: Vim, nano, Emacs,
// micro.
//
// Apart from `ShortcutCatalog` on purpose. That list is the app's own keys, held
// to the menus by a test; these are read by a program in the terminal, which the
// app never sees, and most are sequences — `dd`, `:wq`, ⌃X ⌃S — where a shortcut
// is one key with its modifiers. Mixing them in would have the test reading
// `dd` as the same chord twice.
//
// Listed by hand, from each editor's own documentation, for its default keys.
// A config file that rebinds them is not reflected.
//
// Foundation only, so it can be compiled without Xcode.

/// An editor, as the Keyboard Shortcuts window groups them.
enum EditorKeySection: CaseIterable, Hashable, Identifiable {
    case vim, nano, emacs, micro

    var id: EditorKeySection { self }

    var title: String {
        switch self {
        case .vim: return "Editor: Vim and Neovim"
        case .nano: return "Editor: nano"
        case .emacs: return "Editor: Emacs (in the terminal)"
        case .micro: return "Editor: micro"
        }
    }

    /// What the keys below assume, shown under the heading.
    var note: String {
        switch self {
        case .vim:
            return "Normal mode unless it says otherwise; esc gets back to it. Typed one after another, not held together. vi and Neovim take the same ones."
        case .nano:
            return "⌃ is Control. ⌥ keys are nano's Meta (M-) keys: they need Option sent as Meta in the terminal."
        case .emacs:
            return "⌃ is Control, ⌥ is Meta (M-), which needs Option sent as Meta in the terminal — or press esc, then the key. Keys in a row are pressed one after another."
        case .micro:
            return "micro's default keys, which are the ones most programs use. Typed in the terminal."
        }
    }

    /// Other names to find it by.
    fileprivate var names: [String] {
        switch self {
        case .vim: return ["vim", "vi", "neovim", "nvim"]
        case .nano: return ["nano", "pico"]
        case .emacs: return ["emacs", "emacsclient"]
        case .micro: return ["micro"]
        }
    }
}

struct EditorKeyEntry: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String?
    /// The ways to do it. Each way is the keys pressed in turn, one string per
    /// key cap: [":wq", "↩"].
    let ways: [[String]]
    let section: EditorKeySection
    fileprivate let searchWords: [String]

    /// `ways` are written as the keys separated by spaces — ":wq ↩" — and a
    /// cap may be several characters when they are typed rather than pressed
    /// together: ":wq", "dd", "gg".
    init(_ id: String, _ title: String, _ ways: [String], in section: EditorKeySection, detail: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.ways = ways.map { $0.split(separator: " ").map(String.init) }
        self.section = section

        var words: [String] = []
        let prose = [title, detail ?? "", section.title] + section.names
        for text in prose {
            words += text.lowercased()
                .split(whereSeparator: { $0 == " " })
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }
                .filter { !$0.isEmpty }
        }
        for way in self.ways {
            // As typed, in one piece, and cap by cap — a search for ":wq" or
            // "dd" finds it either way.
            words.append(way.joined().lowercased())
            words += way.map { $0.lowercased() }
            if way.contains(where: { $0.contains("⌃") }) { words.append("ctrl") }
            if way.contains(where: { $0.contains("⌥") }) { words += ["alt", "opt", "option", "meta"] }
            if way.contains("↩") { words += ["enter", "return"] }
            if way.contains("esc") { words.append("escape") }
        }
        searchWords = words
    }

    fileprivate func matches(term: String) -> Bool {
        searchWords.contains { $0.hasPrefix(term) }
    }
}

struct EditorKeyGroup: Identifiable {
    let section: EditorKeySection
    let commands: [EditorKeyEntry]
    var id: EditorKeySection { section }
}

enum EditorKeyCatalog {
    static let all: [EditorKeyEntry] = vim + nano + emacs + micro

    /// The editors that have something to show, each with its commands, in order
    /// — all of them for an empty query. Every word of the query has to match,
    /// as in the shortcut list: "vim save" finds Vim's two ways to save, "ctrl"
    /// every command with a Control key.
    static func groups(matching query: String) -> [EditorKeyGroup] {
        let terms = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        return EditorKeySection.allCases.compactMap { section in
            let commands = all.filter { command in
                command.section == section && terms.allSatisfy { command.matches(term: $0) }
            }
            return commands.isEmpty ? nil : EditorKeyGroup(section: section, commands: commands)
        }
    }

    // MARK: Vim

    private static let vim: [EditorKeyEntry] = [
        EditorKeyEntry("vim.insert", "Insert before the cursor", ["i"], in: .vim),
        EditorKeyEntry("vim.append", "Insert after the cursor", ["a"], in: .vim),
        EditorKeyEntry("vim.insertLineStart", "Insert at the start of the line", ["I"], in: .vim),
        EditorKeyEntry("vim.appendLineEnd", "Insert at the end of the line", ["A"], in: .vim),
        EditorKeyEntry("vim.openBelow", "New line below, and insert", ["o"], in: .vim),
        EditorKeyEntry("vim.openAbove", "New line above, and insert", ["O"], in: .vim),
        EditorKeyEntry("vim.normal", "Back to normal mode", ["esc", "⌃["], in: .vim),
        EditorKeyEntry("vim.visual", "Select by character", ["v"], in: .vim, detail: "Visual mode"),
        EditorKeyEntry("vim.visualLine", "Select by line", ["V"], in: .vim),
        EditorKeyEntry("vim.visualBlock", "Select a block", ["⌃V"], in: .vim),

        EditorKeyEntry("vim.save", "Save", [":w ↩"], in: .vim),
        EditorKeyEntry("vim.saveQuit", "Save and quit", [":wq ↩", "ZZ"], in: .vim),
        EditorKeyEntry("vim.quit", "Quit", [":q ↩"], in: .vim, detail: "Refuses while there are unsaved changes"),
        EditorKeyEntry("vim.quitForce", "Quit without saving", [":q! ↩", "ZQ"], in: .vim),
        EditorKeyEntry("vim.saveAllQuit", "Save every file and quit", [":wqa ↩"], in: .vim),

        EditorKeyEntry("vim.move", "Left, down, up, right", ["h", "j", "k", "l"], in: .vim),
        EditorKeyEntry("vim.wordForward", "Next word", ["w"], in: .vim),
        EditorKeyEntry("vim.wordBack", "Previous word", ["b"], in: .vim),
        EditorKeyEntry("vim.wordEnd", "End of the word", ["e"], in: .vim),
        EditorKeyEntry("vim.lineStart", "Start of the line", ["0"], in: .vim),
        EditorKeyEntry("vim.lineEnd", "End of the line", ["$"], in: .vim),
        EditorKeyEntry("vim.top", "Top of the file", ["gg"], in: .vim),
        EditorKeyEntry("vim.bottom", "Bottom of the file", ["G"], in: .vim),
        EditorKeyEntry("vim.gotoLine", "Go to a line", [":42 ↩", "42G"], in: .vim, detail: "With the line's number"),
        EditorKeyEntry("vim.pageHalf", "Half a page down or up", ["⌃D", "⌃U"], in: .vim),
        EditorKeyEntry("vim.pageFull", "A page down or up", ["⌃F", "⌃B"], in: .vim),
        EditorKeyEntry("vim.bracket", "Jump to the matching bracket", ["%"], in: .vim),

        EditorKeyEntry("vim.deleteChar", "Delete the character", ["x"], in: .vim),
        EditorKeyEntry("vim.deleteLine", "Delete the line", ["dd"], in: .vim, detail: "Into the register, so p puts it back"),
        EditorKeyEntry("vim.deleteToEnd", "Delete to the end of the line", ["D"], in: .vim),
        EditorKeyEntry("vim.deleteWord", "Delete a word", ["dw"], in: .vim),
        EditorKeyEntry("vim.changeWord", "Change a word", ["cw"], in: .vim, detail: "Deletes it and starts inserting"),
        EditorKeyEntry("vim.changeLine", "Change the line", ["cc"], in: .vim),
        EditorKeyEntry("vim.yankLine", "Copy the line", ["yy"], in: .vim, detail: "Yank"),
        EditorKeyEntry("vim.paste", "Paste after or before the cursor", ["p", "P"], in: .vim),
        EditorKeyEntry("vim.undo", "Undo", ["u"], in: .vim),
        EditorKeyEntry("vim.redo", "Redo", ["⌃R"], in: .vim),
        EditorKeyEntry("vim.repeat", "Repeat the last change", ["."], in: .vim),
        EditorKeyEntry("vim.join", "Join the next line on", ["J"], in: .vim),
        EditorKeyEntry("vim.indent", "Indent or outdent the line", [">>", "<<"], in: .vim),

        EditorKeyEntry("vim.search", "Search forward", ["/word ↩"], in: .vim, detail: "? searches backward"),
        EditorKeyEntry("vim.searchNext", "Next or previous match", ["n", "N"], in: .vim),
        EditorKeyEntry("vim.searchWord", "Search for the word under the cursor", ["*"], in: .vim),
        EditorKeyEntry("vim.replace", "Replace in the whole file", [":%s/old/new/g ↩"], in: .vim,
                      detail: "Add c at the end to be asked each time"),
        EditorKeyEntry("vim.noHighlight", "Clear the search highlight", [":noh ↩"], in: .vim),

        EditorKeyEntry("vim.edit", "Open another file", [":e file ↩"], in: .vim),
        EditorKeyEntry("vim.split", "Split the window", [":sp ↩", ":vsp ↩"], in: .vim, detail: "Across, then side by side"),
        EditorKeyEntry("vim.window", "Move to the next window", ["⌃W w"], in: .vim, detail: "Press ⌃W, let go, then w"),
        EditorKeyEntry("vim.buffers", "Next or previous file", [":bn ↩", ":bp ↩"], in: .vim, detail: "Buffers"),
        EditorKeyEntry("vim.numbers", "Show line numbers", [":set number ↩"], in: .vim),
        EditorKeyEntry("vim.help", "Help", [":help ↩"], in: .vim, detail: ":help followed by a topic opens that topic"),
    ]

    // MARK: nano

    private static let nano: [EditorKeyEntry] = [
        EditorKeyEntry("nano.save", "Save (Write Out)", ["⌃O ↩"], in: .nano, detail: "⌃O, then return to confirm the file name"),
        EditorKeyEntry("nano.exit", "Exit", ["⌃X"], in: .nano, detail: "Asks to save if there are changes"),
        EditorKeyEntry("nano.read", "Insert another file", ["⌃R"], in: .nano),
        EditorKeyEntry("nano.cutLine", "Cut the line", ["⌃K"], in: .nano),
        EditorKeyEntry("nano.paste", "Paste", ["⌃U"], in: .nano),
        EditorKeyEntry("nano.search", "Search", ["⌃W"], in: .nano, detail: "⌥W finds the next match"),
        EditorKeyEntry("nano.replace", "Search and replace", ["⌃\\"], in: .nano),
        EditorKeyEntry("nano.gotoLine", "Go to a line", ["⌃_", "⌥G"], in: .nano),
        EditorKeyEntry("nano.undo", "Undo", ["⌥U"], in: .nano),
        EditorKeyEntry("nano.redo", "Redo", ["⌥E"], in: .nano),
        EditorKeyEntry("nano.lineEnds", "Start or end of the line", ["⌃A", "⌃E"], in: .nano),
        EditorKeyEntry("nano.page", "A page up or down", ["⌃Y", "⌃V"], in: .nano),
        EditorKeyEntry("nano.mark", "Start selecting", ["⌥A"], in: .nano, detail: "Move to extend it; ⌃K cuts it"),
        EditorKeyEntry("nano.copy", "Copy the line or selection", ["⌥6"], in: .nano),
        EditorKeyEntry("nano.justify", "Justify the paragraph", ["⌃J"], in: .nano),
        EditorKeyEntry("nano.position", "Show the cursor's position", ["⌃C"], in: .nano),
        EditorKeyEntry("nano.numbers", "Show or hide line numbers", ["⌥N"], in: .nano),
        EditorKeyEntry("nano.refresh", "Redraw the screen", ["⌃L"], in: .nano),
        EditorKeyEntry("nano.help", "Help", ["⌃G"], in: .nano),
    ]

    // MARK: Emacs

    private static let emacs: [EditorKeyEntry] = [
        EditorKeyEntry("emacs.save", "Save", ["⌃X ⌃S"], in: .emacs),
        EditorKeyEntry("emacs.quit", "Quit", ["⌃X ⌃C"], in: .emacs),
        EditorKeyEntry("emacs.open", "Open a file", ["⌃X ⌃F"], in: .emacs),
        EditorKeyEntry("emacs.cancel", "Cancel what is half typed", ["⌃G"], in: .emacs),
        EditorKeyEntry("emacs.command", "Run a command by name", ["⌥X"], in: .emacs),
        EditorKeyEntry("emacs.move", "Forward, back, next line, previous line", ["⌃F", "⌃B", "⌃N", "⌃P"], in: .emacs),
        EditorKeyEntry("emacs.word", "Forward or back a word", ["⌥F", "⌥B"], in: .emacs),
        EditorKeyEntry("emacs.lineEnds", "Start or end of the line", ["⌃A", "⌃E"], in: .emacs),
        EditorKeyEntry("emacs.bufferEnds", "Start or end of the buffer", ["⌥<", "⌥>"], in: .emacs),
        EditorKeyEntry("emacs.page", "A page down or up", ["⌃V", "⌥V"], in: .emacs),
        EditorKeyEntry("emacs.killLine", "Cut to the end of the line", ["⌃K"], in: .emacs, detail: "Kill"),
        EditorKeyEntry("emacs.mark", "Start selecting", ["⌃Space"], in: .emacs, detail: "Set the mark, then move"),
        EditorKeyEntry("emacs.cut", "Cut the selection", ["⌃W"], in: .emacs),
        EditorKeyEntry("emacs.copy", "Copy the selection", ["⌥W"], in: .emacs),
        EditorKeyEntry("emacs.paste", "Paste", ["⌃Y"], in: .emacs, detail: "Yank"),
        EditorKeyEntry("emacs.undo", "Undo", ["⌃/", "⌃X U"], in: .emacs),
        EditorKeyEntry("emacs.searchForward", "Search forward", ["⌃S"], in: .emacs, detail: "Again for the next match"),
        EditorKeyEntry("emacs.searchBack", "Search backward", ["⌃R"], in: .emacs),
        EditorKeyEntry("emacs.replace", "Replace, asking each time", ["⌥%"], in: .emacs),
        EditorKeyEntry("emacs.buffer", "Switch buffer", ["⌃X B"], in: .emacs),
        EditorKeyEntry("emacs.killBuffer", "Close the buffer", ["⌃X K"], in: .emacs),
        EditorKeyEntry("emacs.split", "Split the window below or beside", ["⌃X 2", "⌃X 3"], in: .emacs),
        EditorKeyEntry("emacs.otherWindow", "Move to the other window", ["⌃X O"], in: .emacs),
        EditorKeyEntry("emacs.closeWindow", "Close this window, or all the others", ["⌃X 0", "⌃X 1"], in: .emacs),
        EditorKeyEntry("emacs.help", "Help: the tutorial, or what a key does", ["⌃H T", "⌃H K"], in: .emacs),
    ]

    // MARK: micro

    private static let micro: [EditorKeyEntry] = [
        EditorKeyEntry("micro.save", "Save", ["⌃S"], in: .micro),
        EditorKeyEntry("micro.quit", "Quit", ["⌃Q"], in: .micro),
        EditorKeyEntry("micro.open", "Open a file", ["⌃O"], in: .micro),
        EditorKeyEntry("micro.command", "The command bar", ["⌃E"], in: .micro, detail: "Where help, set and the rest are typed"),
        EditorKeyEntry("micro.find", "Find", ["⌃F"], in: .micro),
        EditorKeyEntry("micro.findNext", "Next or previous match", ["⌃N", "⌃P"], in: .micro),
        EditorKeyEntry("micro.undo", "Undo or redo", ["⌃Z", "⌃Y"], in: .micro),
        EditorKeyEntry("micro.clipboard", "Copy, cut, paste", ["⌃C", "⌃X", "⌃V"], in: .micro),
        EditorKeyEntry("micro.selectAll", "Select everything", ["⌃A"], in: .micro),
        EditorKeyEntry("micro.cutLine", "Cut the line", ["⌃K"], in: .micro),
        EditorKeyEntry("micro.duplicate", "Duplicate the line", ["⌃D"], in: .micro),
        EditorKeyEntry("micro.gotoLine", "Go to a line", ["⌃L"], in: .micro),
        EditorKeyEntry("micro.tab", "New tab", ["⌃T"], in: .micro),
        EditorKeyEntry("micro.split", "Move to the next split", ["⌃W"], in: .micro),
        EditorKeyEntry("micro.help", "Help", ["⌃G"], in: .micro),
    ]
}
