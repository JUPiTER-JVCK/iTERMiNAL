import Foundation

/// What Tab can complete the word at the caret to, when it is a flag or a
/// subcommand of a tool `CommandSpecs` knows.
struct OptionCompletion: Equatable {
    struct Candidate: Equatable {
        /// What the list shows: `-a, --all`, or `commit`.
        var display: String
        /// One line on what it does.
        var detail: String
        /// The spelling this candidate would put in the field, with nothing after it.
        var word: String
        /// What the word becomes if this one is chosen: `word`, then a space —
        /// unless its value follows straight after (`--author=`) or there is a
        /// space there already.
        var insertion: String
    }

    /// UTF-16 range of the word being completed, the unit `NSRange` uses.
    var range: Range<Int>
    /// What has been typed of it.
    var typed: String
    /// The first `OptionCompleter.maxCandidates` matches, in the order of the table.
    var candidates: [Candidate]
    /// How many things match in all.
    var matchCount: Int
    /// What the word becomes when every match shares more than has been typed.
    /// Nil for a single match, and when they share nothing further.
    var sharedInsertion: String?
}

/// Completes flags and subcommands for the composer's Tab key, from the table in
/// `CommandSpecs`.
///
/// It reads the command line up to the caret, finds the tool being run, and
/// works out whether the word at the caret is a flag, a subcommand or neither.
/// Neither is most of the time — a file name, a value, a pattern — and then it
/// returns nil, which leaves the key to the file-name completer.
///
/// Approximate where shells are: it does not expand aliases or functions, does
/// not look inside `$(…)` or backticks (it gives up on a line that has them),
/// and cannot tell a flag's value from a subcommand when the flag is not in the
/// table. A miss costs a completion, never a wrong one.
enum OptionCompleter {
    static let maxCandidates = 100

    /// Words that run the next word: `sudo git status`. A flag of their own
    /// (`sudo -u root`) is more than this knows, so it stops there.
    private static let prefixCommands: Set<String> = [
        "sudo", "doas", "env", "time", "command", "nohup", "exec", "nice", "builtin",
    ]

    static func complete(text: String, caret: Int) -> OptionCompletion? {
        let units = Array(text.utf16)
        let caret = min(max(caret, 0), units.count)
        guard let scan = scanWords(units, upTo: caret) else { return nil }
        let words = scan.words
        if let current = scan.current, !current.plain { return nil }
        let typed = scan.current?.text ?? ""
        let rangeStart = scan.current?.start ?? caret

        // The command: past `VAR=value` prefixes and words like `sudo`.
        var index = 0
        while index < words.count {
            let word = words[index]
            guard word.plain else { return nil }
            if isAssignment(word.text) {
                index += 1
                continue
            }
            if prefixCommands.contains(word.text) {
                index += 1
                if index < words.count, words[index].text.hasPrefix("-") { return nil }
                continue
            }
            break
        }
        // Past the end: the command is the word being typed, or there is none.
        guard index < words.count else { return nil }
        let commandWord = words[index]
        guard commandWord.plain, !commandWord.text.contains("/"),
              let spec = CommandSpecs.spec(named: commandWord.text) else { return nil }

        // What the words between the command and the caret have settled.
        var subcommand: SpecEntry?
        var unknownSubcommand = false
        var expectingValue = false
        var optionsEnded = false
        for word in words[(index + 1)...] {
            let arg = word.text
            if optionsEnded { continue }
            if expectingValue {
                expectingValue = false
                continue
            }
            if arg == "--" {
                optionsEnded = true
                continue
            }
            if arg.hasPrefix("-"), arg != "-" {
                let known = spec.options(after: subcommand).first { $0.names.contains(arg) }
                if known?.takesSeparateValue == true { expectingValue = true }
                continue
            }
            if spec.hasSubcommands, subcommand == nil, !unknownSubcommand {
                subcommand = spec.subcommand(named: arg)
                if subcommand == nil { unknownSubcommand = true }
            }
        }
        // The word at the caret is a value, or after `--` a plain argument.
        if optionsEnded || expectingValue { return nil }

        let entries: [SpecEntry]
        if typed.hasPrefix("-") {
            // `--author=ab` is half way through a value.
            if typed.contains("=") || unknownSubcommand { return nil }
            entries = spec.options(after: subcommand)
        } else {
            guard spec.hasSubcommands, subcommand == nil, !unknownSubcommand else { return nil }
            entries = spec.subcommands
        }

        var matches: [(entry: SpecEntry, word: String)] = []
        for entry in entries {
            if let name = entry.names.first(where: { $0.hasPrefix(typed) }) {
                matches.append((entry, name))
            }
        }
        guard !matches.isEmpty else { return nil }

        let spaceNeeded = caret >= units.count || !isBlank(units[caret])
        let candidates = matches.prefix(maxCandidates).map { match in
            OptionCompletion.Candidate(
                display: match.entry.display,
                detail: match.entry.detail,
                word: match.word,
                insertion: match.word.hasSuffix("=") || !spaceNeeded ? match.word : match.word + " "
            )
        }

        var shared: String?
        if matches.count > 1 {
            let common = commonPrefix(matches.map(\.word))
            if common.count > typed.count { shared = common }
        }
        return OptionCompletion(
            range: rangeStart..<caret,
            typed: typed,
            candidates: Array(candidates),
            matchCount: matches.count,
            sharedInsertion: shared
        )
    }

