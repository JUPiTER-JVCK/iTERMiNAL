import Foundation

// What to press in the programs people run in a terminal: the editors (Vim,
// nano, Emacs, micro), the pager and man, tmux and screen, top and htop, ssh's
// escape keys, and the shell's own line editing — and btop and superfile, the
// tools the app bundles, whose keys are taken from `ShortcutCatalog`.
//
// Apart from `ShortcutCatalog` on purpose. That list is the app's own keys, held
// to the menus by a test; these are read by a program in the terminal, which the
// app never sees, and most are sequences — `dd`, `:wq`, ⌃X ⌃S — where a shortcut
// is one key with its modifiers. Mixing them in would have the test reading
// `dd` as the same chord twice.
//
// Listed by hand, from each program's own documentation, for its default keys.
// A config file that rebinds them is not reflected.
//
// Read in two places: the Keyboard Shortcuts window lists every section, and
// the quick reference strip above the status bar shows the one for the program
// in front of the focused terminal — its `strip` entries in the strip, the rest
// behind the program's name at the end of it.
//
// Foundation only, so it can be compiled without Xcode.

/// A program, as the Keyboard Shortcuts window groups them and the quick
/// reference strip finds them.
enum ProgramKeySection: CaseIterable, Hashable, Identifiable {
    case vim, helix, nano, emacs, micro, pager, man, tmux, screen, top, htop, btop, superfile
    case python, node, irb, psql, mysql, sqlite, fzf, lazygit, gitPatch
    case ssh, shell

    var id: ProgramKeySection { self }

    var title: String {
        switch self {
        case .vim: return "Editor: Vim and Neovim"
        case .helix: return "Editor: Helix"
        case .nano: return "Editor: nano"
        case .emacs: return "Editor: Emacs (in the terminal)"
        case .micro: return "Editor: micro"
        case .pager: return "Pager: less and more"
        case .man: return "Manual pages: man"
        case .tmux: return "Multiplexer: tmux"
        case .screen: return "Multiplexer: GNU screen"
        case .top: return "Monitor: top"
        case .htop: return "Monitor: htop"
        case .btop: return "Monitor: btop"
        case .superfile: return "File manager: superfile"
        case .python: return "Python prompt"
        case .node: return "Node.js prompt"
        case .irb: return "Ruby prompt: irb"
        case .psql: return "Database: psql (PostgreSQL)"
        case .mysql: return "Database: mysql and mariadb"
        case .sqlite: return "Database: sqlite3"
        case .fzf: return "Finder: fzf"
        case .lazygit: return "Git: lazygit"
        case .gitPatch: return "Git: choosing hunks (git add -p)"
        case .ssh: return "ssh: escape keys"
        case .shell: return "Shell: the command line"
        }
    }

    /// What the keys below assume, shown under the heading.
    var note: String {
        switch self {
        case .vim:
            return "Normal mode unless it says otherwise; esc gets back to it. Typed one after another, not held together. vi and Neovim take the same ones."
        case .helix:
            return "Normal mode unless it says otherwise; esc gets back to it. Helix selects first, then acts: x selects the line, d deletes what is selected. space opens a menu of its own — press it, then the key."
        case .nano:
            return "⌃ is Control. ⌥ keys are nano's Meta (M-) keys: they need Option sent as Meta in the terminal."
        case .emacs:
            return "⌃ is Control, ⌥ is Meta (M-), which needs Option sent as Meta in the terminal — or press esc, then the key. Keys in a row are pressed one after another."
        case .micro:
            return "micro's default keys, which are the ones most programs use. Typed in the terminal."
        case .pager:
            return "What git, man and many others show long output in. q leaves it."
        case .man:
            return "A page is read in the pager, so the pager's keys work in it. The sections and searches are typed at the prompt, with man."
        case .tmux:
            return "⌃B is tmux's own prefix: press it, let go, then the key. When tmux runs on this Mac, the strip asks it which prefix is set and shows that one."
        case .screen:
            return "⌃A is screen's own prefix: press it, let go, then the key. An escape line in ~/.screenrc changes it, and the strip shows that one."
        case .top:
            return "macOS's top and Linux's top share only a few keys. The ones that work in just one say which."
        case .htop:
            return "Most also have a function key — F10 quits — which needs fn on most Mac keyboards."
        case .btop, .superfile:
            return "The keys of the version iTERMiNAL bundles, as Keyboard Shortcuts lists them."
        case .python:
            return "Python's >>> prompt: typed there, and return runs it. The same in python3 and ipython."
        case .node:
            return "Node's > prompt. The commands with a dot are the prompt's own; anything else is JavaScript."
        case .irb:
            return "Ruby's interactive prompt."
        case .psql:
            return "PostgreSQL's prompt. A backslash command runs with return; SQL runs once it ends with ;."
        case .mysql:
            return "MySQL's and MariaDB's prompt. SQL runs once it ends with ;."
        case .sqlite:
            return "SQLite's prompt. A dot command runs with return; SQL runs once it ends with ;."
        case .fzf:
            return "Type to narrow the list. fzf's default keys; FZF_DEFAULT_OPTS can change them."
        case .lazygit:
            return "lazygit's default keys. Most act on the panel in front, and ? lists that panel's."
        case .gitPatch:
            return "git asks about each hunk of changes in turn. Type the letter, then return — unless interactive.singleKey is set, when the letter is enough."
        case .ssh:
            return "ssh reads these only at the start of a line, so press return first. They are typed by hand: a click would send the return, and whatever is half typed with it."
        case .shell:
            return "zsh and bash, with their standard keys (emacs mode). In vi mode, or with keys rebound, they differ."
        }
    }

    /// What the strip calls it when the program's own name is not known.
    var badge: String {
        switch self {
        case .vim: return "vim"
        case .helix: return "hx"
        case .nano: return "nano"
        case .emacs: return "emacs"
        case .micro: return "micro"
        case .pager: return "less"
        case .man: return "man"
        case .tmux: return "tmux"
        case .screen: return "screen"
        case .top: return "top"
        case .htop: return "htop"
        case .btop: return "btop"
        case .superfile: return "superfile"
        case .python: return "python"
        case .node: return "node"
        case .irb: return "irb"
        case .psql: return "psql"
        case .mysql: return "mysql"
        case .sqlite: return "sqlite3"
        case .fzf: return "fzf"
        case .lazygit: return "lazygit"
        case .gitPatch: return "git add -p"
        case .ssh: return "ssh"
        case .shell: return "shell"
        }
    }

    /// The executables that are this program, as the kernel names a running
    /// process: lowercased, with no path. What finds the section for the
    /// program in front of a terminal. A version on the end is looked past
    /// (`section(forProgram:)`): python3.12 is python. Choosing hunks has
    /// none: it is `git` reading the terminal, told apart by its command line.
    var executables: [String] {
        switch self {
        case .vim: return ["vim", "vi", "nvim", "view", "vimdiff", "rvim", "rview"]
        case .helix: return ["hx", "helix"]
        case .nano: return ["nano", "rnano", "pico"]
        case .emacs: return ["emacs", "emacsclient", "emacs-nox"]
        case .micro: return ["micro"]
        case .pager: return ["less", "more"]
        case .man: return ["man"]
        case .tmux: return ["tmux"]
        case .screen: return ["screen"]
        case .top: return ["top"]
        case .htop: return ["htop"]
        case .btop: return ["btop"]
        // spf is what the binary is called; superfile is the name of a panel's
        // session.
        case .superfile: return ["spf", "superfile"]
        case .python: return ["python", "python3", "ipython", "ipython3", "bpython"]
        case .node: return ["node", "nodejs"]
        case .irb: return ["irb"]
        case .psql: return ["psql"]
        case .mysql: return ["mysql", "mariadb"]
        case .sqlite: return ["sqlite3"]
        case .fzf: return ["fzf"]
        case .lazygit: return ["lazygit"]
        case .gitPatch: return []
        case .ssh: return ["ssh"]
        case .shell: return ["zsh", "bash", "sh", "dash", "ksh"]
        }
    }

    /// Other names to find it by.
    fileprivate var names: [String] {
        switch self {
        case .vim: return executables + ["neovim"]
        case .helix: return executables
        case .pager: return executables + ["pager"]
        case .man: return executables + ["manual", "apropos", "whatis"]
        case .python: return executables + ["repl"]
        case .node: return executables + ["javascript", "repl"]
        case .irb: return executables + ["ruby", "repl"]
        case .psql: return executables + ["postgres", "postgresql", "sql"]
        case .mysql: return executables + ["sql"]
        case .sqlite: return executables + ["sqlite", "sql"]
        case .gitPatch: return ["git", "patch", "hunk", "stage"]
        case .ssh: return executables + ["escape", "disconnect"]
        case .shell: return executables + ["readline", "prompt"]
        default: return executables
        }
    }

