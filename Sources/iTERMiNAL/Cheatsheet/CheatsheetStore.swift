import SwiftUI

/// What the Cheatsheet page shows: the library, what has been typed in the
/// search field, what that found, and which program is open.
///
/// Held for the life of the app, so the page opens where it was left. A search
/// runs off the main thread and a newer one makes an older one's answer
/// stale, so typing is never held up by the one before it.
final class CheatsheetStore: ObservableObject {
    static let shared = CheatsheetStore()

    /// A program as the list on the left shows it.
    struct Row: Equatable, Identifiable {
        var name: String
        var summary: String
        /// How many of its examples matched; 0 when nothing is being searched.
        var matchCount: Int
        var nameIndices: [Int]

        var id: String { name }
    }

    let library: CheatLibrary
    private let index: CheatIndex
    private let positions: [String: Int]

    @Published var query = "" {
        didSet {
            if query != oldValue { queryChanged() }
        }
    }
    @Published var selectedProgram: String?
    /// The programs in the list, best match first while searching, A to Z
    /// otherwise.
    @Published private(set) var rows: [Row] = []
    @Published private(set) var result = CheatSearchResult()

    private var generation = 0

    init(library: CheatLibrary = CheatsheetCurated.library) {
        self.library = library
        self.index = CheatIndex(library: library)
        var positions: [String: Int] = [:]
        for (i, program) in library.programs.enumerated() { positions[program.name] = i }
        self.positions = positions
        self.rows = Self.allRows(library)
        self.selectedProgram = library.programs.first?.name
    }

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isSearching: Bool { !trimmedQuery.isEmpty }

    /// The open program.
    var selection: CheatProgram? {
        guard let name = selectedProgram, let position = positions[name] else { return nil }
        return library.programs[position]
    }

    /// What the search found inside the open program, best first. Empty when
    /// nothing is being searched, or when the program matched by name alone.
    var hitsInSelection: [CheatHit] {
        guard isSearching, let name = selectedProgram, let position = positions[name] else { return [] }
        return result.hits(inProgram: position)
    }

    /// The command that Return would insert: the open program's best match.
    var bestExampleInSelection: CheatExample? {
        guard let hit = hitsInSelection.first, let program = selection else { return nil }
        return program.examples[hit.example]
    }

    // MARK: Selection

    /// Moves the open program up or down the list, stopping at its ends.
    func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.name == selectedProgram } ?? (delta > 0 ? -1 : rows.count)
        let next = min(max(current + delta, 0), rows.count - 1)
        selectedProgram = rows[next].name
    }

    // MARK: Searching

    private func queryChanged() {
        generation += 1
        let text = trimmedQuery
        guard !text.isEmpty else {
            // Back to the whole list, with the program that was open still open.
            result = CheatSearchResult()
            rows = Self.allRows(library)
            return
        }
        let generation = self.generation
        let index = self.index
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = index.search(text)
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.apply(found)
            }
        }
    }

    private func apply(_ found: CheatSearchResult) {
        result = found
        rows = found.programs.map { hit in
            let program = library.programs[hit.program]
            return Row(name: program.name, summary: program.summary, matchCount: hit.matchCount, nameIndices: hit.nameIndices)
        }
        // As in fzf, the best match is the one under the cursor.
        selectedProgram = rows.first?.name
    }

    private static func allRows(_ library: CheatLibrary) -> [Row] {
        library.programs.map { Row(name: $0.name, summary: $0.summary, matchCount: 0, nameIndices: []) }
    }
}
