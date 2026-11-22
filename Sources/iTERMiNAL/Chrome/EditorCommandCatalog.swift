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
enum EditorSection: CaseIterable, Hashable, Identifiable {
    case vim, nano, emacs, micro

    var id: EditorSection { self }

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

struct EditorCommand: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String?
    /// The ways to do it. Each way is the keys pressed in turn, one string per
    /// key cap: [":wq", "↩"].
    let ways: [[String]]
    let section: EditorSection
    fileprivate let searchWords: [String]

    /// `ways` are written as the keys separated by spaces — ":wq ↩" — and a
    /// cap may be several characters when they are typed rather than pressed
    /// together: ":wq", "dd", "gg".
    init(_ id: String, _ title: String, _ ways: [String], in section: EditorSection, detail: String? = nil) {
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

struct EditorGroup: Identifiable {
    let section: EditorSection
    let commands: [EditorCommand]
    var id: EditorSection { section }
}

enum EditorCommandCatalog {
    static let all: [EditorCommand] = vim + nano + emacs + micro

    /// The editors that have something to show, each with its commands, in order
    /// — all of them for an empty query. Every word of the query has to match,
    /// as in the shortcut list: "vim save" finds Vim's two ways to save, "ctrl"
    /// every command with a Control key.
    static func groups(matching query: String) -> [EditorGroup] {
        let terms = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        return EditorSection.allCases.compactMap { section in
            let commands = all.filter { command in
                command.section == section && terms.allSatisfy { command.matches(term: $0) }
            }
            return commands.isEmpty ? nil : EditorGroup(section: section, commands: commands)
        }
    }

    // MARK: Vim

    private static let vim: [EditorCommand] = [
        EditorCommand("vim.insert", "Insert before the cursor", ["i"], in: .vim),
        EditorCommand("vim.append", "Insert after the cursor", ["a"], in: .vim),
        EditorCommand("vim.insertLineStart", "Insert at the start of the line", ["I"], in: .vim),
        EditorCommand("vim.appendLineEnd", "Insert at the end of the line", ["A"], in: .vim),
        EditorCommand("vim.openBelow", "New line below, and insert", ["o"], in: .vim),
        EditorCommand("vim.openAbove", "New line above, and insert", ["O"], in: .vim),
        EditorCommand("vim.normal", "Back to normal mode", ["esc", "⌃["], in: .vim),
        EditorCommand("vim.visual", "Select by character", ["v"], in: .vim, detail: "Visual mode"),
        EditorCommand("vim.visualLine", "Select by line", ["V"], in: .vim),
        EditorCommand("vim.visualBlock", "Select a block", ["⌃V"], in: .vim),

        EditorCommand("vim.save", "Save", [":w ↩"], in: .vim),
        EditorCommand("vim.saveQuit", "Save and quit", [":wq ↩", "ZZ"], in: .vim),
        EditorCommand("vim.quit", "Quit", [":q ↩"], in: .vim, detail: "Refuses while there are unsaved changes"),
        EditorCommand("vim.quitForce", "Quit without saving", [":q! ↩", "ZQ"], in: .vim),
        EditorCommand("vim.saveAllQuit", "Save every file and quit", [":wqa ↩"], in: .vim),

        EditorCommand("vim.move", "Left, down, up, right", ["h", "j", "k", "l"], in: .vim),
        EditorCommand("vim.wordForward", "Next word", ["w"], in: .vim),
        EditorCommand("vim.wordBack", "Previous word", ["b"], in: .vim),
        EditorCommand("vim.wordEnd", "End of the word", ["e"], in: .vim),
        EditorCommand("vim.lineStart", "Start of the line", ["0"], in: .vim),
        EditorCommand("vim.lineEnd", "End of the line", ["$"], in: .vim),
        EditorCommand("vim.top", "Top of the file", ["gg"], in: .vim),
        EditorCommand("vim.bottom", "Bottom of the file", ["G"], in: .vim),
        EditorCommand("vim.gotoLine", "Go to a line", [":42 ↩", "42G"], in: .vim, detail: "With the line's number"),
        EditorCommand("vim.pageHalf", "Half a page down or up", ["⌃D", "⌃U"], in: .vim),
        EditorCommand("vim.pageFull", "A page down or up", ["⌃F", "⌃B"], in: .vim),
        EditorCommand("vim.bracket", "Jump to the matching bracket", ["%"], in: .vim),

        EditorCommand("vim.deleteChar", "Delete the character", ["x"], in: .vim),
        EditorCommand("vim.deleteLine", "Delete the line", ["dd"], in: .vim, detail: "Into the register, so p puts it back"),
        EditorCommand("vim.deleteToEnd", "Delete to the end of the line", ["D"], in: .vim),
        EditorCommand("vim.deleteWord", "Delete a word", ["dw"], in: .vim),
        EditorCommand("vim.changeWord", "Change a word", ["cw"], in: .vim, detail: "Deletes it and starts inserting"),
        EditorCommand("vim.changeLine", "Change the line", ["cc"], in: .vim),
        EditorCommand("vim.yankLine", "Copy the line", ["yy"], in: .vim, detail: "Yank"),
        EditorCommand("vim.paste", "Paste after or before the cursor", ["p", "P"], in: .vim),
        EditorCommand("vim.undo", "Undo", ["u"], in: .vim),
        EditorCommand("vim.redo", "Redo", ["⌃R"], in: .vim),
        EditorCommand("vim.repeat", "Repeat the last change", ["."], in: .vim),
        EditorCommand("vim.join", "Join the next line on", ["J"], in: .vim),
        EditorCommand("vim.indent", "Indent or outdent the line", [">>", "<<"], in: .vim),

        EditorCommand("vim.search", "Search forward", ["/word ↩"], in: .vim, detail: "? searches backward"),
        EditorCommand("vim.searchNext", "Next or previous match", ["n", "N"], in: .vim),
        EditorCommand("vim.searchWord", "Search for the word under the cursor", ["*"], in: .vim),
        EditorCommand("vim.replace", "Replace in the whole file", [":%s/old/new/g ↩"], in: .vim,
                      detail: "Add c at the end to be asked each time"),
        EditorCommand("vim.noHighlight", "Clear the search highlight", [":noh ↩"], in: .vim),

        EditorCommand("vim.edit", "Open another file", [":e file ↩"], in: .vim),
        EditorCommand("vim.split", "Split the window", [":sp ↩", ":vsp ↩"], in: .vim, detail: "Across, then side by side"),
        EditorCommand("vim.window", "Move to the next window", ["⌃W w"], in: .vim, detail: "Press ⌃W, let go, then w"),
        EditorCommand("vim.buffers", "Next or previous file", [":bn ↩", ":bp ↩"], in: .vim, detail: "Buffers"),
        EditorCommand("vim.numbers", "Show line numbers", [":set number ↩"], in: .vim),
        EditorCommand("vim.help", "Help", [":help ↩"], in: .vim, detail: ":help followed by a topic opens that topic"),
    ]

    // MARK: nano

    private static let nano: [EditorCommand] = [
        EditorCommand("nano.save", "Save (Write Out)", ["⌃O ↩"], in: .nano, detail: "⌃O, then return to confirm the file name"),
        EditorCommand("nano.exit", "Exit", ["⌃X"], in: .nano, detail: "Asks to save if there are changes"),
        EditorCommand("nano.read", "Insert another file", ["⌃R"], in: .nano),
        EditorCommand("nano.cutLine", "Cut the line", ["⌃K"], in: .nano),
        EditorCommand("nano.paste", "Paste", ["⌃U"], in: .nano),
        EditorCommand("nano.search", "Search", ["⌃W"], in: .nano, detail: "⌥W finds the next match"),
        EditorCommand("nano.replace", "Search and replace", ["⌃\\"], in: .nano),
        EditorCommand("nano.gotoLine", "Go to a line", ["⌃_", "⌥G"], in: .nano),
        EditorCommand("nano.undo", "Undo", ["⌥U"], in: .nano),
        EditorCommand("nano.redo", "Redo", ["⌥E"], in: .nano),
        EditorCommand("nano.lineEnds", "Start or end of the line", ["⌃A", "⌃E"], in: .nano),
        EditorCommand("nano.page", "A page up or down", ["⌃Y", "⌃V"], in: .nano),
        EditorCommand("nano.mark", "Start selecting", ["⌥A"], in: .nano, detail: "Move to extend it; ⌃K cuts it"),
        EditorCommand("nano.copy", "Copy the line or selection", ["⌥6"], in: .nano),
        EditorCommand("nano.justify", "Justify the paragraph", ["⌃J"], in: .nano),
        EditorCommand("nano.position", "Show the cursor's position", ["⌃C"], in: .nano),
        EditorCommand("nano.numbers", "Show or hide line numbers", ["⌥N"], in: .nano),
        EditorCommand("nano.refresh", "Redraw the screen", ["⌃L"], in: .nano),
        EditorCommand("nano.help", "Help", ["⌃G"], in: .nano),
    ]

    // MARK: Emacs

    private static let emacs: [EditorCommand] = [
        EditorCommand("emacs.save", "Save", ["⌃X ⌃S"], in: .emacs),
        EditorCommand("emacs.quit", "Quit", ["⌃X ⌃C"], in: .emacs),
        EditorCommand("emacs.open", "Open a file", ["⌃X ⌃F"], in: .emacs),
        EditorCommand("emacs.cancel", "Cancel what is half typed", ["⌃G"], in: .emacs),
        EditorCommand("emacs.command", "Run a command by name", ["⌥X"], in: .emacs),
        EditorCommand("emacs.move", "Forward, back, next line, previous line", ["⌃F", "⌃B", "⌃N", "⌃P"], in: .emacs),
        EditorCommand("emacs.word", "Forward or back a word", ["⌥F", "⌥B"], in: .emacs),
        EditorCommand("emacs.lineEnds", "Start or end of the line", ["⌃A", "⌃E"], in: .emacs),
        EditorCommand("emacs.bufferEnds", "Start or end of the buffer", ["⌥<", "⌥>"], in: .emacs),
        EditorCommand("emacs.page", "A page down or up", ["⌃V", "⌥V"], in: .emacs),
        EditorCommand("emacs.killLine", "Cut to the end of the line", ["⌃K"], in: .emacs, detail: "Kill"),
        EditorCommand("emacs.mark", "Start selecting", ["⌃Space"], in: .emacs, detail: "Set the mark, then move"),
        EditorCommand("emacs.cut", "Cut the selection", ["⌃W"], in: .emacs),
        EditorCommand("emacs.copy", "Copy the selection", ["⌥W"], in: .emacs),
        EditorCommand("emacs.paste", "Paste", ["⌃Y"], in: .emacs, detail: "Yank"),
        EditorCommand("emacs.undo", "Undo", ["⌃/", "⌃X U"], in: .emacs),
        EditorCommand("emacs.searchForward", "Search forward", ["⌃S"], in: .emacs, detail: "Again for the next match"),
        EditorCommand("emacs.searchBack", "Search backward", ["⌃R"], in: .emacs),
        EditorCommand("emacs.replace", "Replace, asking each time", ["⌥%"], in: .emacs),
        EditorCommand("emacs.buffer", "Switch buffer", ["⌃X B"], in: .emacs),
        EditorCommand("emacs.killBuffer", "Close the buffer", ["⌃X K"], in: .emacs),
        EditorCommand("emacs.split", "Split the window below or beside", ["⌃X 2", "⌃X 3"], in: .emacs),
        EditorCommand("emacs.otherWindow", "Move to the other window", ["⌃X O"], in: .emacs),
        EditorCommand("emacs.closeWindow", "Close this window, or all the others", ["⌃X 0", "⌃X 1"], in: .emacs),
        EditorCommand("emacs.help", "Help: the tutorial, or what a key does", ["⌃H T", "⌃H K"], in: .emacs),
    ]

    // MARK: micro

    private static let micro: [EditorCommand] = [
        EditorCommand("micro.save", "Save", ["⌃S"], in: .micro),
        EditorCommand("micro.quit", "Quit", ["⌃Q"], in: .micro),
        EditorCommand("micro.open", "Open a file", ["⌃O"], in: .micro),
        EditorCommand("micro.command", "The command bar", ["⌃E"], in: .micro, detail: "Where help, set and the rest are typed"),
        EditorCommand("micro.find", "Find", ["⌃F"], in: .micro),
        EditorCommand("micro.findNext", "Next or previous match", ["⌃N", "⌃P"], in: .micro),
        EditorCommand("micro.undo", "Undo or redo", ["⌃Z", "⌃Y"], in: .micro),
        EditorCommand("micro.clipboard", "Copy, cut, paste", ["⌃C", "⌃X", "⌃V"], in: .micro),
        EditorCommand("micro.selectAll", "Select everything", ["⌃A"], in: .micro),
        EditorCommand("micro.cutLine", "Cut the line", ["⌃K"], in: .micro),
        EditorCommand("micro.duplicate", "Duplicate the line", ["⌃D"], in: .micro),
        EditorCommand("micro.gotoLine", "Go to a line", ["⌃L"], in: .micro),
        EditorCommand("micro.tab", "New tab", ["⌃T"], in: .micro),
        EditorCommand("micro.split", "Move to the next split", ["⌃W"], in: .micro),
        EditorCommand("micro.help", "Help", ["⌃G"], in: .micro),
    ]
}