    /// Key caps a click types ahead of the entry's own keys.
    ///
    /// Vim's and Helix's commands are normal mode's, and a click in insert
    /// mode would otherwise type `:w` into the file. esc in normal mode does
    /// nothing.
    var clickLead: [String] {
        self == .vim || self == .helix ? ["esc"] : []
    }

    /// Whether a letter on its own cap means the lowercase key. Emacs writes
    /// ⌃X U for the u key, the way a menu prints it; Vim, screen and the rest
    /// mean the case they show.
    var capsAreLowercase: Bool {
        self == .emacs
    }

    /// btop and superfile, whose keys come from `ShortcutCatalog`: the
    /// Keyboard Shortcuts window already lists them, under Inside btop and
    /// Inside superfile, so it leaves these sections out.
    var isBundledTool: Bool {
        self == .btop || self == .superfile
    }

    /// Python and Node: one program runs a prompt and runs programs, and only
    /// its arguments say which (`ActiveProgram.isInteractiveInterpreter`).
    var isInterpreter: Bool {
        self == .python || self == .node
    }

    /// Whether the arguments of a leader of this kind are read when it is in
    /// front: a shell's, to tell a script from a prompt, and an interpreter's,
    /// a prompt from a program.
    var readsArguments: Bool {
        self == .shell || isInterpreter
    }

    /// The prefix key a multiplexer's keys start with when nothing changes it:
    /// tmux's ⌃B, screen's ⌃A. The one set can be swapped in
    /// (`ProgramKeyCatalog.entries(in:prefix:)`).
    var defaultPrefix: String? {
        switch self {
        case .tmux: return "⌃B"
        case .screen: return "⌃A"
        default: return nil
        }
    }
}

struct ProgramKeyEntry: Identifiable, Hashable {
    /// What a click on the entry types.
    enum Click: Hashable {
        /// Each way types its own keys.
        case keys
        /// Every way types these key caps instead: the part before what only
        /// the person can fill in — "/" for a search, ":e space" for a file.
        case prefix(String)
        /// Nothing is typed: a reference, or keys that only work by hand.
        case none
    }

    let id: String
    let title: String
    let detail: String?
    /// The ways to do it. Each way is the keys pressed in turn, one string per
    /// key cap: [":wq", "↩"].
    let ways: [[String]]
    let section: ProgramKeySection
    /// What the strip calls it, beside its keys: nano's own "Write Out".
    let short: String
    /// Its place in the strip, lowest first. Nil keeps it to the full list.
    let strip: Int?
    let click: Click
    fileprivate let searchWords: [String]

    /// `ways` are written as the keys separated by spaces — ":wq ↩" — and a
    /// cap may be several characters when they are typed rather than pressed
    /// together: ":wq", "dd", "gg".
    init(
        _ id: String,
        _ title: String,
        _ ways: [String],
        in section: ProgramKeySection,
        detail: String? = nil,
        short: String? = nil,
        strip: Int? = nil,
        click: Click = .keys
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.ways = ways.map { $0.split(separator: " ").map(String.init) }
        self.section = section
        self.short = short ?? title
        self.strip = strip
        self.click = click

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

    /// What clicking the way at `index` types into the program, or nil when a
    /// click there types nothing. A return at the end is left off, so the
    /// person sees what was typed and presses return to go ahead.
    func typed(way index: Int) -> String? {
        let caps: [String]
        switch click {
        case .none:
            return nil
        case .prefix(let prefix):
            // One button types it, not one per way: Vim's ":42" and "42G" both
            // need the number, and two buttons typing the same ":" read as two
            // different things.
            guard index == 0 else { return nil }
            caps = prefix.split(separator: " ").map(String.init)
        case .keys:
            guard ways.indices.contains(index) else { return nil }
            caps = ways[index]
        }
        let lowercase = section.capsAreLowercase
        guard let body = ProgramKeySend.text(for: caps, lowercaseLetters: lowercase) else { return nil }
        if section.clickLead.isEmpty { return body }
        guard let lead = ProgramKeySend.text(for: section.clickLead, lowercaseLetters: lowercase) else { return body }
        return lead + body
    }

    /// The way the strip shows: the first a click can type — btop's help is
    /// F1, ? or h, and F1 is not sent — or the first, when none can.
    var stripWay: Int {
        ways.indices.first { typed(way: $0) != nil } ?? 0
    }

    /// Whether a click on the way the strip shows types anything.
    var isClickable: Bool { typed(way: stripWay) != nil }

    /// Whether `term` starts one of the words it is found by, for the full
    /// list's search.
    func isFound(by term: String) -> Bool { matches(term: term) }

    /// The same entry with one cap swapped for another wherever it is — in its
    /// keys, in what a click types and in the words around them. For a
    /// multiplexer whose prefix has been changed: tmux's ⌃B for the ⌃A set.
    func replacingCap(_ old: String, with new: String) -> ProgramKeyEntry {
        guard old != new else { return self }
        func swap(_ caps: [String]) -> String {
            caps.map { $0 == old ? new : $0 }.joined(separator: " ")
        }
        let click: Click
        switch self.click {
        case .prefix(let prefix):
            click = .prefix(swap(prefix.split(separator: " ").map(String.init)))
        default:
            click = self.click
        }
        return ProgramKeyEntry(
            id, title.replacingOccurrences(of: old, with: new), ways.map(swap), in: section,
            detail: detail?.replacingOccurrences(of: old, with: new),
            short: short.replacingOccurrences(of: old, with: new), strip: strip, click: click
        )
    }
}

struct ProgramKeyGroup: Identifiable {
    let section: ProgramKeySection
    let commands: [ProgramKeyEntry]
    var id: ProgramKeySection { section }
}

enum ProgramKeyCatalog {
    static let all: [ProgramKeyEntry] = vim + helix + nano + emacs + micro + pager + man + tmux + screen
        + top + htop + btop + superfile + python + node + irb + psql + mysql + sqlite + fzf + lazygit
        + gitPatch + ssh + shell

    private static let bySection: [ProgramKeySection: [ProgramKeyEntry]] = Dictionary(grouping: all, by: \.section)

    /// The sections that have something to show, each with its commands, in
    /// order — all of them for an empty query. Every word of the query has to
    /// match, as in the shortcut list: "vim save" finds Vim's two ways to save,
    /// "ctrl" every command with a Control key.
    static func groups(matching query: String) -> [ProgramKeyGroup] {
        let terms = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        return ProgramKeySection.allCases.filter { !$0.isBundledTool }.compactMap { section in
            let commands = entries(in: section).filter { command in
                terms.allSatisfy { command.matches(term: $0) }
            }
            return commands.isEmpty ? nil : ProgramKeyGroup(section: section, commands: commands)
        }
    }

    static func entries(in section: ProgramKeySection) -> [ProgramKeyEntry] {
        bySection[section] ?? []
    }

    /// What the strip shows for `section`, in its order.
    static func strip(for section: ProgramKeySection) -> [ProgramKeyEntry] {
        strip(of: entries(in: section))
    }

    /// `section`'s keys, with `prefix` — the prefix key the person set — in
    /// place of the program's own (`defaultPrefix`): tmux's ⌃B becomes the ⌃A
    /// a ~/.tmux.conf asked for. Nil, or the program's own, changes nothing.
    static func entries(in section: ProgramKeySection, prefix: String?) -> [ProgramKeyEntry] {
        let listed = entries(in: section)
        guard let prefix, let standard = section.defaultPrefix, prefix != standard else { return listed }
        return listed.map { $0.replacingCap(standard, with: prefix) }
    }

    /// What the strip shows for `section` with `prefix` swapped in.
    static func strip(for section: ProgramKeySection, prefix: String?) -> [ProgramKeyEntry] {
        strip(of: entries(in: section, prefix: prefix))
    }

    private static func strip(of entries: [ProgramKeyEntry]) -> [ProgramKeyEntry] {
        entries
            .filter { $0.strip != nil }
            .sorted { ($0.strip ?? 0) < ($1.strip ?? 0) }
    }

    /// The entries every word of `query` finds, as the Keyboard Shortcuts
    /// window searches: for the full list's own search box.
    static func filter(_ entries: [ProgramKeyEntry], matching query: String) -> [ProgramKeyEntry] {
        let terms = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !terms.isEmpty else { return entries }
        return entries.filter { entry in terms.allSatisfy { entry.isFound(by: $0) } }
    }

