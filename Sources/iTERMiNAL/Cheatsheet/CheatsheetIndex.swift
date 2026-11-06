import Foundation

/// One example that a search matched, and which characters of it did.
struct CheatHit: Equatable {
    /// Positions in `CheatLibrary.programs` and in that program's `examples`.
    var program: Int
    var example: Int
    var score: Int
    /// `Character` offsets into the program's name, the description and the
    /// command, for emphasising what matched.
    var nameIndices: [Int]
    var descriptionIndices: [Int]
    var commandIndices: [Int]
}

/// A program that a search found: by its name, by its examples, or both.
struct CheatProgramHit: Equatable {
    var program: Int
    var score: Int
    var nameIndices: [Int]
    /// How many of its examples matched.
    var matchCount: Int
}

struct CheatSearchResult: Equatable {
    /// Best first.
    var programs: [CheatProgramHit] = []
    /// Best first, at most the limit asked for.
    var examples: [CheatHit] = []
    /// How many examples matched before the list was cut short.
    var exampleTotal = 0

    var isEmpty: Bool { programs.isEmpty }

    /// The hits inside one program, by example.
    func hits(inProgram program: Int) -> [CheatHit] {
        examples.filter { $0.program == program }
    }
}

/// Lets a search be abandoned from another thread once a newer one has begun,
/// so a run of keystrokes costs one search and not one for each.
final class CheatSearchToken {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// A library made searchable: type a few letters, as for fzf, and the programs
/// and examples that contain them in order come back best first.
///
/// What is matched is the program's name, the description and the command,
/// read as one line — "git undo reset" finds `git reset` under "Undo" — which is
/// what `FuzzyMatcher` scores. The scoring is the command palette's, so
/// the two feel alike.
///
/// It does not keep a `[Character]` for every example the way
/// `CommandHistoryIndex` does. The library can be tens of thousands of examples,
/// and 16 bytes a character would cost tens of megabytes. Each example is
/// instead kept as lower-case UTF-8 in one shared buffer, which is enough to
/// rule most of them out by a plain scan, and only the few that pass are
/// matched properly.
struct CheatIndex {
    let library: CheatLibrary

    private struct Ref {
        var program: Int
        var example: Int
    }

    private let refs: [Ref]
    /// Lower-case UTF-8 of "name description command" for every example, back
    /// to back.
    private let bytes: ContiguousArray<UInt8>
    private let ranges: [Range<Int>]
    private let nameCharacters: [[Character]]
    private let nameFolded: [[Character]]

    init(library: CheatLibrary) {
        self.library = library
        var refs: [Ref] = []
        var bytes = ContiguousArray<UInt8>()
        var ranges: [Range<Int>] = []
        for (p, program) in library.programs.enumerated() {
            for (e, example) in program.examples.enumerated() {
                let start = bytes.count
                bytes.append(contentsOf: Array(program.name.lowercased().utf8))
                bytes.append(0x20)
                bytes.append(contentsOf: Array(example.description.lowercased().utf8))
                bytes.append(0x20)
                bytes.append(contentsOf: Array(example.command.lowercased().utf8))
                refs.append(Ref(program: p, example: e))
                ranges.append(start..<bytes.count)
            }
        }
        self.refs = refs
        self.bytes = bytes
        self.ranges = ranges
        self.nameCharacters = library.programs.map { Array($0.name) }
        self.nameFolded = nameCharacters.map { $0.map { FuzzyMatcher.fold($0) } }
    }

    /// The fewest letters that are matched against the examples. One letter
    /// is in most of them, which says nothing; it narrows the list of programs
    /// by name and no more.
    static let minimumLettersForExamples = 2

