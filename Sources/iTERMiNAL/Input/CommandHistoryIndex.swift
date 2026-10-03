import Foundation

/// Every command the composer can recall, newest first, ready to be searched
/// and to complete what is being typed.
///
/// Held in memory for as long as it is wanted and never written anywhere.
/// Only single-line commands are indexed: the ghost suggestion completes the
/// line being typed, and a search row shows one line.
struct CommandHistoryIndex {
    struct Entry {
        let command: String
        fileprivate let characters: [Character]
        fileprivate let folded: [Character]
    }

    /// A search result: the command, and which of its characters matched.
    struct Hit: Equatable {
        var command: String
        var indices: [Int]
    }

    private(set) var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }

    /// - Parameters:
    ///   - composer: what this composer has run, **oldest first** — the order
    ///     `WorkspaceStore.composerHistory` keeps it in.
    ///   - shell: the shell's own history, **newest first** — what
    ///     `ShellHistory.search` returns.
    ///
    /// A command in both lists is kept once, at its newest position.
    init(composer: [String], shell: [String], limit: Int = 5_000) {
        var seen = Set<String>()
        for command in Array(composer.reversed()) + shell {
            guard entries.count < limit else { break }
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.contains("\n"), seen.insert(trimmed).inserted else { continue }
            let characters = Array(trimmed)
            entries.append(Entry(command: trimmed, characters: characters, folded: characters.map { FuzzyMatcher.fold($0) }))
        }
    }

    /// The rest of the newest command that starts with what has been typed —
    /// what a shell greys out after the caret. Nil when nothing starts with it,
    /// when the text is empty or spans lines, or when the only match is the
    /// text itself.
    func completion(for text: String) -> String? {
        guard !text.contains("\n"), !text.allSatisfy(\.isWhitespace) else { return nil }
        let length = text.count
        for entry in entries where entry.command.hasPrefix(text) && entry.characters.count > length {
            return String(entry.command.dropFirst(length))
        }
        return nil
    }

    /// The best matches for a query, best first and, among equals, newest
    /// first. An empty query lists the newest.
    func search(_ query: String, limit: Int) -> [Hit] {
        let needle = FuzzyMatcher.needle(query)
        guard !needle.isEmpty else {
            return entries.prefix(limit).map { Hit(command: $0.command, indices: []) }
        }
        var found: [(score: Int, recency: Int, hit: Hit)] = []
        for (recency, entry) in entries.enumerated() {
            guard let match = FuzzyMatcher.match(needle: needle, folded: entry.folded, original: entry.characters) else { continue }
            found.append((match.score, recency, Hit(command: entry.command, indices: match.indices)))
        }
        found.sort { $0.score != $1.score ? $0.score > $1.score : $0.recency < $1.recency }
        return found.prefix(limit).map(\.hit)
    }
}
