/// What a stretch of a command line is, for colouring it as it is typed.
enum ShellTokenKind: Equatable {
    /// The word that names what runs: `git` in `git status`.
    case command
    /// `-l`, `--force`, or the `--name=` part of `--name=value`.
    case flag
    /// A quoted run, quotes included. An unterminated one runs to the end.
    case string
    /// `$HOME`, `${name}`, `$?`, and the `NAME` of a `NAME=value` prefix.
    case variable
    /// Pipes, `&&`, `;`, redirections, grouping and reserved words (`if`, `do`).
    case op
    /// `#` to the end of the line.
    case comment
}

struct ShellToken: Equatable {
    let kind: ShellTokenKind
    /// UTF-16 offsets into the text — the unit `NSRange` and `NSTextStorage`
    /// use, so a token's range goes straight into an attribute call.
    let range: Range<Int>
}

/// Splits a command line into coloured spans.
///
/// A lexer, not a parser: it only has to decide what colour each stretch of
/// text is while someone is typing, so it never fails and never needs the
/// line to be complete — an unclosed quote, a trailing pipe and a half-typed
/// `$(` are all ordinary input here. It does not know aliases or functions,
/// which live in the user's shell, so it cannot say whether a command word is
/// *real*; the editor decides that and leaves unknown words neutral.
///
/// Deliberately approximate where shells disagree with each other. `sudo -u
/// root ls` takes `root` for the command, because telling it is an option
/// argument needs per-tool knowledge. That costs a neutral word, never a
/// wrong colour, since an unrecognised command word is left uncoloured.
enum ShellTokenizer {
    static func tokenize(_ text: String) -> [ShellToken] {
        var lexer = Lexer(Array(text.utf16))
        lexer.run()
        return lexer.tokens
    }

    /// Words after which the next word is a command again: `sudo ls`.
    private static let prefixCommands: Set<String> = [
        "sudo", "doas", "env", "time", "nohup", "exec", "command", "builtin", "nice", "xargs",
    ]
    /// Reserved words that open a command position: `then echo`.
    private static let openingKeywords: Set<String> = [
        "if", "then", "else", "elif", "while", "until", "do", "{", "!",
    ]
    /// Reserved words that do not: `fi`, `for x`.
    private static let closingKeywords: Set<String> = [
        "fi", "done", "esac", "for", "case", "select", "function", "}",
    ]

    // MARK: Characters

    private enum Ch {
        static let space = UInt16(0x20), tab = UInt16(0x09)
        static let newline = UInt16(0x0A), cr = UInt16(0x0D)
        static let hash = UInt16(0x23), dollar = UInt16(0x24)
        static let amp = UInt16(0x26), squote = UInt16(0x27)
        static let lparen = UInt16(0x28), rparen = UInt16(0x29)
        static let minus = UInt16(0x2D), semicolon = UInt16(0x3B)
        static let lt = UInt16(0x3C), eq = UInt16(0x3D), gt = UInt16(0x3E)
        static let backslash = UInt16(0x5C), backtick = UInt16(0x60)
        static let dquote = UInt16(0x22), pipe = UInt16(0x7C)
        static let lbrace = UInt16(0x7B), rbrace = UInt16(0x7D)
        static let underscore = UInt16(0x5F)
    }