    static func entry(id: String) -> ProgramKeyEntry? {
        all.first { $0.id == id }
    }

    /// A process or command name as the sections list it: no path, no leading
    /// dash (a login shell is "-zsh"), lowercased, and without a version after
    /// a dash ("emacs-29.4").
    static func normalizedProgramName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])
        }
        if name.hasPrefix("-") { name.removeFirst() }
        name = name.lowercased()
        if let dash = name.lastIndex(of: "-"), dash != name.startIndex {
            let tail = name[name.index(after: dash)...]
            if !tail.isEmpty, tail.allSatisfy({ $0.isNumber || $0 == "." }) {
                name = String(name[..<dash])
            }
        }
        return name
    }

    /// The section for a running program or a command's first word, if any.
    ///
    /// A version run into the name is looked past when the name itself is not
    /// listed: python3.12 is python, node20 is node. Only for finding the
    /// section — the name shown stays as the kernel gave it.
    static func section(forProgram raw: String) -> ProgramKeySection? {
        let name = normalizedProgramName(raw)
        guard !name.isEmpty else { return nil }
        if let found = ProgramKeySection.allCases.first(where: { $0.executables.contains(name) }) {
            return found
        }
        var base = Substring(name)
        while let last = base.last, last.isNumber || last == "." { base = base.dropLast() }
        guard base.count < name.count, base.count > 1, base.last?.isLetter == true else { return nil }
        return ProgramKeySection.allCases.first { $0.executables.contains(String(base)) }
    }

    // MARK: Vim

    private static let vim: [ProgramKeyEntry] = [
        ProgramKeyEntry("vim.insert", "Insert before the cursor", ["i"], in: .vim, short: "Insert", strip: 5),
        ProgramKeyEntry("vim.append", "Insert after the cursor", ["a"], in: .vim),
        ProgramKeyEntry("vim.insertLineStart", "Insert at the start of the line", ["I"], in: .vim),
        ProgramKeyEntry("vim.appendLineEnd", "Insert at the end of the line", ["A"], in: .vim),
        ProgramKeyEntry("vim.openBelow", "New line below, and insert", ["o"], in: .vim),
        ProgramKeyEntry("vim.openAbove", "New line above, and insert", ["O"], in: .vim),
        ProgramKeyEntry("vim.normal", "Back to normal mode", ["esc", "⌃["], in: .vim, short: "Normal mode", strip: 6),
        ProgramKeyEntry("vim.visual", "Select by character", ["v"], in: .vim, detail: "Visual mode"),
        ProgramKeyEntry("vim.visualLine", "Select by line", ["V"], in: .vim),
        ProgramKeyEntry("vim.visualBlock", "Select a block", ["⌃V"], in: .vim),

        ProgramKeyEntry("vim.save", "Save", [":w ↩"], in: .vim, strip: 1),
        ProgramKeyEntry("vim.saveQuit", "Save and quit", [":wq ↩", "ZZ"], in: .vim, strip: 3),
        ProgramKeyEntry("vim.quit", "Quit", [":q ↩"], in: .vim, detail: "Refuses while there are unsaved changes", strip: 2),
        ProgramKeyEntry("vim.quitForce", "Quit without saving", [":q! ↩", "ZQ"], in: .vim, short: "Quit, don't save", strip: 4),
        ProgramKeyEntry("vim.saveAllQuit", "Save every file and quit", [":wqa ↩"], in: .vim),

        ProgramKeyEntry("vim.move", "Left, down, up, right", ["h", "j", "k", "l"], in: .vim),
        ProgramKeyEntry("vim.wordForward", "Next word", ["w"], in: .vim),
        ProgramKeyEntry("vim.wordBack", "Previous word", ["b"], in: .vim),
        ProgramKeyEntry("vim.wordEnd", "End of the word", ["e"], in: .vim),
        ProgramKeyEntry("vim.lineStart", "Start of the line", ["0"], in: .vim),
        ProgramKeyEntry("vim.lineEnd", "End of the line", ["$"], in: .vim),
        ProgramKeyEntry("vim.top", "Top of the file", ["gg"], in: .vim),
        ProgramKeyEntry("vim.bottom", "Bottom of the file", ["G"], in: .vim),
        ProgramKeyEntry("vim.gotoLine", "Go to a line", [":42 ↩", "42G"], in: .vim, detail: "With the line's number",
                        click: .prefix(":")),
        ProgramKeyEntry("vim.pageHalf", "Half a page down or up", ["⌃D", "⌃U"], in: .vim),
        ProgramKeyEntry("vim.pageFull", "A page down or up", ["⌃F", "⌃B"], in: .vim),
        ProgramKeyEntry("vim.bracket", "Jump to the matching bracket", ["%"], in: .vim),

        ProgramKeyEntry("vim.deleteChar", "Delete the character", ["x"], in: .vim),
        ProgramKeyEntry("vim.deleteLine", "Delete the line", ["dd"], in: .vim, detail: "Into the register, so p puts it back"),
        ProgramKeyEntry("vim.deleteToEnd", "Delete to the end of the line", ["D"], in: .vim),
        ProgramKeyEntry("vim.deleteWord", "Delete a word", ["dw"], in: .vim),
        ProgramKeyEntry("vim.changeWord", "Change a word", ["cw"], in: .vim, detail: "Deletes it and starts inserting"),
        ProgramKeyEntry("vim.changeLine", "Change the line", ["cc"], in: .vim),
        ProgramKeyEntry("vim.yankLine", "Copy the line", ["yy"], in: .vim, detail: "Yank"),
        ProgramKeyEntry("vim.paste", "Paste after or before the cursor", ["p", "P"], in: .vim),
        ProgramKeyEntry("vim.undo", "Undo", ["u"], in: .vim, strip: 7),
        ProgramKeyEntry("vim.redo", "Redo", ["⌃R"], in: .vim),
        ProgramKeyEntry("vim.repeat", "Repeat the last change", ["."], in: .vim),
        ProgramKeyEntry("vim.join", "Join the next line on", ["J"], in: .vim),
        ProgramKeyEntry("vim.indent", "Indent or outdent the line", [">>", "<<"], in: .vim),

        ProgramKeyEntry("vim.search", "Search forward", ["/word ↩"], in: .vim, detail: "? searches backward",
                        short: "Find", strip: 8, click: .prefix("/")),
        ProgramKeyEntry("vim.searchNext", "Next or previous match", ["n", "N"], in: .vim),
        ProgramKeyEntry("vim.searchWord", "Search for the word under the cursor", ["*"], in: .vim),
        ProgramKeyEntry("vim.replace", "Replace in the whole file", [":%s/old/new/g ↩"], in: .vim,
                        detail: "Add c at the end to be asked each time", click: .prefix(":%s/")),
        ProgramKeyEntry("vim.noHighlight", "Clear the search highlight", [":noh ↩"], in: .vim),

        ProgramKeyEntry("vim.edit", "Open another file", [":e file ↩"], in: .vim, click: .prefix(":e space")),
        ProgramKeyEntry("vim.split", "Split the window", [":sp ↩", ":vsp ↩"], in: .vim, detail: "Across, then side by side"),
        ProgramKeyEntry("vim.window", "Move to the next window", ["⌃W w"], in: .vim, detail: "Press ⌃W, let go, then w"),
        ProgramKeyEntry("vim.buffers", "Next or previous file", [":bn ↩", ":bp ↩"], in: .vim, detail: "Buffers"),
        ProgramKeyEntry("vim.numbers", "Show line numbers", [":set number ↩"], in: .vim, click: .prefix(":set space number")),
        ProgramKeyEntry("vim.help", "Help", [":help ↩"], in: .vim, detail: ":help followed by a topic opens that topic", strip: 9),
    ]

    // MARK: Helix

    // Helix's default keymap. It selects, then acts on the selection, so many
    // keys read differently from Vim's: x selects a line, d deletes what is
    // selected. `space` starts a menu of its own.
    private static let helix: [ProgramKeyEntry] = [
        ProgramKeyEntry("helix.save", "Save", [":w ↩"], in: .helix, strip: 1),
        ProgramKeyEntry("helix.quit", "Quit", [":q ↩"], in: .helix, detail: "Refuses while there are unsaved changes", strip: 2),
        ProgramKeyEntry("helix.saveQuit", "Save and quit", [":wq ↩", ":x ↩"], in: .helix, strip: 3),
        ProgramKeyEntry("helix.quitForce", "Quit without saving", [":q! ↩"], in: .helix, short: "Quit, don't save", strip: 4),
        ProgramKeyEntry("helix.insert", "Insert before the selection", ["i"], in: .helix, short: "Insert", strip: 5),
        ProgramKeyEntry("helix.append", "Insert after the selection", ["a"], in: .helix),
        ProgramKeyEntry("helix.open", "New line below or above, and insert", ["o", "O"], in: .helix),
        ProgramKeyEntry("helix.normal", "Back to normal mode", ["esc"], in: .helix, short: "Normal mode", strip: 6),
        ProgramKeyEntry("helix.select", "Select mode, where moving extends the selection", ["v"], in: .helix),
        ProgramKeyEntry("helix.line", "Select the line", ["x"], in: .helix, detail: "Again for the line after"),
        ProgramKeyEntry("helix.all", "Select the whole file", ["%"], in: .helix),
        ProgramKeyEntry("helix.collapse", "Collapse the selection to the cursor", [";"], in: .helix),
        ProgramKeyEntry("helix.delete", "Delete what is selected", ["d"], in: .helix),
        ProgramKeyEntry("helix.change", "Change what is selected", ["c"], in: .helix, detail: "Deletes it and starts inserting"),
        ProgramKeyEntry("helix.yank", "Copy what is selected", ["y"], in: .helix, detail: "Yank"),
        ProgramKeyEntry("helix.paste", "Paste after or before the selection", ["p", "P"], in: .helix),
        ProgramKeyEntry("helix.undo", "Undo", ["u"], in: .helix, detail: "U redoes", strip: 7),
        ProgramKeyEntry("helix.redo", "Redo", ["U"], in: .helix),
        ProgramKeyEntry("helix.words", "Next word, previous word, end of the word", ["w", "b", "e"], in: .helix),
        ProgramKeyEntry("helix.ends", "Start or end of the file", ["gg", "ge"], in: .helix),
        ProgramKeyEntry("helix.search", "Search forward", ["/word ↩"], in: .helix, detail: "? searches backward",
                        short: "Find", strip: 8, click: .prefix("/")),
        ProgramKeyEntry("helix.searchNext", "Next or previous match", ["n", "N"], in: .helix),
        ProgramKeyEntry("helix.palette", "Every command, to search", ["space ?"], in: .helix, short: "Commands", strip: 9),
        ProgramKeyEntry("helix.files", "Open a file", ["space f"], in: .helix, short: "Files", strip: 10),
        ProgramKeyEntry("helix.buffers", "Switch between open files", ["space b"], in: .helix),
        ProgramKeyEntry("helix.globalSearch", "Search every file in the folder", ["space /"], in: .helix),
        ProgramKeyEntry("helix.comment", "Comment or uncomment the lines", ["⌃C"], in: .helix),
        ProgramKeyEntry("helix.indent", "Indent or outdent", [">", "<"], in: .helix),
        ProgramKeyEntry("helix.join", "Join the lines", ["J"], in: .helix),
        ProgramKeyEntry("helix.case", "Switch upper and lower case", ["~"], in: .helix),
        ProgramKeyEntry("helix.tutor", "The tutorial", [":tutor ↩"], in: .helix),
    ]

    // MARK: nano

    // The strip uses nano's own names for these, from the two lines it shows
    // along its bottom.
    private static let nano: [ProgramKeyEntry] = [
        ProgramKeyEntry("nano.save", "Save (Write Out)", ["⌃O ↩"], in: .nano, detail: "⌃O, then return to confirm the file name",
                        short: "Write Out", strip: 1),
        ProgramKeyEntry("nano.exit", "Exit", ["⌃X"], in: .nano, detail: "Asks to save if there are changes", strip: 2),
        ProgramKeyEntry("nano.read", "Insert another file", ["⌃R"], in: .nano),
        ProgramKeyEntry("nano.cutLine", "Cut the line", ["⌃K"], in: .nano, short: "Cut", strip: 4),
        ProgramKeyEntry("nano.paste", "Paste", ["⌃U"], in: .nano, strip: 5),
        ProgramKeyEntry("nano.search", "Search", ["⌃W"], in: .nano, detail: "⌥W finds the next match", short: "Where Is", strip: 3),
        ProgramKeyEntry("nano.replace", "Search and replace", ["⌃\\"], in: .nano, short: "Replace", strip: 6),
        ProgramKeyEntry("nano.gotoLine", "Go to a line", ["⌃_", "⌥G"], in: .nano, short: "Go To Line", strip: 8),
        ProgramKeyEntry("nano.undo", "Undo", ["⌥U"], in: .nano, strip: 7),
        ProgramKeyEntry("nano.redo", "Redo", ["⌥E"], in: .nano),
        ProgramKeyEntry("nano.lineEnds", "Start or end of the line", ["⌃A", "⌃E"], in: .nano),
        ProgramKeyEntry("nano.page", "A page up or down", ["⌃Y", "⌃V"], in: .nano),
        ProgramKeyEntry("nano.mark", "Start selecting", ["⌥A"], in: .nano, detail: "Move to extend it; ⌃K cuts it"),
        ProgramKeyEntry("nano.copy", "Copy the line or selection", ["⌥6"], in: .nano),
        ProgramKeyEntry("nano.justify", "Justify the paragraph", ["⌃J"], in: .nano),
        ProgramKeyEntry("nano.position", "Show the cursor's position", ["⌃C"], in: .nano),
        ProgramKeyEntry("nano.numbers", "Show or hide line numbers", ["⌥N"], in: .nano),
        ProgramKeyEntry("nano.refresh", "Redraw the screen", ["⌃L"], in: .nano),
        ProgramKeyEntry("nano.help", "Help", ["⌃G"], in: .nano, strip: 9),
    ]

    // MARK: Emacs

    private static let emacs: [ProgramKeyEntry] = [
        ProgramKeyEntry("emacs.save", "Save", ["⌃X ⌃S"], in: .emacs, strip: 1),
        ProgramKeyEntry("emacs.quit", "Quit", ["⌃X ⌃C"], in: .emacs, strip: 2),
        ProgramKeyEntry("emacs.open", "Open a file", ["⌃X ⌃F"], in: .emacs, short: "Open", strip: 3),
        ProgramKeyEntry("emacs.cancel", "Cancel what is half typed", ["⌃G"], in: .emacs, short: "Cancel", strip: 4),
        ProgramKeyEntry("emacs.command", "Run a command by name", ["⌥X"], in: .emacs, short: "Command", strip: 9),
        ProgramKeyEntry("emacs.move", "Forward, back, next line, previous line", ["⌃F", "⌃B", "⌃N", "⌃P"], in: .emacs),
        ProgramKeyEntry("emacs.word", "Forward or back a word", ["⌥F", "⌥B"], in: .emacs),
        ProgramKeyEntry("emacs.lineEnds", "Start or end of the line", ["⌃A", "⌃E"], in: .emacs),
        ProgramKeyEntry("emacs.bufferEnds", "Start or end of the buffer", ["⌥<", "⌥>"], in: .emacs),
        ProgramKeyEntry("emacs.page", "A page down or up", ["⌃V", "⌥V"], in: .emacs),
        ProgramKeyEntry("emacs.killLine", "Cut to the end of the line", ["⌃K"], in: .emacs, detail: "Kill", short: "Cut line", strip: 7),
        ProgramKeyEntry("emacs.mark", "Start selecting", ["⌃Space"], in: .emacs, detail: "Set the mark, then move"),
        ProgramKeyEntry("emacs.cut", "Cut the selection", ["⌃W"], in: .emacs),
        ProgramKeyEntry("emacs.copy", "Copy the selection", ["⌥W"], in: .emacs),
        ProgramKeyEntry("emacs.paste", "Paste", ["⌃Y"], in: .emacs, detail: "Yank", strip: 8),
        ProgramKeyEntry("emacs.undo", "Undo", ["⌃/", "⌃X U"], in: .emacs, strip: 6),
        ProgramKeyEntry("emacs.searchForward", "Search forward", ["⌃S"], in: .emacs, detail: "Again for the next match",
                        short: "Search", strip: 5),
        ProgramKeyEntry("emacs.searchBack", "Search backward", ["⌃R"], in: .emacs),
        ProgramKeyEntry("emacs.replace", "Replace, asking each time", ["⌥%"], in: .emacs),
        ProgramKeyEntry("emacs.buffer", "Switch buffer", ["⌃X B"], in: .emacs),
        ProgramKeyEntry("emacs.killBuffer", "Close the buffer", ["⌃X K"], in: .emacs),
        ProgramKeyEntry("emacs.split", "Split the window below or beside", ["⌃X 2", "⌃X 3"], in: .emacs),
        ProgramKeyEntry("emacs.otherWindow", "Move to the other window", ["⌃X O"], in: .emacs),
        ProgramKeyEntry("emacs.closeWindow", "Close this window, or all the others", ["⌃X 0", "⌃X 1"], in: .emacs),
        ProgramKeyEntry("emacs.help", "Help: the tutorial, or what a key does", ["⌃H T", "⌃H K"], in: .emacs),
    ]

    // MARK: micro

    private static let micro: [ProgramKeyEntry] = [
        ProgramKeyEntry("micro.save", "Save", ["⌃S"], in: .micro, strip: 1),
        ProgramKeyEntry("micro.quit", "Quit", ["⌃Q"], in: .micro, strip: 2),
        ProgramKeyEntry("micro.open", "Open a file", ["⌃O"], in: .micro, short: "Open", strip: 8),
        ProgramKeyEntry("micro.command", "The command bar", ["⌃E"], in: .micro, detail: "Where help, set and the rest are typed",
                        short: "Command", strip: 6),
        ProgramKeyEntry("micro.find", "Find", ["⌃F"], in: .micro, strip: 3),
        ProgramKeyEntry("micro.findNext", "Next or previous match", ["⌃N", "⌃P"], in: .micro),
        ProgramKeyEntry("micro.undo", "Undo or redo", ["⌃Z", "⌃Y"], in: .micro, short: "Undo", strip: 4),
        ProgramKeyEntry("micro.clipboard", "Copy, cut, paste", ["⌃C", "⌃X", "⌃V"], in: .micro, short: "Copy", strip: 5),
        ProgramKeyEntry("micro.selectAll", "Select everything", ["⌃A"], in: .micro),
        ProgramKeyEntry("micro.cutLine", "Cut the line", ["⌃K"], in: .micro),
        ProgramKeyEntry("micro.duplicate", "Duplicate the line", ["⌃D"], in: .micro),
        ProgramKeyEntry("micro.gotoLine", "Go to a line", ["⌃L"], in: .micro),
        ProgramKeyEntry("micro.tab", "New tab", ["⌃T"], in: .micro),
        ProgramKeyEntry("micro.split", "Move to the next split", ["⌃W"], in: .micro),
        ProgramKeyEntry("micro.help", "Help", ["⌃G"], in: .micro, strip: 7),
    ]

    // MARK: Pager

    // less's own keys, which `more` on a Mac also is.
    private static let pager: [ProgramKeyEntry] = [
        ProgramKeyEntry("pager.quit", "Quit", ["q"], in: .pager, strip: 1),
        ProgramKeyEntry("pager.pageDown", "A page down", ["space", "f"], in: .pager, short: "Page down", strip: 2),
        ProgramKeyEntry("pager.pageUp", "A page up", ["b"], in: .pager, short: "Page up", strip: 3),
        ProgramKeyEntry("pager.halfPage", "Half a page down or up", ["d", "u"], in: .pager),
        ProgramKeyEntry("pager.line", "A line down or up", ["j", "k"], in: .pager, detail: "Return and the arrow keys too"),
        ProgramKeyEntry("pager.search", "Search forward", ["/word ↩"], in: .pager, detail: "? searches backward",
                        short: "Find", strip: 4, click: .prefix("/")),
        ProgramKeyEntry("pager.next", "Next or previous match", ["n", "N"], in: .pager, short: "Next", strip: 5),
        ProgramKeyEntry("pager.top", "Top", ["g"], in: .pager, detail: "< too", strip: 6),
        ProgramKeyEntry("pager.bottom", "End", ["G"], in: .pager, detail: "> too", strip: 7),
        ProgramKeyEntry("pager.filter", "Show only the lines that match", ["&word ↩"], in: .pager,
                        detail: "& and return on its own shows every line again", click: .prefix("&")),
        ProgramKeyEntry("pager.numbers", "Show or hide line numbers", ["-N"], in: .pager),
        ProgramKeyEntry("pager.follow", "Follow new lines as they are written", ["F"], in: .pager,
                        detail: "As tail -f does; ⌃C stops following"),
        ProgramKeyEntry("pager.edit", "Open the file in your editor", ["v"], in: .pager, detail: "When reading a file, not output piped in"),
        ProgramKeyEntry("pager.help", "Help", ["h"], in: .pager, strip: 8),
    ]

    // MARK: man

    // The sections are as both macOS and Linux number them. Section 9 is left
    // out: not every system has one.
    private static let man: [ProgramKeyEntry] = [
        ProgramKeyEntry("man.quit", "Quit", ["q"], in: .man, strip: 1),
        ProgramKeyEntry("man.pageDown", "A page down", ["space", "f"], in: .man, short: "Page down", strip: 2),
        ProgramKeyEntry("man.pageUp", "A page up", ["b"], in: .man, short: "Page up", strip: 9),
        ProgramKeyEntry("man.search", "Search the page", ["/word ↩"], in: .man, detail: "n for the next match, N for the one before",
                        short: "Find", strip: 3, click: .prefix("/")),
        ProgramKeyEntry("man.next", "Next or previous match", ["n", "N"], in: .man, short: "Next", strip: 4),
        ProgramKeyEntry("man.heading", "Jump to a heading", ["/^EXAMPLES ↩"], in: .man,
                        detail: "Headings start at the left edge: NAME, SYNOPSIS, DESCRIPTION, OPTIONS, EXAMPLES, SEE ALSO",
                        short: "Heading", strip: 10, click: .prefix("/^")),
        ProgramKeyEntry("man.ends", "Top or end of the page", ["g", "G"], in: .man),
        ProgramKeyEntry("man.help", "The pager's help", ["h"], in: .man, short: "Help", strip: 11),

        ProgramKeyEntry("man.keyword", "Search every manual for a word", ["man -k word", "apropos word"], in: .man,
                        detail: "Lists the pages whose one-line description has it", short: "Search manuals",
                        strip: 5, click: .none),
        ProgramKeyEntry("man.whatis", "What a command is, in one line", ["man -f ls", "whatis ls"], in: .man, click: .none),
        ProgramKeyEntry("man.inSection", "Open the page from one section", ["man 3 printf"], in: .man,
                        detail: "For a name in more than one: printf is a command and a C function", click: .none),
        ProgramKeyEntry("man.all", "Every page with that name, one after another", ["man -a printf"], in: .man, click: .none),
        ProgramKeyEntry("man.where", "Where the page's file is", ["man -w ls"], in: .man, click: .none),

        ProgramKeyEntry("man.section1", "Section 1: user commands", ["1"], in: .man, detail: "Programs and shell commands",
                        short: "User commands", strip: 6, click: .none),
        ProgramKeyEntry("man.section2", "Section 2: system calls", ["2"], in: .man, detail: "What the kernel offers a program",
                        short: "System calls", strip: 7, click: .none),
        ProgramKeyEntry("man.section3", "Section 3: C library functions", ["3"], in: .man, short: "C library", strip: 8, click: .none),
        ProgramKeyEntry("man.section4", "Section 4: devices and special files", ["4"], in: .man, click: .none),
        ProgramKeyEntry("man.section5", "Section 5: file formats", ["5"], in: .man, detail: "Configuration files, such as crontab's",
                        click: .none),
        ProgramKeyEntry("man.section6", "Section 6: games", ["6"], in: .man, click: .none),
        ProgramKeyEntry("man.section7", "Section 7: overviews and conventions", ["7"], in: .man, click: .none),
        ProgramKeyEntry("man.section8", "Section 8: system administration", ["8"], in: .man, detail: "Commands mostly run as root",
                        click: .none),
    ]

    // MARK: tmux

    private static let tmux: [ProgramKeyEntry] = [
        ProgramKeyEntry("tmux.newWindow", "New window", ["⌃B c"], in: .tmux, strip: 1),
        ProgramKeyEntry("tmux.nextWindow", "Next or previous window", ["⌃B n", "⌃B p"], in: .tmux, short: "Next window", strip: 2),
        ProgramKeyEntry("tmux.window", "Go to a window by its number", ["⌃B 1"], in: .tmux, detail: "Any number from 0 to 9",
                        click: .prefix("⌃B")),
        ProgramKeyEntry("tmux.splitBeside", "Split, with a new pane beside this one", ["⌃B %"], in: .tmux,
                        short: "Split beside", strip: 3),
        ProgramKeyEntry("tmux.splitBelow", "Split, with a new pane below this one", ["⌃B \""], in: .tmux,
                        short: "Split below", strip: 4),
        ProgramKeyEntry("tmux.nextPane", "Move to the next pane", ["⌃B o"], in: .tmux,
                        detail: "⌃B, then an arrow key, moves that way", short: "Next pane", strip: 5),
        ProgramKeyEntry("tmux.zoom", "Zoom the pane, or put it back", ["⌃B z"], in: .tmux, short: "Zoom", strip: 6),
        ProgramKeyEntry("tmux.closePane", "Close the pane", ["⌃B x"], in: .tmux, detail: "Asks first"),
        ProgramKeyEntry("tmux.closeWindow", "Close the window", ["⌃B &"], in: .tmux, detail: "Asks first"),
        ProgramKeyEntry("tmux.detach", "Detach, leaving it running", ["⌃B d"], in: .tmux, detail: "tmux attach brings it back",
                        short: "Detach", strip: 7),
        ProgramKeyEntry("tmux.scroll", "Scroll back", ["⌃B ["], in: .tmux,
                        detail: "Copy mode: arrow or page keys move, q leaves", short: "Scroll", strip: 8),
        ProgramKeyEntry("tmux.renameWindow", "Rename the window", ["⌃B ,"], in: .tmux),
        ProgramKeyEntry("tmux.choose", "Choose a session or window from a list", ["⌃B s", "⌃B w"], in: .tmux),
        ProgramKeyEntry("tmux.command", "The command prompt", ["⌃B :"], in: .tmux),
        ProgramKeyEntry("tmux.keys", "List every key", ["⌃B ?"], in: .tmux, short: "Keys", strip: 9),
    ]

    // MARK: screen

    private static let screen: [ProgramKeyEntry] = [
        ProgramKeyEntry("screen.newWindow", "New window", ["⌃A c"], in: .screen, strip: 1),
        ProgramKeyEntry("screen.nextWindow", "Next or previous window", ["⌃A n", "⌃A p"], in: .screen,
                        short: "Next window", strip: 2),
        ProgramKeyEntry("screen.lastWindow", "Back to the window before", ["⌃A ⌃A"], in: .screen),
        ProgramKeyEntry("screen.window", "Go to a window by its number", ["⌃A 1"], in: .screen, detail: "Any number from 0 to 9",
                        click: .prefix("⌃A")),
        ProgramKeyEntry("screen.list", "List the windows", ["⌃A \""], in: .screen, short: "List", strip: 3),
        ProgramKeyEntry("screen.detach", "Detach, leaving it running", ["⌃A d"], in: .screen, detail: "screen -r brings it back",
                        short: "Detach", strip: 4),
        ProgramKeyEntry("screen.splitBelow", "Split, with a region below", ["⌃A S"], in: .screen, short: "Split", strip: 5),
        ProgramKeyEntry("screen.splitBeside", "Split, with a region beside", ["⌃A |"], in: .screen, detail: "screen 4.1 and later"),
        ProgramKeyEntry("screen.nextRegion", "Move to the next region", ["⌃A ⇥"], in: .screen, short: "Next region", strip: 6),
        ProgramKeyEntry("screen.closeRegion", "Close this region, or all the others", ["⌃A X", "⌃A Q"], in: .screen),
        ProgramKeyEntry("screen.kill", "Close the window", ["⌃A k"], in: .screen, detail: "Asks first"),
        ProgramKeyEntry("screen.scroll", "Scroll back", ["⌃A ["], in: .screen, detail: "Copy mode; esc leaves", short: "Scroll", strip: 7),
        ProgramKeyEntry("screen.rename", "Rename the window", ["⌃A A"], in: .screen),
        ProgramKeyEntry("screen.literal", "Send ⌃A itself to the program", ["⌃A a"], in: .screen),
        ProgramKeyEntry("screen.help", "Help", ["⌃A ?"], in: .screen, strip: 8),
    ]

    // MARK: top

    private static let top: [ProgramKeyEntry] = [
        ProgramKeyEntry("top.quit", "Quit", ["q"], in: .top, strip: 1),
        ProgramKeyEntry("top.help", "Help, with every key this top takes", ["?"], in: .top, detail: "Linux's top takes h too",
                        short: "Help", strip: 2),
        ProgramKeyEntry("top.delay", "How often it updates", ["s"], in: .top, detail: "Asks for the seconds", short: "Delay", strip: 3),
        ProgramKeyEntry("top.user", "Only one user's processes", ["U"], in: .top, detail: "Asks for the name", short: "One user", strip: 4),
        ProgramKeyEntry("top.sortMac", "Sort by a column (macOS)", ["o cpu ↩"], in: .top,
                        detail: "o, then the column — cpu, mem, pid, time — and return", click: .prefix("o")),
        ProgramKeyEntry("top.sortLinux", "Sort by CPU, memory or time (Linux)", ["P", "M", "T"], in: .top),
        ProgramKeyEntry("top.signalMac", "Send a signal to a process (macOS)", ["S"], in: .top, detail: "Asks for the signal, then the process"),
        ProgramKeyEntry("top.killLinux", "Send a signal to a process (Linux)", ["k"], in: .top, detail: "Asks for the process, then the signal"),
    ]

    // MARK: htop

    private static let htop: [ProgramKeyEntry] = [
        ProgramKeyEntry("htop.quit", "Quit", ["q", "F10"], in: .htop, strip: 1),
        ProgramKeyEntry("htop.search", "Find a process by name", ["/", "F3"], in: .htop, short: "Find", strip: 2),
        ProgramKeyEntry("htop.filter", "Show only the processes that match", ["\\", "F4"], in: .htop, short: "Filter", strip: 3),
        ProgramKeyEntry("htop.tree", "Tree view", ["t", "F5"], in: .htop, short: "Tree", strip: 4),
        ProgramKeyEntry("htop.sortBy", "Sort by CPU, memory or time", ["P", "M", "T"], in: .htop, short: "Sort by CPU", strip: 5),
        ProgramKeyEntry("htop.sortColumn", "Choose the column to sort by", ["<", ">", "F6"], in: .htop),
        ProgramKeyEntry("htop.kill", "Send a signal to the selected process", ["k", "F9"], in: .htop,
                        detail: "Lists the signals first", short: "Kill", strip: 6),
        ProgramKeyEntry("htop.user", "Only one user's processes", ["u"], in: .htop, short: "One user", strip: 7),
        ProgramKeyEntry("htop.tag", "Tag a process", ["space"], in: .htop, detail: "k then signals every tagged one"),
        ProgramKeyEntry("htop.priority", "Raise or lower the priority", ["]", "["], in: .htop, detail: "F7 and F8 too"),
        ProgramKeyEntry("htop.userThreads", "Hide or show user threads", ["H"], in: .htop),
        ProgramKeyEntry("htop.kernelThreads", "Hide or show kernel threads", ["K"], in: .htop, detail: "Linux"),
        ProgramKeyEntry("htop.setup", "Setup", ["S", "F2"], in: .htop),
        ProgramKeyEntry("htop.help", "Help", ["h", "F1"], in: .htop, strip: 8),
    ]

    // MARK: btop and superfile

    // The two tools the app bundles. `ShortcutCatalog` already lists their
    // keys, each checked against the version bundled, so they are taken from
    // there rather than written twice. All this says is which the strip shows,
    // in what order, and its word for each.
    private static let btop = bundledTool(.btop, from: .btop, strip: [
        ("btop.quit", "Quit"), ("btop.filter", "Filter"), ("btop.tree", "Tree"), ("btop.sortReverse", "Reverse sort"),
        ("btop.kill", "Kill"), ("btop.presetNext", "Next view"), ("btop.menu", "Menu"), ("btop.options", "Options"),
        ("btop.help", "Help"),
    ])

    private static let superfile = bundledTool(.superfile, from: .superfile, strip: [
        ("superfile.quit", "Quit"), ("superfile.search", "Search"), ("superfile.confirm", "Open"), ("superfile.parent", "Parent"),
        ("superfile.copy", "Copy"), ("superfile.paste", "Paste"), ("superfile.create", "New"), ("superfile.rename", "Rename"),
        ("superfile.dotFiles", "Dot files"), ("superfile.help", "Help"),
    ])

    private static func bundledTool(
        _ section: ProgramKeySection,
        from shortcuts: ShortcutSection,
        strip: [(id: String, short: String)]
    ) -> [ProgramKeyEntry] {
        ShortcutCatalog.all.filter { $0.section == shortcuts }.map { entry in
            let rank = strip.firstIndex { $0.id == entry.id }
            return ProgramKeyEntry(
                entry.id,
                entry.title,
                entry.chords.map(cap),
                in: section,
                detail: entry.detail,
                short: rank.map { strip[$0].short },
                strip: rank.map { $0 + 1 }
            )
        }
    }

    /// One cap a chord, written as this list writes keys: a letter on its own
    /// as the key it is, "q" — the shortcut list prints it as a capital, the
    /// way menus do, and says ⇧ when it is one — and the rest joined: "⌃C",
    /// "⇧P", "F1".
    private static func cap(_ chord: ShortcutChord) -> String {
        if chord.modifiers.isEmpty, case .character(let character) = chord.key {
            return String(character)
        }
        return chord.symbols.joined().replacingOccurrences(of: "Space", with: "space")
    }

    // MARK: Python, Node, Ruby

    // Typed at the prompt, and run with return. How to leave comes first:
    // it is what people look for.
    private static let python: [ProgramKeyEntry] = [
        ProgramKeyEntry("python.quit", "Quit", ["exit()"], in: .python, detail: "Or ⌃D on an empty line", strip: 1),
        ProgramKeyEntry("python.interrupt", "Stop what is running", ["⌃C"], in: .python, detail: "At the prompt, abandons the line",
                        short: "Stop", strip: 2),
        ProgramKeyEntry("python.help", "Help", ["help()"], in: .python, detail: "q leaves it", strip: 3),
        ProgramKeyEntry("python.helpOn", "Help on one thing", ["help(name)"], in: .python, detail: "A module, function or object",
                        short: "Help on…", strip: 4, click: .prefix("help(")),
        ProgramKeyEntry("python.dir", "The names something has", ["dir(name)"], in: .python, short: "Names in…", strip: 5,
                        click: .prefix("dir(")),
        ProgramKeyEntry("python.last", "The last result", ["_"], in: .python, short: "Last result", strip: 6),
        ProgramKeyEntry("python.endInput", "End the input, and quit", ["⌃D"], in: .python, detail: "On an empty line"),
    ]

    private static let node: [ProgramKeyEntry] = [
        ProgramKeyEntry("node.quit", "Quit", [".exit"], in: .node, detail: "Or ⌃D, or ⌃C twice", strip: 1),
        ProgramKeyEntry("node.help", "The prompt's own commands", [".help"], in: .node, short: "Help", strip: 2),
        ProgramKeyEntry("node.interrupt", "Stop what is running", ["⌃C"], in: .node, detail: "At the prompt, abandons the line",
                        short: "Stop", strip: 3),
        ProgramKeyEntry("node.editor", "Write several lines, then run them", [".editor"], in: .node,
                        detail: "⌃D runs them, ⌃C cancels", short: "Editor", strip: 4),
        ProgramKeyEntry("node.last", "The last result", ["_"], in: .node, short: "Last result", strip: 5),
        ProgramKeyEntry("node.load", "Run a file in this session", [".load file"], in: .node, short: "Load",
                        strip: 6, click: .prefix(".load space")),
        ProgramKeyEntry("node.clear", "Clear the screen", ["⌃L"], in: .node),
    ]

    private static let irb: [ProgramKeyEntry] = [
        ProgramKeyEntry("irb.quit", "Quit", ["exit"], in: .irb, detail: "Or ⌃D on an empty line", strip: 1),
        ProgramKeyEntry("irb.help", "Help", ["help"], in: .irb, strip: 2),
        ProgramKeyEntry("irb.interrupt", "Stop what is running", ["⌃C"], in: .irb, short: "Stop", strip: 3),
        ProgramKeyEntry("irb.last", "The last result", ["_"], in: .irb, short: "Last result", strip: 4),
    ]

    // MARK: Database prompts

    private static let psql: [ProgramKeyEntry] = [
        ProgramKeyEntry("psql.quit", "Quit", ["\\q"], in: .psql, detail: "Or ⌃D", strip: 1),
        ProgramKeyEntry("psql.help", "psql's own commands", ["\\?"], in: .psql, short: "Help", strip: 2),
        ProgramKeyEntry("psql.sqlHelp", "Help on SQL", ["\\h"], in: .psql, detail: "\\h and a statement, such as \\h SELECT, for that one",
                        short: "SQL help", strip: 3),
        ProgramKeyEntry("psql.databases", "List the databases", ["\\l"], in: .psql, short: "Databases", strip: 4),
        ProgramKeyEntry("psql.tables", "List the tables", ["\\dt"], in: .psql, short: "Tables", strip: 5),
        ProgramKeyEntry("psql.describe", "Describe a table", ["\\d name"], in: .psql, short: "Describe", strip: 6,
                        click: .prefix("\\d space")),
        ProgramKeyEntry("psql.connect", "Connect to another database", ["\\c name"], in: .psql, short: "Connect", strip: 7,
                        click: .prefix("\\c space")),
        ProgramKeyEntry("psql.expanded", "One column per row, or back", ["\\x"], in: .psql, detail: "Expanded output",
                        short: "Expanded", strip: 8),
        ProgramKeyEntry("psql.timing", "Show how long each query takes", ["\\timing"], in: .psql),
        ProgramKeyEntry("psql.edit", "Edit the query in your editor", ["\\e"], in: .psql),
        ProgramKeyEntry("psql.cancel", "Cancel the query that is running", ["⌃C"], in: .psql),
    ]

    private static let mysql: [ProgramKeyEntry] = [
        ProgramKeyEntry("mysql.quit", "Quit", ["exit"], in: .mysql, detail: "Or \\q", strip: 1),
        ProgramKeyEntry("mysql.help", "Help", ["help"], in: .mysql, detail: "help and a statement explains that one", strip: 2),
        ProgramKeyEntry("mysql.databases", "List the databases", ["show databases;"], in: .mysql, short: "Databases", strip: 3,
                        click: .prefix("show space databases;")),
        ProgramKeyEntry("mysql.use", "Switch to a database", ["use name;"], in: .mysql, short: "Use", strip: 4,
                        click: .prefix("use space")),
        ProgramKeyEntry("mysql.tables", "List the tables", ["show tables;"], in: .mysql, short: "Tables", strip: 5,
                        click: .prefix("show space tables;")),
        ProgramKeyEntry("mysql.describe", "Describe a table", ["describe name;"], in: .mysql, short: "Describe", strip: 6,
                        click: .prefix("describe space")),
        ProgramKeyEntry("mysql.cancel", "Cancel what is half typed", ["\\c"], in: .mysql, short: "Cancel", strip: 7),
        ProgramKeyEntry("mysql.vertical", "End a query with this for one column per row", ["\\G"], in: .mysql),
    ]

    private static let sqlite: [ProgramKeyEntry] = [
        ProgramKeyEntry("sqlite.quit", "Quit", [".quit"], in: .sqlite, detail: "Or .exit, or ⌃D", strip: 1),
        ProgramKeyEntry("sqlite.help", "Help", [".help"], in: .sqlite, strip: 2),
        ProgramKeyEntry("sqlite.tables", "List the tables", [".tables"], in: .sqlite, short: "Tables", strip: 3),
        ProgramKeyEntry("sqlite.schema", "How the tables are made", [".schema"], in: .sqlite,
                        detail: "A table's name after it for just that one", short: "Schema", strip: 4),
        ProgramKeyEntry("sqlite.mode", "How results are shown", [".mode column"], in: .sqlite,
                        detail: "column, box, table, csv, json, line, markdown", short: "Mode", strip: 5,
                        click: .prefix(".mode space")),
        ProgramKeyEntry("sqlite.headers", "Column names above results", [".headers on"], in: .sqlite, short: "Headers",
                        strip: 6, click: .prefix(".headers space")),
        ProgramKeyEntry("sqlite.open", "Open another database file", [".open file"], in: .sqlite, short: "Open", strip: 7,
                        click: .prefix(".open space")),
    ]

    // MARK: fzf and lazygit

    private static let fzf: [ProgramKeyEntry] = [
        ProgramKeyEntry("fzf.accept", "Choose the line", ["↩"], in: .fzf, short: "Choose", strip: 1, click: .none),
        ProgramKeyEntry("fzf.cancel", "Cancel", ["esc"], in: .fzf, detail: "⌃C and ⌃G too", strip: 2),
        ProgramKeyEntry("fzf.down", "Down the list", ["⌃J", "⌃N"], in: .fzf, short: "Down", strip: 3),
        ProgramKeyEntry("fzf.up", "Up the list", ["⌃K", "⌃P"], in: .fzf, short: "Up", strip: 4),
        ProgramKeyEntry("fzf.mark", "Mark the line, to choose several", ["⇥"], in: .fzf, detail: "With -m; ⇧⇥ unmarks",
                        short: "Mark", strip: 5),
        ProgramKeyEntry("fzf.clear", "Clear what is typed", ["⌃U"], in: .fzf, short: "Clear", strip: 6),
        ProgramKeyEntry("fzf.exact", "Match these letters exactly", ["'word"], in: .fzf, short: "Exact", strip: 7,
                        click: .prefix("'")),
        ProgramKeyEntry("fzf.starts", "Lines that start with it", ["^word"], in: .fzf, click: .prefix("^")),
        ProgramKeyEntry("fzf.ends", "Lines that end with it", ["word$"], in: .fzf, click: .none),
        ProgramKeyEntry("fzf.without", "Lines without it", ["!word"], in: .fzf, click: .prefix("!")),
    ]

    private static let lazygit: [ProgramKeyEntry] = [
        ProgramKeyEntry("lazygit.quit", "Quit", ["q"], in: .lazygit, detail: "esc goes back from a menu or panel", strip: 1),
        ProgramKeyEntry("lazygit.keys", "Every key for the panel in front", ["?"], in: .lazygit, short: "Keys", strip: 2),
        ProgramKeyEntry("lazygit.stage", "Stage or unstage the file", ["space"], in: .lazygit, short: "Stage", strip: 3),
        ProgramKeyEntry("lazygit.stageAll", "Stage or unstage everything", ["a"], in: .lazygit, short: "Stage all", strip: 4),
        ProgramKeyEntry("lazygit.commit", "Commit", ["c"], in: .lazygit, strip: 5),
        ProgramKeyEntry("lazygit.push", "Push", ["P"], in: .lazygit, strip: 6),
        ProgramKeyEntry("lazygit.pull", "Pull", ["p"], in: .lazygit, strip: 7),
        ProgramKeyEntry("lazygit.panels", "Previous or next panel", ["h", "l"], in: .lazygit, detail: "← and → too"),
        ProgramKeyEntry("lazygit.discard", "Discard the change", ["d"], in: .lazygit, detail: "Asks first"),
        ProgramKeyEntry("lazygit.undo", "Undo", ["z"], in: .lazygit, detail: "From the reflog"),
        ProgramKeyEntry("lazygit.menu", "The panel's commands, as a menu", ["x"], in: .lazygit),
        ProgramKeyEntry("lazygit.filter", "Filter or search", ["/"], in: .lazygit),
        ProgramKeyEntry("lazygit.back", "Back", ["esc"], in: .lazygit),
    ]

    // MARK: Choosing hunks

    // `git add -p`, and `checkout`, `reset`, `restore`, `stash` and `commit`
    // with -p: one question for each hunk.
    private static let gitPatch: [ProgramKeyEntry] = [
        ProgramKeyEntry("gitPatch.yes", "Take this hunk", ["y"], in: .gitPatch, short: "Yes", strip: 1),
        ProgramKeyEntry("gitPatch.no", "Leave this hunk", ["n"], in: .gitPatch, short: "No", strip: 2),
        ProgramKeyEntry("gitPatch.split", "Split it into smaller hunks", ["s"], in: .gitPatch, short: "Split", strip: 3),
        ProgramKeyEntry("gitPatch.edit", "Edit it by hand", ["e"], in: .gitPatch, short: "Edit", strip: 4),
        ProgramKeyEntry("gitPatch.all", "This one and every later one in the file", ["a"], in: .gitPatch, short: "All in file", strip: 5),
        ProgramKeyEntry("gitPatch.none", "None of the rest in the file", ["d"], in: .gitPatch, short: "None in file", strip: 6),
        ProgramKeyEntry("gitPatch.quit", "Stop here", ["q"], in: .gitPatch, detail: "What was taken so far stays",
                        short: "Quit", strip: 7),
        ProgramKeyEntry("gitPatch.help", "Help", ["?"], in: .gitPatch, strip: 8),
        ProgramKeyEntry("gitPatch.goto", "Go to a hunk", ["g"], in: .gitPatch),
        ProgramKeyEntry("gitPatch.search", "Find a hunk by what it changes", ["/"], in: .gitPatch),
    ]

    // MARK: ssh

    // From ssh(1), ESCAPE CHARACTERS. ~C is left out: OpenSSH 9.2 and later
    // turn it off unless EnableEscapeCommandline is set. None is typed by a
    // click: each starts with a return, which would run whatever is half typed
    // on the far end's line.
    private static let ssh: [ProgramKeyEntry] = [
        ProgramKeyEntry("ssh.disconnect", "Disconnect", ["↩ ~ ."], in: .ssh, detail: "Even when the far end has stopped answering",
                        strip: 1, click: .none),
        ProgramKeyEntry("ssh.suspend", "Suspend ssh, back to this Mac's shell", ["↩ ~ ⌃Z"], in: .ssh, detail: "fg goes back to it",
                        short: "Suspend", strip: 2, click: .none),
        ProgramKeyEntry("ssh.forwards", "List the forwarded connections", ["↩ ~ #"], in: .ssh, short: "Forwards", strip: 3,
                        click: .none),
        ProgramKeyEntry("ssh.rekey", "Make new session keys", ["↩ ~ R"], in: .ssh, click: .none),
        ProgramKeyEntry("ssh.literal", "Send a ~ itself", ["↩ ~ ~"], in: .ssh, click: .none),
        ProgramKeyEntry("ssh.help", "List the escape keys", ["↩ ~ ?"], in: .ssh, short: "Help", strip: 4, click: .none),
    ]

    // MARK: Shell

    // Keys zsh's line editor and bash's readline share in their default
    // (emacs) mode. ⌃C, ⌃Z and ⌃D are the terminal's own, which is why the
    // strip also shows them for a program it has no keys for.
    private static let shell: [ProgramKeyEntry] = [
        ProgramKeyEntry("shell.history", "Search the commands you have run", ["⌃R"], in: .shell,
                        detail: "Type part of one; ⌃R again for older matches, return runs it", short: "History", strip: 1),
        ProgramKeyEntry("shell.lineStart", "Start of the line", ["⌃A"], in: .shell, short: "Start", strip: 2),
        ProgramKeyEntry("shell.lineEnd", "End of the line", ["⌃E"], in: .shell, short: "End", strip: 3),
        ProgramKeyEntry("shell.word", "Back or forward a word", ["⌥B", "⌥F"], in: .shell),
        ProgramKeyEntry("shell.deleteWord", "Delete the word before the cursor", ["⌃W"], in: .shell, short: "Delete word", strip: 4),
        ProgramKeyEntry("shell.deleteLine", "Delete the line", ["⌃U"], in: .shell, detail: "In bash, only what is before the cursor",
                        short: "Clear line", strip: 5),
        ProgramKeyEntry("shell.deleteToEnd", "Delete to the end of the line", ["⌃K"], in: .shell),
        ProgramKeyEntry("shell.paste", "Put back what was deleted", ["⌃Y"], in: .shell),
        ProgramKeyEntry("shell.undo", "Undo the last change to the line", ["⌃_"], in: .shell),
        ProgramKeyEntry("shell.clear", "Clear the screen", ["⌃L"], in: .shell, short: "Clear screen", strip: 6),
        ProgramKeyEntry("shell.repeat", "Run the last command again", ["!!"], in: .shell, detail: "sudo !! runs it as root",
                        short: "Last command", strip: 7),
        ProgramKeyEntry("shell.lastArgument", "The last word of the command before", ["⌥."], in: .shell,
                        detail: "Again for the one before that", short: "Last word", strip: 8),
        ProgramKeyEntry("shell.previousFolder", "Back to the folder you were in before", ["cd -"], in: .shell,
                        short: "Previous folder", strip: 9, click: .prefix("cd space -")),
        ProgramKeyEntry("shell.complete", "Complete a command, file or folder name", ["⇥"], in: .shell),
        ProgramKeyEntry("shell.interrupt", "Stop the running command", ["⌃C"], in: .shell, detail: "At a prompt, abandons the line",
                        short: "Stop"),
        ProgramKeyEntry("shell.suspend", "Suspend the running command", ["⌃Z"], in: .shell, detail: "fg brings it back, bg keeps it going behind",
                        short: "Suspend"),
        ProgramKeyEntry("shell.endInput", "End the input", ["⌃D"], in: .shell, detail: "On an empty line, exits the shell",
                        short: "End input"),
    ]
}
