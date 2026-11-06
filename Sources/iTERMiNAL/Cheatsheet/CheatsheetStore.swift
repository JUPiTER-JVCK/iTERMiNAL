import SwiftUI

/// What the Cheatsheet page shows: the library, what has been typed in the
/// search field, what that found, and which program is open.
///
/// Held for the life of the app, so the page opens where it was left. The pages
/// written for this app are there at once; tldr-pages' examples are read from the
/// bundle in the background the first time the page opens and join them when they
/// are ready. A search runs off the main thread, and a newer one makes an older
/// one's answer stale, so typing is never held up by the one before it.
final class CheatsheetStore: ObservableObject {
    static let shared = CheatsheetStore()

    /// A program as the list on the left shows it.
    struct Row: Equatable, Identifiable {
        var name: String
        var summary: String
        /// How many of its examples matched; 0 when nothing is being searched.
        var matchCount: Int
        var nameIndices: [Int]
        /// Written for this app, as against only in tldr-pages.
        var isCurated: Bool

        var id: String { name }
    }

    /// Where reading tldr-pages' examples has got to.
    enum TldrStatus: Equatable {
        case notLoaded
        case loading
        case loaded(version: String)
        /// This build has no copy of them, as a local build without `Vendor/` does not.
        case missing
        case failed(String)
    }

    /// Where asking the assistant has got to. Optional, explicit, and never started
    /// by typing.
    enum AskState: Equatable {
        case idle
        /// Choosing which entries to offer it.
        case preparing
        /// Waiting for the person to say yes to exactly this.
        case confirming(CheatsheetAskRequest)
        case asking(question: String)
        case answered(question: String, picks: [CheatsheetAskRequest.Candidate])
        /// No assistant is set up, which is a thing to fix and not an error.
        case notConfigured
        case failed(String)
    }

    /// Where reading a program's manual page has got to.
    enum ManualState: Equatable {
        case loading
        case found(ManPage.Excerpt)
        /// There is no page by that name on this Mac.
        case missing
        case failed(String)
    }

    @Published private(set) var library: CheatLibrary
    private var index: CheatIndex
    private var positions: [String: Int]

    @Published var query = "" {
        didSet {
            if query != oldValue { startSearch() }
        }
    }
    /// Letters, words, or whichever the text looks like.
    @Published var mode: CheatSearchMode = .auto {
        didSet {
            if mode != oldValue { startSearch() }
        }
    }
    @Published var selectedProgram: String?
    /// The programs in the list: best match first while searching; otherwise
    /// the ones written for this app, then the rest, each A to Z.
    @Published private(set) var rows: [Row] = []
    @Published private(set) var result = CheatSearchResult()
    @Published private(set) var tldr: TldrStatus = .notLoaded
    @Published private(set) var ask: AskState = .idle
    /// Each program's manual page on this Mac, for the ones that have been asked for.
    @Published private(set) var manuals: [String: ManualState] = [:]

    private var generation = 0
    private var token = CheatSearchToken()
    private var askTask: Task<Void, Never>?

    init(library: CheatLibrary = CheatsheetCurated.library) {
        self.library = library
        self.index = CheatIndex(library: library)
        self.positions = Self.positions(of: library)
        self.rows = Self.allRows(library)
        self.selectedProgram = library.programs.first?.name
    }

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isSearching: Bool { !trimmedQuery.isEmpty }

    /// What the text is being searched as: the letters or the words.
    var resolvedMode: CheatQuery.Resolved { CheatQuery.resolve(trimmedQuery, mode: mode) }

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

    // MARK: tldr-pages