    private static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }

    private static func isIdentifierStart(_ c: UInt16) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == Ch.underscore
    }

    private static func isIdentifierPart(_ c: UInt16) -> Bool {
        isIdentifierStart(c) || isDigit(c)
    }

    /// Ends a word when unquoted.
    private static func isWordBreak(_ c: UInt16) -> Bool {
        switch c {
        case Ch.space, Ch.tab, Ch.newline, Ch.cr,
             Ch.pipe, Ch.amp, Ch.semicolon, Ch.lt, Ch.gt, Ch.lparen, Ch.rparen:
            return true
        default:
            return false
        }
    }

    // MARK: Lexer

    private struct Lexer {
        let u: [UInt16]
        var i = 0
        var tokens: [ShellToken] = []
        /// True where a command may start: the beginning, after `|`, `;`, `&&`,
        /// a newline, `(`, `$(`, and after a prefix like `sudo`.
        var expectCommand = true
        /// The word after `>` or `<` is a file name, not a command.
        var redirectTarget = false
        var inBackticks = false

        init(_ units: [UInt16]) { u = units }

        mutating func run() {
            while i < u.count {
                let c = u[i]
                switch c {
                case Ch.space, Ch.tab:
                    i += 1
                case Ch.newline, Ch.cr:
                    expectCommand = true
                    redirectTarget = false
                    i += 1
                case Ch.backslash where i + 1 < u.count && u[i + 1] == Ch.newline:
                    // A continued line is still the same command.
                    i += 2
                case Ch.hash:
                    comment()
                case Ch.pipe, Ch.amp, Ch.semicolon, Ch.lt, Ch.gt, Ch.lparen, Ch.rparen:
                    opRun()
                default:
                    word()
                }
            }
        }

        private mutating func emit(_ kind: ShellTokenKind, _ from: Int, _ to: Int) {
            guard to > from else { return }
            tokens.append(ShellToken(kind: kind, range: from..<to))
        }

        private func peek(_ offset: Int = 0) -> UInt16? {
            i + offset < u.count ? u[i + offset] : nil
        }

        private mutating func comment() {
            let start = i
            while i < u.count, u[i] != Ch.newline, u[i] != Ch.cr { i += 1 }
            emit(.comment, start, i)
        }

        // MARK: Operators

        private mutating func opRun() {
            let start = i
            switch u[i] {
            case Ch.pipe:
                i += 1
                if peek() == Ch.pipe || peek() == Ch.amp { i += 1 }
                emit(.op, start, i)
                expectCommand = true
                redirectTarget = false
            case Ch.amp:
                i += 1
                if peek() == Ch.amp {
                    i += 1
                    emit(.op, start, i)
                    expectCommand = true
                    redirectTarget = false
                } else if peek() == Ch.gt {
                    // &> and &>> send both streams to a file.
                    i += 1
                    if peek() == Ch.gt { i += 1 }
                    emit(.op, start, i)
                    redirectTarget = true
                } else {
                    emit(.op, start, i)
                    expectCommand = true
                    redirectTarget = false
                }
            case Ch.semicolon:
                i += 1
                if peek() == Ch.semicolon { i += 1 }
                emit(.op, start, i)
                expectCommand = true
                redirectTarget = false
            case Ch.lt, Ch.gt:
                redirection(from: start)
            case Ch.lparen:
                i += 1
                emit(.op, start, i)
                expectCommand = true
                redirectTarget = false
            case Ch.rparen:
                i += 1
                emit(.op, start, i)
                expectCommand = false
                redirectTarget = false
            default:
                i += 1
            }
        }

        /// `i` is on the `<` or `>`; `start` is where the operator begins,
        /// which is earlier when a file descriptor leads it (`2>`).
        private mutating func redirection(from start: Int) {
            let first = u[i]
            i += 1
            if first == Ch.lt {
                if peek() == Ch.lt {
                    i += 1
                    if peek() == Ch.lt || peek() == Ch.minus { i += 1 }   // <<< and <<-
                } else if peek() == Ch.gt {
                    i += 1                                                // <>
                } else if peek() == Ch.amp {
                    i += 1                                                // <& duplicates an input descriptor
                }
            } else {
                if peek() == Ch.gt {
                    i += 1                                                // >>
                } else if peek() == Ch.amp || peek() == Ch.pipe {
                    i += 1                                                // >& and >|
                }
            }
            if peek() == Ch.lparen, !(u[i - 1] == Ch.amp || u[i - 1] == Ch.pipe) {
                // <( and >( are process substitution: a command follows.
                i += 1
                emit(.op, start, i)
                expectCommand = true
                redirectTarget = false
                return
            }
            emit(.op, start, i)
            redirectTarget = true
        }

        // MARK: Words

        private enum Role { case command, flag, plain }

        private mutating func word() {
            let start = i

            // 2> and 0< : digits glued to a redirection belong to it.
            var digitsEnd = i
            while digitsEnd < u.count, ShellTokenizer.isDigit(u[digitsEnd]) { digitsEnd += 1 }
            if digitsEnd > i, digitsEnd < u.count, u[digitsEnd] == Ch.lt || u[digitsEnd] == Ch.gt {
                i = digitsEnd
                redirection(from: start)
                return
            }

            let isTarget = redirectTarget
            redirectTarget = false

            // NAME=value before a command: NAME is a variable, and a command
            // is still to come.
            var isAssignment = false
            if expectCommand, !isTarget, let equals = assignmentEquals(at: start) {
                emit(.variable, start, equals)
                i = equals + 1
                isAssignment = true
            }

            let role: Role
            if isTarget || isAssignment {
                role = .plain
            } else if u[start] == Ch.minus {
                role = .flag
            } else if expectCommand {
                role = .command
            } else {
                role = .plain
            }

            let firstTokenIndex = tokens.count
            var segmentStart = i
            var firstRun = true

            while i < u.count {
                let c = u[i]
                if ShellTokenizer.isWordBreak(c) { break }
                switch c {
                case Ch.squote:
                    flush(from: segmentStart, role: role, first: &firstRun, wordStart: start)
                    let quoteStart = i
                    i += 1
                    while i < u.count, u[i] != Ch.squote { i += 1 }
                    if i < u.count { i += 1 }
                    emit(.string, quoteStart, i)
                    segmentStart = i
                case Ch.dquote:
                    flush(from: segmentStart, role: role, first: &firstRun, wordStart: start)
                    doubleQuoted()
                    segmentStart = i
                case Ch.backslash:
                    i = min(i + 2, u.count)
                case Ch.dollar:
                    if let end = variableEnd(at: i) {
                        flush(from: segmentStart, role: role, first: &firstRun, wordStart: start)
                        emit(.variable, i, end)
                        i = end
                        segmentStart = i
                    } else if peek(1) == Ch.lparen {
                        // $( opens a command, so this word is over and the
                        // next one is a command.
                        flush(from: segmentStart, role: role, first: &firstRun, wordStart: start)
                        emit(.op, i, i + 2)
                        i += 2
                        expectCommand = true
                        return
                    } else {
                        i += 1
                    }
                case Ch.backtick:
                    flush(from: segmentStart, role: role, first: &firstRun, wordStart: start)
                    emit(.op, i, i + 1)
                    i += 1
                    inBackticks.toggle()
                    expectCommand = inBackticks
                    return
                default:
                    i += 1
                }
            }
            flush(from: segmentStart, role: role, first: &firstRun, wordStart: start)

            // What this word does to what comes next.
            if isTarget || isAssignment { return }
            let text = String(decoding: u[start..<i], as: UTF16.self)
            if role == .command {
                if tokens.count == firstTokenIndex + 1,
                   tokens[firstTokenIndex].kind == .command,
                   tokens[firstTokenIndex].range == start..<i,
                   ShellTokenizer.openingKeywords.contains(text) || ShellTokenizer.closingKeywords.contains(text) {
                    // Reserved words look like commands and are not.
                    tokens[firstTokenIndex] = ShellToken(kind: .op, range: start..<i)
                    expectCommand = ShellTokenizer.openingKeywords.contains(text)
                } else {
                    expectCommand = ShellTokenizer.prefixCommands.contains(text)
                }
            }
        }

        /// Emits the unquoted stretch `[from, i)` in the word's role.
        private mutating func flush(from: Int, role: Role, first: inout Bool, wordStart: Int) {
            defer { first = false }
            guard i > from else { return }
            switch role {
            case .command:
                emit(.command, from, i)
            case .flag:
                // `--name=value`: the flag is the part up to the `=`.
                if first, let equals = (from..<i).first(where: { u[$0] == Ch.eq }) {
                    emit(.flag, from, equals + 1)
                } else {
                    emit(.flag, from, i)
                }
            case .plain:
                break
            }
        }

        /// The index of the `=` if a `NAME=` assignment starts at `start`.
        private func assignmentEquals(at start: Int) -> Int? {
            guard start < u.count, ShellTokenizer.isIdentifierStart(u[start]) else { return nil }
            var j = start + 1
            while j < u.count, ShellTokenizer.isIdentifierPart(u[j]) { j += 1 }
            return j < u.count && u[j] == Ch.eq ? j : nil
        }

        /// `i` is on the opening quote. Variables inside stay variables.
        private mutating func doubleQuoted() {
            var runStart = i
            i += 1
            while i < u.count {
                let c = u[i]
                if c == Ch.backslash {
                    i = min(i + 2, u.count)
                    continue
                }
                if c == Ch.dquote {
                    i += 1
                    emit(.string, runStart, i)
                    return
                }
                if c == Ch.dollar, let end = variableEnd(at: i) {
                    emit(.string, runStart, i)
                    emit(.variable, i, end)
                    i = end
                    runStart = i
                    continue
                }
                i += 1
            }
            emit(.string, runStart, i)
        }

        /// The end of the variable reference starting at `$`, or nil if it is
        /// not one — `$(` is a command, and a bare `$` is just a character.
        private func variableEnd(at index: Int) -> Int? {
            guard index + 1 < u.count else { return nil }
            let next = u[index + 1]
            if next == Ch.lbrace {
                var j = index + 2
                while j < u.count, u[j] != Ch.rbrace { j += 1 }
                return j < u.count ? j + 1 : j
            }
            if ShellTokenizer.isIdentifierStart(next) {
                var j = index + 2
                while j < u.count, ShellTokenizer.isIdentifierPart(u[j]) { j += 1 }
                return j
            }
            if ShellTokenizer.isDigit(next) { return index + 2 }
            switch next {
            case 0x3F, 0x24, 0x21, 0x40, 0x2A, 0x23, Ch.minus:   // ? $ ! @ * # -
                return index + 2
            default:
                return nil
            }
        }
    }
}
