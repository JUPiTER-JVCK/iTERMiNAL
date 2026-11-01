import Foundation

/// Closing brackets and quotes for the composer, and the shell-aware scan of a
/// command line that decides when not to. Foundation only, so the rules are
/// checked off a Mac; `CommandTextView` reads the caret and makes the edit.
///
/// A command line is not prose. A quote typed inside another kind of quote is
/// a letter, an apostrophe in a word is not an opening quote, and a bracket in
/// a comment is nothing at all — so a pair is only typed where the shell would
/// read the opener as one.
enum AutoPairing {
    /// Where in the shell's quoting the end of some text is.
    enum QuoteState: Equatable {
        case none
        case single
        case double
        case backtick
        /// After a `#` that starts a comment, up to the end of the line.
        case comment
    }

    /// What reading a command line left open.
    struct Scan: Equatable {
        var state: QuoteState
        /// Brackets opened and not yet closed, outermost first. Only those
        /// outside any quote, comment or escape.
        var open: [Character]
        /// The text ends in a backslash outside single quotes, which asks the
        /// shell for another line.
        var endsWithBackslash: Bool
    }

    /// What typing a character does.
    enum Edit: Equatable {
        /// Type it as it is.
        case plain
        /// Type it and its closer, with the caret between.
        case pair
        /// Its closer is already next: move past it instead of typing another.
        case stepOver
    }

    static let closers: [Character: Character] = [
        "(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`",
    ]

    /// What is next to the caret that leaves room for a pair: nothing, a space,
    /// or something that already ends a word or a group.
    private static let roomAfter: Set<Character> = [")", "]", "}", ";", "|", "&", ","]
    /// Where a `#` starts a comment: at the start of a word.
    private static let beforeComment: Set<Character> = [";", "|", "&", "("]

    // MARK: Scanning

    static func scan(_ text: String) -> Scan {
        let characters = Array(text)
        var state = QuoteState.none
        var open: [Character] = []
        var endsWithBackslash = false
        var previous: Character?
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch state {
            case .none:
                switch character {
                case "\\":
                    if index == characters.count - 1 { endsWithBackslash = true }
                    index += 1   // the next character is a letter, whatever it is
                case "'": state = .single
                case "\"": state = .double
                case "`": state = .backtick
                case "#":
                    if previous == nil || previous!.isWhitespace || beforeComment.contains(previous!) {
                        state = .comment
                    }
                case "(", "[", "{": open.append(character)
                case ")", "]", "}":
                    if let last = open.last, closers[last] == character { open.removeLast() }
                default: break
                }
            case .single:
                if character == "'" { state = .none }
            case .double:
                if character == "\\" {
                    if index == characters.count - 1 { endsWithBackslash = true }
                    index += 1
                } else if character == "\"" {
                    state = .none
                }
            case .backtick:
                if character == "\\" {
                    if index == characters.count - 1 { endsWithBackslash = true }
                    index += 1
                } else if character == "`" {
                    state = .none
                }
            case .comment:
                if character == "\n" { state = .none }
            }
            previous = character
            index += 1
        }
        return Scan(state: state, open: open, endsWithBackslash: endsWithBackslash)
    }

    // MARK: Typing

    /// What typing `typed` does, with `before` and `after` the caret and nothing
    /// selected.
    static func edit(typing typed: Character, before: String, after: String) -> Edit {
        let state = scan(before).state
        let next = after.first
        let previous = before.last
        let hasRoom = next == nil || next!.isWhitespace || roomAfter.contains(next!)

        switch typed {
        case ")", "]", "}":
            // A closer that is already there is stepped over — except in a
            // single-quoted string or a comment, where it is only a letter.
            guard state != .single, state != .comment else { return .plain }
            return next == typed ? .stepOver : .plain

        case "\"", "'", "`":
            let closes: QuoteState = typed == "\"" ? .double : (typed == "'" ? .single : .backtick)
            if state == closes {
                return next == typed ? .stepOver : .plain
            }
            // Inside a different quote, or a comment, it is a letter.
            guard state == .none else { return .plain }
            // Escaped, or the apostrophe in a word (don't, it's).
            if previous == "\\" { return .plain }
            if typed == "'", let previous, previous.isLetter || previous.isNumber { return .plain }
            return hasRoom ? .pair : .plain

        case "(", "[", "{":
            switch state {
            case .none:
                return hasRoom ? .pair : .plain
            case .double, .backtick:
                // `$(` and `${` still mean something inside double quotes.
                return previous == "$" && hasRoom ? .pair : .plain
            case .single, .comment:
                return .plain
            }

        default:
            return .plain
        }
    }

    /// Whether backspace with the caret between `before` and `after` should
    /// remove an opener and the closer typed for it together: the character
    /// before is an opener, the one after is its closer, and the opener really
    /// is one.
    static func deletesPair(before: String, after: String) -> Bool {
        guard let opener = before.last, let closer = after.first, closers[opener] == closer else { return false }
        let earlier = String(before.dropLast())
        let scanned = scan(earlier)
        switch opener {
        case "\"", "'", "`":
            // The quote before the caret opened a string only if nothing was
            // open before it; otherwise it closed one, and the quote after is
            // the next string's.
            return scanned.state == .none && earlier.last != "\\"
        default:
            return scanned.state != .single && scanned.state != .comment
        }
    }
}
