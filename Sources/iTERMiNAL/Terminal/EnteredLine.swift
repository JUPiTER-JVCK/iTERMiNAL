import Foundation

/// Whether a line typed into a terminal was a command its shell took, and what
/// a tab is called after one. Foundation only, so it is checked off a Mac.
///
/// The line is rebuilt from the keys pressed (`InstrumentedTerminalView`),
/// whatever program is reading them. At a `sudo`, `ssh`, `su` or `passwd`
/// prompt those keys are a password: echo being off keeps it off the screen,
/// not out of the keystrokes. Taken for a command, it became the tab's name —
/// in the sidebar, the task manager, notifications, the local API, Recents and
/// the composer's history, the last two of which are written to disk. So a
/// line is taken only when what was true as Return was pressed says the shell
/// was the one reading it, and only when it starts the way a command does.
enum EnteredLine {
    /// What was true of the terminal as Return was pressed. It is read before
    /// the Return is passed on: once the shell has it, the program the line
    /// starts can take the terminal, and would then seem to have been there
    /// all along.
    struct Moment: Equatable {
        /// Whether the shell's own process group had the terminal, from the
        /// kernel: true at its prompt, false while a job it started — `sudo`,
        /// `ssh`, `vim` — has it. Nil when the kernel could not say.
        var shellInFront: Bool?
        /// Whether the terminal was taking a whole line without showing it:
        /// line-at-a-time input with echo off. That is how `sudo`, `ssh`, `su`,
        /// `passwd` and `read -s` read a password, as they come. (A sudo set
        /// to show `*` for each key reads key by key instead, and is left to
        /// the other checks.) A shell's own line editor turns echo off too,
        /// but reads key by key, so it is not this.
        var hiddenInput: Bool
        /// Whether the alternate screen was showing, which full-screen programs
        /// — editors, pagers, top, tmux — switch to while they run.
        var alternateScreen: Bool
    }

    /// Whether a line entered at `moment` may be taken for a command.
    ///
    /// For a remote session the kernel can only say that `ssh` has the
    /// terminal, which it always does, so its answer is not used there. What
    /// remains is what this Mac can see: `ssh`'s own password prompt is hidden
    /// input, and a full-screen program is on the alternate screen. A prompt on
    /// the far end, behind ssh, is out of sight; `label(for:)` is what is left
    /// for that.
    static func isCommand(at moment: Moment, remote: Bool) -> Bool {
        if moment.hiddenInput || moment.alternateScreen { return false }
        if remote { return true }
        return moment.shellInFront ?? true
    }