    /// Reads tldr-pages' examples, once, if this build has them. Called when the
    /// page appears; the work is off the main thread and the page keeps working
    /// with what it has until it is done.
    func loadMoreIfNeeded() {
        guard tldr == .notLoaded else { return }
        tldr = .loading
        let curated = CheatsheetCurated.library.programs
        let url = TldrBundle.dataURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Self.load(curated: curated, from: url)
            DispatchQueue.main.async { self?.finishLoading(outcome) }
        }
    }

    private struct Loaded {
        var library: CheatLibrary
        var index: CheatIndex
        var version: String
    }

    private enum Outcome {
        case loaded(Loaded)
        case missing
        case failed(String)
    }

    private static func load(curated: [CheatProgram], from url: URL?) -> Outcome {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let data = try Data(contentsOf: url)
            let loaded = try TldrData.decode(data)
            let library = CheatLibrary.merging(curated: curated, tldr: loaded.programs)
            return .loaded(Loaded(library: library, index: CheatIndex(library: library), version: loaded.version))
        } catch let failure as TldrData.Failure {
            return .failed(failure.description)
        } catch {
            return .failed("it could not be read")
        }
    }

    private func finishLoading(_ outcome: Outcome) {
        switch outcome {
        case .missing:
            tldr = .missing
        case .failed(let message):
            tldr = .failed(message)
        case .loaded(let loaded):
            library = loaded.library
            index = loaded.index
            positions = Self.positions(of: loaded.library)
            tldr = .loaded(version: loaded.version)
            // What was typed while it loaded is searched again in the bigger library; the
            // open program stays open if it is still there.
            if isSearching {
                startSearch()
            } else {
                rows = Self.allRows(library)
            }
        }
    }

    // MARK: Searching

    private func startSearch() {
        generation += 1
        // The search before this one, if still running, is no longer wanted; nor is a
        // question to the assistant about the words before these.
        token.cancel()
        token = CheatSearchToken()
        if ask != .idle { cancelAsk() }
        let text = trimmedQuery
        let resolved = resolvedMode
        guard !text.isEmpty else {
            // Back to the whole list, with the program that was open still open.
            result = CheatSearchResult()
            rows = Self.allRows(library)
            return
        }
        let generation = self.generation
        let index = self.index
        let token = self.token
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = index.search(text, as: resolved, token: token)
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
            return Row(
                name: program.name,
                summary: program.summary,
                matchCount: hit.matchCount,
                nameIndices: hit.nameIndices,
                isCurated: program.isCurated
            )
        }
        // As in fzf, the best match is the one under the cursor.
        selectedProgram = rows.first?.name
    }

    // MARK: The manual on this Mac

    /// Runs `/usr/bin/man` for a name and hands back what it printed. All it does is read a
    /// file and format it; it does not run the program the page is about. Called off the main
    /// thread, with a time limit and `ProcessRunner`'s cap on how much it may say.
    private static func runMan(_ name: String) -> ManPageReader.Outcome? {
        let environment = [
            // No pager, and nothing a terminal would be asked about.
            "MANPAGER": "cat",
            "PAGER": "cat",
            "TERM": "dumb",
            // The commands Homebrew installs are found by their folders on the path.
            "PATH": ManPage.searchPath(base: ProcessInfo.processInfo.environment["PATH"]),
        ]
        guard let result = ProcessRunner.run("/usr/bin/man", [name], timeout: 4, environment: environment) else { return nil }
        return ManPageReader.Outcome(status: result.status, output: result.output, timedOut: result.timedOut)
    }

    private let manPages = ManPageReader(run: CheatsheetStore.runMan)

    /// Reads `name`'s manual page, unless it already has or is. Called when the section is
    /// opened, not when a program is chosen: moving down the list starts nothing.
    func loadManual(_ name: String) {
        switch manuals[name] {
        case .loading?, .found?, .missing?:
            return                      // in hand, or on its way
        case .failed?, nil:
            break                       // not asked for yet, or it failed: try
        }
        manuals[name] = .loading
        let reader = manPages
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = reader.read(name)
            DispatchQueue.main.async {
                switch result {
                case .found(let excerpt): self?.manuals[name] = .found(excerpt)
                case .missing: self?.manuals[name] = .missing
                case .failed(let message): self?.manuals[name] = .failed(message)
                }
            }
        }
    }

    // MARK: Asking the assistant

    /// Begins asking the assistant to choose among the entries closest to what is
    /// typed. Nothing is sent: this prepares the question, and the person is shown
    /// exactly what would go, and where, before `confirmAsk` sends it.
    ///
    /// Whether an assistant is set up is looked up here, once, and not as the page
    /// is drawn: it reads the Keychain.
    func beginAsk(baseURL: String) {
        guard isSearching else { return }
        switch ask {
        case .preparing, .asking: return
        default: break
        }
        guard AssistantServiceProvider.current.isConfigured else {
            ask = .notConfigured
            return
        }
        let question = trimmedQuery
        ask = .preparing
        let index = self.index
        let library = self.library
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // The closest entries by meaning, whatever mode the page is in: a question
            // is words.
            let found = index.searchNatural(question, programLimit: 0, exampleLimit: CheatsheetAskRequest.candidateLimit)
            let entries = found.examples.map { hit -> (program: String, description: String, command: String) in
                let program = library.programs[hit.program]
                let example = program.examples[hit.example]
                return (program.name, example.description, example.command)
            }
            DispatchQueue.main.async {
                guard let self, case .preparing = self.ask, self.trimmedQuery == question else { return }
                if let request = CheatsheetAskRequest.make(question: question, candidates: entries, baseURL: baseURL) {
                    self.ask = .confirming(request)
                } else {
                    self.ask = .failed("Nothing in the cheatsheet comes close to that, so there is nothing for the assistant to choose from.")
                }
            }
        }
    }

    /// Sends what `beginAsk` prepared, now that the person has seen it.
    func confirmAsk() {
        guard case .confirming(let request) = ask else { return }
        let service = AssistantServiceProvider.current
        guard service.isConfigured else {
            ask = .notConfigured
            return
        }
        ask = .asking(question: request.question)
        askTask = Task { [weak self] in
            do {
                let reply = try await service.complete(
                    system: CheatsheetAskRequest.systemPrompt,
                    user: request.userContent,
                    temperature: nil
                )
                guard !Task.isCancelled else { return }
                let picks = request.picks(from: reply)
                DispatchQueue.main.async {
                    self?.finishAsk(question: request.question, .answered(question: request.question, picks: picks))
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let message = error.localizedDescription
                DispatchQueue.main.async { self?.finishAsk(question: request.question, .failed(message)) }
            }
        }
    }

    /// Stops asking, or drops the answer, and goes back to the search.
    func cancelAsk() {
        askTask?.cancel()
        askTask = nil
        ask = .idle
    }

    /// An answer counts only for the question it was asked.
    private func finishAsk(question: String, _ state: AskState) {
        guard case .asking(let asked) = ask, asked == question else { return }
        askTask = nil
        ask = state
    }

    // MARK: Building the lists

    private static func positions(of library: CheatLibrary) -> [String: Int] {
        var positions: [String: Int] = [:]
        positions.reserveCapacity(library.programs.count)
        for (i, program) in library.programs.enumerated() { positions[program.name] = i }
        return positions
    }

    private static func allRows(_ library: CheatLibrary) -> [Row] {
        let rows = library.programs.map {
            Row(name: $0.name, summary: $0.summary, matchCount: 0, nameIndices: [], isCurated: $0.isCurated)
        }
        return rows.filter(\.isCurated) + rows.filter { !$0.isCurated }
    }
}
