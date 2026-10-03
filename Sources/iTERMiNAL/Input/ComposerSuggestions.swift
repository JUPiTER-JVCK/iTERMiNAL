import SwiftUI

/// What the composer offers beside the text being typed: the rest of a
/// remembered command as a ghost after the caret, and a list for searching
/// history (⌃R) or choosing between files (Tab).
///
/// All of it is advice. Nothing here runs a command, and choosing a row only
/// changes the text in the field — Return in the field is still the only way
/// anything is sent.
///
/// The history it draws on lives in memory for as long as this object does. It
/// is never saved, exported, or sent anywhere.
///
/// The decisions are `SuggestionState`'s, which the logic checks drive. This
/// is the SwiftUI side: the history read from disk, and the editor.
final class ComposerSuggestions: ObservableObject {
    typealias Mode = SuggestionState.Mode
    typealias Replacement = SuggestionState.Replacement
    typealias Row = SuggestionState.Row
    typealias Key = SuggestionState.Key

    @Published private var state = SuggestionState()

    var mode: Mode? { state.mode }
    var rows: [Row] { state.rows }
    var hiddenCount: Int { state.hiddenCount }
    var selected: Int { state.selected }

    /// Where the caret is, in UTF-16 units, as the editor last reported it.
    /// Plain rather than published: it moves on every keystroke and nothing
    /// draws from it.
    var caret = 0
    /// Where the command would run, if this Mac can see it. Nil for a remote
    /// session, whose files are not here to complete.
    var directory: () -> String? = { nil }
    /// Puts a replacement into the field. Set by the editor.
    var apply: ((Replacement) -> Void)?
    /// True while the pointer is over the list, so clicking a row is not
    /// mistaken for the field losing focus.
    var pointerInside = false

    private var composerHistory: [String] = []
    private var shellHistory: [String] = []
    private var readsShellHistory = false
    private var loadingShellHistory = false
    /// The ghost for the last text asked about. The card redraws for reasons
    /// that have nothing to do with the text, and working a ghost out means
    /// looking through every remembered command.
    private var ghostCache: (text: String, completion: String)?

    // MARK: History sources

    func start(composerHistory: [String], readsShellHistory: Bool) {
        self.composerHistory = composerHistory
        self.readsShellHistory = readsShellHistory
        rebuildIndex()
        if readsShellHistory { reloadShellHistory() }
    }

    func setComposerHistory(_ history: [String]) {
        guard history != composerHistory else { return }
        composerHistory = history
        rebuildIndex()
    }

    func setReadsShellHistory(_ reads: Bool) {
        guard reads != readsShellHistory else { return }
        readsShellHistory = reads
        if reads {
            reloadShellHistory()
        } else {
            shellHistory = []
            rebuildIndex()
        }
    }

    /// Reads the shell's history file again, off the main thread. Cheap, and
    /// the file may have grown since it was last read.
    func reloadShellHistory() {
        guard readsShellHistory, !loadingShellHistory else { return }
        loadingShellHistory = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let commands = ShellHistory.search()
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingShellHistory = false
                // The switch may have been turned off while the file was read.
                guard self.readsShellHistory else { return }
                self.shellHistory = commands
                self.rebuildIndex()
            }
        }
    }

    private func rebuildIndex() {
        ghostCache = nil
        state.setIndex(CommandHistoryIndex(composer: composerHistory, shell: shellHistory))
    }

    // MARK: Ghost

    func ghost(for text: String) -> String {
        guard state.mode == nil, state.dismissedGhost != text else { return "" }
        if let cache = ghostCache, cache.text == text { return cache.completion }
        let completion = state.ghost(for: text)
        ghostCache = (text, completion)
        return completion
    }

    // MARK: Following the editor

    func refresh(text: String, caret: Int) {
        self.caret = caret
        // Nothing to do, and nothing to publish, unless a list is open or a
        // ghost was dismissed for other text.
        guard state.mode != nil || state.dismissedGhost != nil else { return }
        state.refresh(text: text, caret: caret, directory: directory())
    }

    /// Returns whether the key was used; false leaves it to the text view.
    func handle(_ key: Key, text: String, caret: Int) -> Bool {
        self.caret = caret
        let outcome = state.handle(key, text: text, caret: caret, directory: directory())
        if key == .historySearch { reloadShellHistory() }
        if let replacement = outcome.replacement { apply?(replacement) }
        return outcome.consumed
    }

    func choose(_ row: Row?) {
        pointerInside = false
        if let replacement = state.choose(row) { apply?(replacement) }
    }

    func close() {
        pointerInside = false
        // Called on every send and whenever the card goes away: publishing for
        // a list that is not open would redraw the card for nothing.
        guard state.mode != nil else { return }
        state.close()
    }
}