    /// - Parameter token: if it is cancelled while this runs, the search stops
    ///   and returns nothing, which is for a caller that has already moved on.
    func search(
        _ query: String,
        programLimit: Int = 300,
        exampleLimit: Int = 600,
        token: CheatSearchToken? = nil
    ) -> CheatSearchResult {
        let needle = FuzzyMatcher.needle(query)
        guard !needle.isEmpty else { return CheatSearchResult() }

        // A plain scan can only stand in for the matcher when every character is
        // ASCII, where lower-casing a byte is lower-casing the character.
        let scanNeedle: [UInt8]? = needle.allSatisfy { $0.isASCII } ? needle.map { $0.asciiValue ?? 0 } : nil

        var nameHits: [Int: FuzzyMatch] = [:]
        for p in 0..<nameFolded.count {
            if let match = FuzzyMatcher.match(needle: needle, folded: nameFolded[p], original: nameCharacters[p]) {
                nameHits[p] = match
            }
        }

        var hits: [CheatHit] = []
        let searchesExamples = needle.count >= Self.minimumLettersForExamples
        for (r, ref) in refs.enumerated() where searchesExamples {
            if r & 0xFF == 0, token?.isCancelled == true { return CheatSearchResult() }
            if let scanNeedle, !Self.containsInOrder(scanNeedle, in: bytes, range: ranges[r]) { continue }
            let program = library.programs[ref.program]
            let example = program.examples[ref.example]

            let name = nameCharacters[ref.program]
            let description = Array(example.description)
            let command = Array(example.command)
            var line = name
            line.append(" ")
            line.append(contentsOf: description)
            line.append(" ")
            line.append(contentsOf: command)
            let folded = line.map { FuzzyMatcher.fold($0) }
            guard let match = FuzzyMatcher.match(needle: needle, folded: folded, original: line) else { continue }

            let descriptionStart = name.count + 1
            let commandStart = descriptionStart + description.count + 1
            var inName: [Int] = [], inDescription: [Int] = [], inCommand: [Int] = []
            for index in match.indices {
                if index < name.count {
                    inName.append(index)
                } else if index >= commandStart {
                    inCommand.append(index - commandStart)
                } else if index >= descriptionStart, index < descriptionStart + description.count {
                    inDescription.append(index - descriptionStart)
                }
            }
            hits.append(CheatHit(
                program: ref.program,
                example: ref.example,
                score: match.score,
                nameIndices: inName,
                descriptionIndices: inDescription,
                commandIndices: inCommand
            ))
        }

        // Best first; among equals, ours before tldr's, then the order written.
        hits = hits.enumerated().sorted { a, b in
            if a.element.score != b.element.score { return a.element.score > b.element.score }
            let aCurated = library.programs[a.element.program].examples[a.element.example].source == .curated
            let bCurated = library.programs[b.element.program].examples[b.element.example].source == .curated
            if aCurated != bCurated { return aCurated }
            return a.offset < b.offset
        }.map(\.element)

        var perProgram: [Int: (best: Int, count: Int)] = [:]
        for hit in hits {
            let current = perProgram[hit.program] ?? (best: Int.min, count: 0)
            perProgram[hit.program] = (best: max(current.best, hit.score), count: current.count + 1)
        }

        // A program is as good a match as the better of its name and its best
        // example. Typing a name needs no extra weight: every example is matched
        // with the name in front of it, and a name that is the whole of the query
        // earns the matcher's whole-string bonus.
        var programs: [CheatProgramHit] = []
        for p in Set(perProgram.keys).union(nameHits.keys) {
            let name = nameHits[p]
            let examples = perProgram[p]
            programs.append(CheatProgramHit(
                program: p,
                score: max(name?.score ?? Int.min, examples?.best ?? Int.min),
                nameIndices: name?.indices ?? [],
                matchCount: examples?.count ?? 0
            ))
        }
        // Among equal scores, a page written for this app first, then the one
        // with more matches, then the order they are listed in.
        programs.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            let aCurated = library.programs[a.program].isCurated
            let bCurated = library.programs[b.program].isCurated
            if aCurated != bCurated { return aCurated }
            if a.matchCount != b.matchCount { return a.matchCount > b.matchCount }
            return a.program < b.program
        }

        return CheatSearchResult(
            programs: Array(programs.prefix(programLimit)),
            examples: Array(hits.prefix(exampleLimit)),
            exampleTotal: hits.count
        )
    }

    /// Whether every byte of `needle` turns up in `buffer[range]`, in order.
    private static func containsInOrder(_ needle: [UInt8], in buffer: ContiguousArray<UInt8>, range: Range<Int>) -> Bool {
        var matched = 0
        var i = range.lowerBound
        while i < range.upperBound {
            if buffer[i] == needle[matched] {
                matched += 1
                if matched == needle.count { return true }
            }
            i += 1
        }
        return false
    }
}