    // MARK: Reading the line

    private struct Word {
        var start: Int
        var text: String
        /// No quote, backslash or `$` in it: its text is what the shell sees.
        var plain: Bool
    }

    private struct Scan {
        /// The words of the command the caret is in, before the one being typed.
        var words: [Word]
        /// The word the caret is at the end of, if it is not after a space.
        var current: Word?
    }

    private enum U {
        static let space = UInt16(0x20), tab = UInt16(0x09)
        static let newline = UInt16(0x0A), carriageReturn = UInt16(0x0D)
        static let pipe = UInt16(0x7C), ampersand = UInt16(0x26), semicolon = UInt16(0x3B)
        static let leftParen = UInt16(0x28), rightParen = UInt16(0x29)
        static let less = UInt16(0x3C), greater = UInt16(0x3E)
        static let backslash = UInt16(0x5C), singleQuote = UInt16(0x27), doubleQuote = UInt16(0x22)
        static let backtick = UInt16(0x60), dollar = UInt16(0x24), hash = UInt16(0x23)
    }

    /// Splits the line up to the caret into words, starting afresh after `|`,
    /// `&&`, `;`, `(` and a new line. Nil when the line is more than this reads:
    /// an open quote, a command substitution, or a file name being typed after
    /// a redirection.
    private static func scanWords(_ units: [UInt16], upTo caret: Int) -> Scan? {
        var words: [Word] = []
        var start: Int?
        var buffer: [UInt16] = []
        var plain = true
        var redirectPending = false

        func finishWord() {
            guard let begun = start else { return }
            // The word after `>` is a file name, not an argument.
            if redirectPending {
                redirectPending = false
            } else {
                words.append(Word(start: begun, text: String(decoding: buffer, as: UTF16.self), plain: plain))
            }
            start = nil
            buffer = []
            plain = true
        }
        func begin(_ index: Int) {
            if start == nil { start = index }
        }

        var i = 0
        while i < caret {
            let c = units[i]
            switch c {
            case U.space, U.tab:
                finishWord()
                i += 1

            case U.newline, U.carriageReturn, U.pipe, U.ampersand, U.semicolon, U.leftParen, U.rightParen:
                finishWord()
                words = []
                redirectPending = false
                i += 1

            case U.less, U.greater:
                // `2>`: a number straight before it names a stream, not an argument.
                if start != nil, plain, buffer.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) {
                    start = nil
                    buffer = []
                } else {
                    finishWord()
                }
                redirectPending = true
                i += 1
                while i < caret, units[i] == U.greater || units[i] == U.ampersand || units[i] == U.pipe { i += 1 }

            case U.backslash:
                if i + 1 < caret, units[i + 1] == U.newline {
                    // A continued line is still the same line.
                    finishWord()
                    i += 2
                    continue
                }
                begin(i)
                plain = false
                if i + 1 < caret {
                    buffer.append(units[i + 1])
                    i += 2
                } else {
                    i += 1
                }

            case U.singleQuote:
                begin(i)
                plain = false
                var j = i + 1
                while j < caret, units[j] != U.singleQuote {
                    buffer.append(units[j])
                    j += 1
                }
                if j >= caret { return nil }
                i = j + 1

            case U.doubleQuote:
                begin(i)
                plain = false
                var j = i + 1
                var closed = false
                while j < caret {
                    let inner = units[j]
                    if inner == U.backslash, j + 1 < caret {
                        buffer.append(units[j + 1])
                        j += 2
                        continue
                    }
                    if inner == U.doubleQuote {
                        closed = true
                        break
                    }
                    if inner == U.backtick { return nil }
                    if inner == U.dollar, j + 1 < caret, units[j + 1] == U.leftParen { return nil }
                    buffer.append(inner)
                    j += 1
                }
                if !closed { return nil }
                i = j + 1

            case U.backtick:
                return nil

            case U.dollar:
                if i + 1 < caret, units[i + 1] == U.leftParen { return nil }
                begin(i)
                plain = false
                buffer.append(c)
                i += 1

            case U.hash where start == nil:
                // A comment runs to the end of the line; the caret inside one
                // has nothing to complete.
                while i < caret, units[i] != U.newline { i += 1 }
                if i >= caret { return nil }

            default:
                begin(i)
                buffer.append(c)
                i += 1
            }
        }

        // Typing a file name after `>`: not ours to complete.
        if redirectPending { return nil }
        let current = start.map { Word(start: $0, text: String(decoding: buffer, as: UTF16.self), plain: plain) }
        return Scan(words: words, current: current)
    }

    private static func isBlank(_ unit: UInt16) -> Bool {
        unit == U.space || unit == U.tab || unit == U.newline || unit == U.carriageReturn
    }

    /// `NAME=value`, which sets a variable for the command that follows.
    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func commonPrefix(_ words: [String]) -> String {
        guard var prefix = words.first else { return "" }
        for word in words.dropFirst() {
            while !word.hasPrefix(prefix) { prefix.removeLast() }
            if prefix.isEmpty { break }
        }
        return prefix
    }
}
