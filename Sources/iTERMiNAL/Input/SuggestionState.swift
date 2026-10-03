import Foundation

/// What the composer's suggestions are doing at any moment, and how each key
/// changes it. Foundation only, so it can be driven by the logic checks.
///
/// `ComposerSuggestions` wraps this for SwiftUI and carries what has to live
/// outside it: the editor, the pointer, and the history read from disk.
///
/// A key never runs anything. The most it does is hand back a `Replacement` for
/// the editor to put into the field.
struct SuggestionState {
    enum Mode: Equatable {
        case history
        case path
    }

    /// Text to put into the field: all of it when `range` is nil, otherwise just
    /// that UTF-16 range.
    struct Replacement: Equatable {
        var range: NSRange?
        var text: String
    }

    struct Row: Identifiable, Equatable {
        let id: Int
        let text: String
        /// `Character` offsets into `text` to emphasise: what the search matched.
        let emphasized: Set<Int>
        let isDirectory: Bool
        let replacement: Replacement
    }

    /// The keys the editor hands over. `tab` and `historySearch` open or act on
    /// the list; the rest only mean something while one is open, or — `dismiss`
    /// — while a ghost is showing.
    enum Key {
        case up, down, accept, dismiss, tab, historySearch
    }

    struct Outcome: Equatable {
        /// False leaves the key to the text view.
        var consumed: Bool
        var replacement: Replacement?
    }

    static let maxRows = 8

    private(set) var mode: Mode?
    private(set) var rows: [Row] = []
    /// Candidates beyond the rows shown, so the list can say there are more.
    private(set) var hiddenCount = 0
    private(set) var selected = 0
    /// The text a ghost was waved away for. It stays gone for exactly that
    /// text, and comes back as soon as the text changes.
    private(set) var dismissedGhost: String?
    private(set) var index = CommandHistoryIndex(composer: [], shell: [])
    private var queryText = ""

    // MARK: History

    mutating func setIndex(_ newIndex: CommandHistoryIndex) {
        index = newIndex
        if mode == .history {
            rows = historyRows(for: queryText)
            clampSelection()
        }
    }

    // MARK: Ghost

    /// The rest of a remembered command, to show after `text`. Empty while a
    /// list is open, after it has been dismissed for this text, or when
    /// nothing remembered starts with it.
    func ghost(for text: String) -> String {
        guard mode == nil, dismissedGhost != text else { return "" }
        return index.completion(for: text) ?? ""
    }

    // MARK: Following the editor

    /// The text or caret changed. Only a list that is open has anything to
    /// follow.
    mutating func refresh(text: String, caret: Int, directory: String?) {
        queryText = text
        if let dismissed = dismissedGhost, dismissed != text { dismissedGhost = nil }
        switch mode {
        case .none:
            break
        case .history:
            rows = historyRows(for: text)
            hiddenCount = 0
            clampSelection()
        case .path:
            guard let directory,
                  let completion = PathCompleter.complete(text: text, caret: caret, workingDirectory: directory),
                  !completion.candidates.isEmpty else {
                close()
                return
            }
            let (shown, hidden) = pathRows(completion)
            rows = shown
            hiddenCount = hidden
            clampSelection()
        }
    }

    // MARK: Keys

    /// `directory` is where the command would run, nil when this Mac cannot see
    /// it — a remote session — in which case there are no files to complete.
    mutating func handle(_ key: Key, text: String, caret: Int, directory: String?) -> Outcome {
        queryText = text
        switch key {
        case .historySearch:
            if mode == .history {
                move(by: 1)
            } else {
                open(.history, rows: historyRows(for: text), hidden: 0)
            }
            return Outcome(consumed: true, replacement: nil)

        case .up:
            guard mode != nil else { return Outcome(consumed: false, replacement: nil) }
            move(by: -1)
            return Outcome(consumed: true, replacement: nil)

        case .down:
            guard mode != nil else { return Outcome(consumed: false, replacement: nil) }
            move(by: 1)
            return Outcome(consumed: true, replacement: nil)

        case .accept:
            guard mode != nil else { return Outcome(consumed: false, replacement: nil) }
            return Outcome(consumed: true, replacement: choose(rows.indices.contains(selected) ? rows[selected] : nil))

        case .dismiss:
            if mode != nil {
                close()
            } else {
                dismissedGhost = text
            }
            return Outcome(consumed: true, replacement: nil)

        case .tab:
            // With a list open, Tab chooses from it like Return does.
            if mode != nil {
                return Outcome(consumed: true, replacement: choose(rows.indices.contains(selected) ? rows[selected] : nil))
            }
            // Otherwise Tab never types a tab into a command line, whether or
            // not there was anything to complete.
            return Outcome(consumed: true, replacement: completePath(text: text, caret: caret, directory: directory))
        }
    }

    /// Closes the list, and returns what choosing `row` puts into the field.
    mutating func choose(_ row: Row?) -> Replacement? {
        close()
        return row?.replacement
    }

    mutating func close() {
        guard mode != nil else { return }
        mode = nil
        rows = []
        hiddenCount = 0
        selected = 0
    }

    // MARK: Lists

    private mutating func open(_ newMode: Mode, rows newRows: [Row], hidden: Int) {
        rows = newRows
        hiddenCount = hidden
        selected = 0
        mode = newMode
    }

    private mutating func move(by delta: Int) {
        guard !rows.isEmpty else { return }
        selected = min(max(selected + delta, 0), rows.count - 1)
    }

    private mutating func clampSelection() {
        selected = rows.isEmpty ? 0 : min(selected, rows.count - 1)
    }

    private func historyRows(for query: String) -> [Row] {
        index.search(query, limit: Self.maxRows).enumerated().map { offset, hit in
            Row(
                id: offset,
                text: hit.command,
                emphasized: Set(hit.indices),
                isDirectory: false,
                replacement: Replacement(range: nil, text: hit.command)
            )
        }
    }

    // MARK: Paths

    /// A single candidate, or what several share, is put straight into the
    /// text, as a shell does; the next Tab then lists what is left to choose
    /// between. Returns that replacement, or nil if it opened a list or found
    /// nothing.
    private mutating func completePath(text: String, caret: Int, directory: String?) -> Replacement? {
        guard let directory,
              let completion = PathCompleter.complete(text: text, caret: caret, workingDirectory: directory) else {
            return nil
        }
        let range = NSRange(location: completion.range.lowerBound, length: completion.range.count)
        if completion.candidates.count == 1 {
            return Replacement(range: range, text: completion.candidates[0].insertion)
        }
        if let shared = completion.sharedInsertion {
            return Replacement(range: range, text: shared)
        }
        let (shown, hidden) = pathRows(completion)
        open(.path, rows: shown, hidden: hidden)
        return nil
    }

    private func pathRows(_ completion: PathCompletion) -> ([Row], Int) {
        let range = NSRange(location: completion.range.lowerBound, length: completion.range.count)
        let shown = completion.candidates.prefix(Self.maxRows).enumerated().map { offset, candidate in
            Row(
                id: offset,
                text: candidate.name + (candidate.isDirectory ? "/" : ""),
                emphasized: [],
                isDirectory: candidate.isDirectory,
                replacement: Replacement(range: range, text: candidate.insertion)
            )
        }
        return (shown, max(0, completion.candidates.count - Self.maxRows))
    }
}
