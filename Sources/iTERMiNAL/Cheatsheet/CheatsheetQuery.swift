import Foundation

/// How the search field's text is read.
enum CheatSearchMode: String, CaseIterable, Identifiable {
    /// Decided from the text: letters for a short or symbolic query, meaning
    /// for a sentence.
    case auto
    /// The letters typed, in order, as in fzf: "gcm" finds `git commit -m`.
    case fuzzy
    /// The words typed, by what they mean: "undo my last commit" finds
    /// `git reset --soft HEAD~1`.
    case natural

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .fuzzy: return "Letters"
        case .natural: return "Words"
        }
    }
}

enum CheatQuery {
    /// What a query is searched as, once `auto` has been decided.
    enum Resolved: Equatable {
        case fuzzy
        case natural
    }

    static func resolve(_ text: String, mode: CheatSearchMode) -> Resolved {
        switch mode {
        case .fuzzy: return .fuzzy
        case .natural: return .natural
        case .auto: return looksLikeSentence(text) ? .natural : .fuzzy
        }
    }

    /// Whether the text is a sentence rather than a few letters of a command.
    ///
    /// One word is letters: a program's name, or its initials. Anything with a
    /// flag, a path or a variable in it is a command being recalled. Three words
    /// or more is a sentence. Two words are a sentence when one of them is one a
    /// sentence is made of — "kill port", "undo commit" — and letters when
    /// neither is, as in "docker ps". A word of three letters or fewer does not
    /// count towards that: `ps`, `rm`, `du` and `ls` are in the families of words
    /// for what they do, but written alone they are the commands.
    static func looksLikeSentence(_ text: String) -> Bool {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count >= 2 else { return false }
        if text.contains(where: { "-/.~=$_{}\\".contains($0) }) { return false }
        if words.count >= 3 { return true }
        return words.contains { word in
            let lower = word.lowercased()
            return CheatText.stopwords.contains(lower) || (lower.count > 3 && CheatSynonyms.knows(CheatText.stem(lower)))
        }
    }
}

/// Words, for matching by meaning.
enum CheatText {
    /// A word in a text, where it is: `Character` offsets, end not included.
    struct Token: Equatable {
        var text: String
        var start: Int
        var end: Int
    }

    /// Letters and digits, lower-cased, with everything else a gap. "cherry-pick"
    /// is two words, and so is `--soft`'s "soft" and the "tar" of `tar.gz`.
    static func tokens(_ characters: [Character]) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var start = 0
        for (offset, character) in characters.enumerated() {
            if character.isLetter || character.isNumber {
                if current.isEmpty { start = offset }
                current += character.lowercased()
            } else if !current.isEmpty {
                tokens.append(Token(text: current, start: start, end: offset))
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(Token(text: current, start: start, end: characters.count)) }
        return tokens
    }

    static func words(_ text: String) -> [String] {
        tokens(Array(text)).map(\.text)
    }

    /// A word with its ending taken off, so that "delete", "deletes", "deleted" and
    /// "deleting" are one word, and "file" and "files". It need not be a word itself,
    /// only the same thing for the same family, on both sides of a match.
    static func stem(_ word: String) -> String {
        guard word.count > 3 else { return word }
        var root = word
        if word.hasSuffix("ies"), word.count > 4 {
            root = String(word.dropLast(3)) + "y"
        } else if word.hasSuffix("ing"), word.count - 3 >= 3 {
            root = String(word.dropLast(3))
        } else if word.hasSuffix("ed"), word.count - 2 >= 3 {
            root = String(word.dropLast(2))
        } else if word.hasSuffix("es"), word.count - 2 >= 3,
                  ["s", "x", "z", "ch", "sh"].contains(where: { word.dropLast(2).hasSuffix($0) }) {
            root = String(word.dropLast(2))                        // boxes, matches, processes
        } else if word.hasSuffix("s"), !word.hasSuffix("ss"), word.count - 1 >= 3 {
            root = String(word.dropLast(1))                        // files, types, deletes
        }
        // The "e" that "delete" has and "deleting" has not.
        if root.count > 3, root.hasSuffix("e") { root = String(root.dropLast(1)) }
        return root
    }

    /// Words that carry no meaning of their own in a question.
    static let stopwords: Set<String> = [
        "a", "an", "the", "i", "me", "my", "we", "you", "your", "to", "of", "in", "on", "at", "for",
        "from", "into", "onto", "by", "with", "how", "do", "does", "did", "can", "could", "would",
        "should", "want", "need", "like", "please", "is", "are", "be", "it", "its", "this", "that",
        "these", "those", "some", "any", "and", "or", "what", "which", "when", "where", "way",
        "using", "use", "so", "all",
    ]

    /// The stems a query is made of, in order, once the words that mean nothing
    /// are gone and repeats are made one.
    static func queryTerms(_ query: String) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for word in words(query) where !stopwords.contains(word) {
            let root = stem(word)
            if seen.insert(root).inserted { terms.append(root) }
        }
        return terms
    }
}