    /// What a tab is called after `line`: the program and its first argument,
    /// since a whole command line is far wider than a sidebar row and its head
    /// is what tells one tab from another. Nil when the line should not name a
    /// tab at all.
    ///
    /// - A line that starts with a space: shells keep those out of their
    ///   history when asked to (bash's `ignorespace`, zsh's
    ///   `HIST_IGNORE_SPACE`), which is how people keep a command with a secret
    ///   in it out of the record.
    /// - A line whose command word could not be one (`isPlausibleCommandWord`).
    ///   Leading `NAME=value` assignments are looked past to find it, and kept
    ///   in the name as they always were.
    static func label(for line: String) -> String? {
        guard let first = line.unicodeScalars.first,
              !CharacterSet.whitespacesAndNewlines.contains(first) else { return nil }
        let words = line.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true)
        guard let command = words.first(where: { !isAssignment($0) }),
              isPlausibleCommandWord(command) else { return nil }
        return words.prefix(2).joined(separator: " ")
    }

    /// Words that are commands without a letter in them.
    private static let shellWords: Set<Substring> = ["[", "[[", "(", "((", "{", "!", "!!", ".", "..", ":", "-", "~"]

    /// Whether `word` could start a command: a name or a path made of letters,
    /// digits and `. _ - + / ~`, with a letter in it — `ls`, `g++`, `7z`,
    /// `./build.sh`, `~/bin/sync`, `/usr/bin/env` — or one of the shell's own
    /// (`[`, `.`, `!!`, …). A `\` before it (the command, not an alias of it)
    /// and an opening `(` are looked past.
    ///
    /// A password often has a character no command name does (`@ # $ % & * ! =`
    /// and the rest), or no letter at all, and is then not taken. One made of
    /// letters and digits alone can look like any command, which is why this
    /// is the last check rather than the first.
    static func isPlausibleCommandWord(_ word: Substring) -> Bool {
        if shellWords.contains(word) { return true }
        var name = word
        if name.hasPrefix("\\") { name = name.dropFirst() }
        while name.hasPrefix("(") { name = name.dropFirst() }
        guard let head = name.first, head != "-",
              name.unicodeScalars.allSatisfy(isNameScalar),
              name.unicodeScalars.contains(where: isLetter),
              // `~` starts a path to a home folder, and is nowhere else in one.
              !name.dropFirst().contains("~") else { return false }
        return true
    }

    /// `NAME=value`, which sets a variable for the command after it.
    private static func isAssignment(_ word: Substring) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals].unicodeScalars
        guard let first = name.first, isLetter(first) || first == "_" else { return false }
        return name.allSatisfy { isLetter($0) || isDigit($0) || $0 == "_" }
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar)
    }

    private static func isNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        isLetter(scalar) || isDigit(scalar) || ".-_+/~".unicodeScalars.contains(scalar)
    }

    // MARK: The line

    /// The line being typed, rebuilt from the bytes heading for the terminal.
    ///
    /// Deliberately conservative. These are the bytes the user typed, not what
    /// the shell has after its own line editing, so anything that rewrites the
    /// line behind our back — history recall, tab completion, any arrow key —
    /// abandons the buffer rather than reporting a command that was never run.
    /// A wrong tab name is worse than the directory it would otherwise show.
    struct LineBuffer {
        /// What has been typed since the last Enter.
        private var bytes: [UInt8] = []
        /// Cleared when something happens that makes the buffer stop matching
        /// what the shell will actually run.
        private var isTrustworthy = true

        init() {}

        /// What has been typed since the last Enter, while it still matches
        /// what the shell has. Nil once anything has moved or rewritten the
        /// line where the buffer cannot follow, and while nothing is typed.
        var text: String? {
            guard isTrustworthy, !bytes.isEmpty else { return nil }
            return String(bytes: bytes, encoding: .utf8)
        }

        /// Takes in `data` and returns each line it completes, with the moment
        /// it was entered at — which still has to say it was the shell's
        /// (`isCommand`).
        ///
        /// `moment` was read before `data` was passed on, so it speaks for the
        /// first Return in it only. A line after that in the same bytes — a
        /// paste of several — is read by whatever the first one started, which
        /// nothing here has seen: `sudo ls` and then the password, pasted
        /// together. Those lines are not returned, and nor is one completed
        /// with no moment at all.
        mutating func feed(_ data: ArraySlice<UInt8>, moment: Moment?) -> [(line: String, moment: Moment)] {
            var moment = moment
            var lines: [(line: String, moment: Moment)] = []
            for byte in data {
                switch byte {
                case 0x0D, 0x0A:                    // Enter: the line is complete
                    if isTrustworthy, !bytes.isEmpty, let moment,
                       let line = String(bytes: bytes, encoding: .utf8) {
                        lines.append((line, moment))
                    }
                    moment = nil
                    bytes.removeAll(keepingCapacity: true)
                    isTrustworthy = true
                case 0x7F, 0x08:                    // Backspace
                    // One keypress deletes one character, which in UTF-8 may be
                    // several bytes: dropping a single byte would leave a broken
                    // sequence that fails to decode on Enter, silently losing an
                    // otherwise perfectly good command.
                    while let last = bytes.last, last & 0xC0 == 0x80 {
                        bytes.removeLast()
                    }
                    if !bytes.isEmpty { bytes.removeLast() }
                case 0x03, 0x04, 0x15:              // ^C, ^D, ^U abandon the line
                    bytes.removeAll(keepingCapacity: true)
                    isTrustworthy = true
                case 0x20...0x7E, 0x80...0xFF:      // Printable ASCII and UTF-8
                    bytes.append(byte)
                default:
                    // Every other control byte — escape sequences, Tab, and the
                    // readline editing keys (^W, ^K, ^A, ^E, ^Y…) — moves or
                    // rewrites the shell's line somewhere this buffer cannot
                    // follow. Treating them as "no effect" produced titles that
                    // were confidently wrong: `echo old`, ^W, `new` runs
                    // `echo new` and would have been recorded as `echo oldnew`.
                    isTrustworthy = false
                }
            }
            return lines
        }
    }

    // MARK: Names written before these rules

    /// The title a Recents entry keeps when it is read back.
    ///
    /// An entry closed by a build before this one (`vetted` unset) may be named
    /// after a password: its tab was, and the name was written to the state
    /// file. It is renamed after where it was — its host, else its folder —
    /// which is what its tab would have been called with no command to go by.
    /// A name chosen by hand, or set by the shell, goes with it; there is no
    /// telling those apart from a password now.
    static func recentTitle(_ title: String, vetted: Bool?, directory: String, connectionName: String?) -> String {
        if vetted == true { return title }
        if let connectionName, !connectionName.isEmpty { return connectionName }
        let folder = (directory as NSString).lastPathComponent
        return folder.isEmpty ? "Terminal" : folder
    }
}
