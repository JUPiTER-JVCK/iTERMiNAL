import Foundation

/// What Tab can complete the word at the caret to.
struct PathCompletion: Equatable {
    struct Candidate: Equatable {
        /// The file's own name.
        var name: String
        var isDirectory: Bool
        /// What the word becomes if this one is chosen: escaped for the shell,
        /// the directory typed so far kept as it was, a `/` after a directory
        /// and a closing quote after a file in quotes.
        var insertion: String
    }

    /// UTF-16 range of the word being completed, the unit `NSRange` uses.
    var range: Range<Int>
    /// The first `PathCompleter.maxCandidates` matches, in order.
    var candidates: [Candidate]
    /// How many things match in all, which is more than `candidates` holds when
    /// a directory has more matches than are worth listing.
    var matchCount: Int
    /// What the word becomes when every match shares more than has been typed —
    /// the part a shell fills in before it lists anything. Worked out from all
    /// the matches, not just the ones kept. Nil when they share nothing further,
    /// and always nil for a single match.
    var sharedInsertion: String?
}

/// Completes file and directory names for the composer's Tab key.
///
/// Only for places this Mac can read, so the caller passes no working directory
/// for a remote session, and a relative path then completes to nothing.
enum PathCompleter {
    static let maxCandidates = 100

    /// Nil when there is nothing to offer: the word is not a path (a command
    /// name, a flag, a variable), the directory cannot be read, or nothing in
    /// it starts with what has been typed.
    static func complete(
        text: String,
        caret: Int,
        workingDirectory: String?,
        home: String = NSHomeDirectory()
    ) -> PathCompletion? {
        let units = Array(text.utf16)
        let caret = min(max(caret, 0), units.count)
        let (start, openQuote) = scan(units, upTo: caret)
        let word = Array(units[start..<caret])

        // What has been typed of the name, with the shell's escaping undone.
        let content: String
        var quote: UInt16?
        if let open = openQuote {
            // The quote must be what the word began with: `a"b` is not
            // something to complete inside.
            guard word.first == open else { return nil }
            quote = open
            let inside = String(decoding: word.dropFirst(), as: UTF16.self)
            content = open == Unit.doubleQuote ? unescapeDoubleQuoted(inside) : inside
        } else {
            var plain: [UInt16] = []
            var index = 0
            while index < word.count {
                let unit = word[index]
                if unit == Unit.backslash {
                    if index + 1 < word.count { plain.append(word[index + 1]) }
                    index += 2
                    continue
                }
                // A closed quote earlier in the word: not worth guessing at.
                if unit == Unit.singleQuote || unit == Unit.doubleQuote { return nil }
                plain.append(unit)
                index += 1
            }
            content = String(decoding: plain, as: UTF16.self)
        }

        // Flags and variables are not file names.
        if content.hasPrefix("-") || content.hasPrefix("$") { return nil }

        // The first word of a command names a command, which is not this
        // completer's to finish — unless it is plainly a path.
        let tokens = ShellTokenizer.tokenize(text)
        let atCommand = word.isEmpty
            ? isCommandPosition(after: start, tokens: tokens, units: units)
            : tokens.contains { $0.kind == .command && $0.range.lowerBound == start }
        if atCommand, !(content.contains("/") || content.hasPrefix(".") || content.hasPrefix("~")) {
            return nil
        }

        if quote == nil {
            if content == "~" {
                let tilde = PathCompletion.Candidate(name: "~", isDirectory: true, insertion: "~/")
                return PathCompletion(range: start..<caret, candidates: [tilde], matchCount: 1, sharedInsertion: nil)
            }
            // `~user` would need the account database.
            if content.hasPrefix("~"), !content.hasPrefix("~/") { return nil }
        }

        let slash = content.lastIndex(of: "/")
        let directoryPart = slash.map { String(content[...$0]) } ?? ""
        let prefix = slash.map { String(content[content.index(after: $0)...]) } ?? content

        guard let directory = resolve(directoryPart, quoted: quote != nil, workingDirectory: workingDirectory, home: home),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }

        let visible = names.filter { prefix.hasPrefix(".") || !$0.hasPrefix(".") }
        var matches = visible.filter { $0.hasPrefix(prefix) }
        // Case is taken literally first, as a shell does; only when that finds
        // nothing does a differently-cased name count, which is how this Mac's
        // file system treats them anyway.
        if matches.isEmpty, !prefix.isEmpty {
            let folded = prefix.lowercased()
            matches = visible.filter { $0.lowercased().hasPrefix(folded) }
        }
        // A single quote cannot be written inside single quotes.
        if quote == Unit.singleQuote { matches.removeAll { $0.contains("'") } }
        guard !matches.isEmpty else { return nil }

        matches.sort { lhs, rhs in
            let (a, b) = (lhs.lowercased(), rhs.lowercased())
            return a != b ? a < b : lhs < rhs
        }

        let render = Renderer(quote: quote, directoryPart: directoryPart)

        // What they share comes from every match: a name past the cut that
        // diverges earlier would otherwise be left out of it, and Tab would
        // fill in a prefix that excludes real files. Only what is kept for
        // listing is cut, and only those need asking the file system about.
        var shared: String?
        if matches.count > 1 {
            let common = commonPrefix(of: matches)
            if common.count > prefix.count, common.hasPrefix(prefix) {
                shared = render.partial(common)
            }
        }
        let candidates = matches.prefix(maxCandidates).map { name -> PathCompletion.Candidate in
            let isDir = isDirectory(directory, name)
            return PathCompletion.Candidate(name: name, isDirectory: isDir, insertion: render.insertion(name, isDirectory: isDir))
        }
        return PathCompletion(range: start..<caret, candidates: candidates, matchCount: matches.count, sharedInsertion: shared)
    }

    // MARK: The word at the caret

    /// Where the word the caret is in begins, and the quote it is still
    /// inside, if any. An empty word at the caret begins at the caret.
    private static func scan(_ units: [UInt16], upTo caret: Int) -> (start: Int, quote: UInt16?) {
        var start = caret
        var inWord = false
        var quote: UInt16?
        var index = 0
        while index < caret {
            let unit = units[index]
            if let open = quote {
                if unit == open {
                    quote = nil
                } else if unit == Unit.backslash, open == Unit.doubleQuote, index + 1 < caret {
                    index += 1
                }
            } else if Unit.breaks.contains(unit) {
                inWord = false
            } else {
                if !inWord {
                    inWord = true
                    start = index
                }
                if unit == Unit.backslash {
                    index += 1
                } else if unit == Unit.singleQuote || unit == Unit.doubleQuote {
                    quote = unit
                }
            }
            index += 1
        }
        return (inWord ? start : caret, quote)
    }

    /// Whether a word that has not been started yet would be the first of a
    /// command. A typed word shows itself to the tokenizer as a command token;
    /// an empty one has nothing to show, so what comes before it decides: the
    /// start of the line, or an operator that begins a command (`|`, `&&`, `;`,
    /// `$(`, `then`) rather than one that takes a file (`>`, `<<`).
    private static func isCommandPosition(after start: Int, tokens: [ShellToken], units: [UInt16]) -> Bool {
        guard let last = tokens.last(where: { $0.range.upperBound <= start }) else { return true }
        guard last.kind == .op else { return false }
        let op = String(decoding: units[last.range], as: UTF16.self)
        if op.hasSuffix("(") { return true }
        return !(op.contains("<") || op.contains(">"))
    }

    private static func unescapeDoubleQuoted(_ text: String) -> String {
        var result = ""
        var escaping = false
        for character in text {
            if escaping {
                if !"\"\\$`".contains(character) { result.append("\\") }
                result.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        if escaping { result.append("\\") }
        return result
    }

    // MARK: Files

    private static func resolve(_ directoryPart: String, quoted: Bool, workingDirectory: String?, home: String) -> String? {
        if !quoted, directoryPart.hasPrefix("~/") {
            return home + "/" + String(directoryPart.dropFirst(2))
        }
        if directoryPart.hasPrefix("/") { return directoryPart }
        guard let workingDirectory else { return nil }
        return directoryPart.isEmpty ? workingDirectory : workingDirectory + "/" + directoryPart
    }

    private static func isDirectory(_ directory: String, _ name: String) -> Bool {
        var isDirectory: ObjCBool = false
        let path = directory.hasSuffix("/") ? directory + name : directory + "/" + name
        // Follows a symlink, so a link to a directory completes like one.
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func commonPrefix(of names: [String]) -> String {
        guard let first = names.first else { return "" }
        var common = Array(first)
        for name in names.dropFirst() {
            let characters = Array(name)
            var length = 0
            while length < common.count, length < characters.count, common[length] == characters[length] {
                length += 1
            }
            common = Array(common[..<length])
        }
        return String(common)
    }

    // MARK: Writing a word back

    /// Turns names back into text the shell reads as those names.
    private struct Renderer {
        let quote: UInt16?
        let directoryPart: String

        private var quoteString: String? {
            quote.map { String(decoding: [$0], as: UTF16.self) }
        }

        /// A complete choice: a directory ends in `/`, a file in quotes gets its
        /// closing quote.
        func insertion(_ name: String, isDirectory: Bool) -> String {
            let tail = isDirectory ? "/" : (quoteString ?? "")
            return partial(name) + tail
        }

        /// The word so far, ending in `name`, with no closing text.
        func partial(_ name: String) -> String {
            if let quote, let quoteString {
                return quoteString + escapeQuoted(directoryPart, in: quote) + escapeQuoted(name, in: quote)
            }
            if directoryPart.hasPrefix("~/") {
                return "~/" + escape(String(directoryPart.dropFirst(2)), atWordStart: false) + escape(name, atWordStart: false)
            }
            return escape(directoryPart + name, atWordStart: true)
        }

        private static let special = Set(" \t\n\\'\"`$&;|<>()*?[]{}!#")

        private func escape(_ text: String, atWordStart: Bool) -> String {
            var result = ""
            for (offset, character) in text.enumerated() {
                if Self.special.contains(character) || (atWordStart && offset == 0 && character == "~") {
                    result.append("\\")
                }
                result.append(character)
            }
            return result
        }

        /// Inside double quotes only a few characters keep their meaning;
        /// inside single quotes none do.
        private func escapeQuoted(_ text: String, in quote: UInt16) -> String {
            guard quote == Unit.doubleQuote else { return text }
            var result = ""
            for character in text {
                if "\"\\$`".contains(character) { result.append("\\") }
                result.append(character)
            }
            return result
        }
    }

    private enum Unit {
        static let backslash = UInt16(0x5C)
        static let singleQuote = UInt16(0x27)
        static let doubleQuote = UInt16(0x22)
        /// What ends a word outside quotes: blanks, and the characters that
        /// begin a new command or a redirection.
        static let breaks: Set<UInt16> = [
            0x20, 0x09, 0x0A, 0x0D,         // space, tab, newline, return
            0x7C, 0x26, 0x3B,               // | & ;
            0x3C, 0x3E, 0x28, 0x29, 0x60,   // < > ( ) `
        ]
    }
}
