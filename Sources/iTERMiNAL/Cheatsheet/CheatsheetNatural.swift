import Foundation

/// Finds examples by what the words of a question mean rather than by their
/// letters: "undo my last commit" finds `git reset --soft HEAD~1`, which has
/// none of those words in its command.
///
/// Every example is a small document — the program's name and tags, the
/// description, the words written to find it by, and the command — and a
/// question is scored against each by BM25, the ranking search engines have
/// long used: a word counts for more the rarer it is, and a document's own
/// length counts against it. On top of that:
///
///   * A word's family counts as the word at half weight ("remove" for
///     "delete", "reset" for "undo"; see `CheatSynonyms`).
///   * A word nothing contains is looked for with one letter wrong or missing.
///   * A document that has more of the question's words is worth more than one
///     that has one of them very well.
///   * A page written for this app counts for more than one from tldr-pages.
///     Without that, the first answer to "delete a directory" was a cloud
///     storage tool's command, because its page says it more often.
///
/// Held entirely in memory and built once with the library, off the main thread.
struct CheatNaturalIndex {
    /// One example that scored.
    struct Ranked: Equatable {
        var program: Int
        var example: Int
        var score: Float
    }

    private struct Posting {
        var document: Int32
        var weight: Float
    }

    private let postings: [String: [Posting]]
    private let vocabulary: [String]
    private let lengths: [Float]
    private let priors: [Float]
    private let programOf: [Int32]
    private let exampleOf: [Int32]
    private let averageLength: Float

    // How much a word is worth where it is found.
    static let nameWeight: Float = 3
    static let tagWeight: Float = 2
    static let summaryWeight: Float = 1
    static let descriptionWeight: Float = 2
    static let intentWeight: Float = 2
    static let commandWeight: Float = 1

    // BM25's two knobs: how fast repeating a word stops mattering, and how much
    // a long document is held against it.
    private static let k1: Float = 1.2
    private static let b: Float = 0.6

    static let synonymWeight: Float = 0.5
    static let typoWeight: Float = 0.8
    /// What a page written for this app counts for against one that is not.
    static let curatedPrior: Float = 1.6
    /// What a document that has only some of the question's words keeps: the
    /// share it has, raised to this.
    static let coverageExponent: Float = 1.5
    /// Examples scoring less than this share of the best one are not results.
    static let relevanceFloor: Float = 0.2
    /// The most words of a question that are used.
    static let maximumTerms = 32

    init(library: CheatLibrary) {
        var postings: [String: [Posting]] = [:]
        var lengths: [Float] = []
        var priors: [Float] = []
        var programOf: [Int32] = []
        var exampleOf: [Int32] = []

        for (p, program) in library.programs.enumerated() {
            // What is true of the program is true of each of its examples: it counts
            // towards a match, but not towards how long the example is. Otherwise a
            // page with many tags would have every one of its examples held against
            // it for being long, when each is a line.
            var shared: [String: Float] = [:]
            func addShared(_ words: [String], _ weight: Float) {
                for word in words where !CheatText.stopwords.contains(word) {
                    shared[CheatText.stem(word), default: 0] += weight
                }
            }
            addShared(CheatText.words(program.name), Self.nameWeight)
            addShared(program.tags.flatMap { CheatText.words($0) }, Self.tagWeight)
            addShared(CheatText.words(program.summary), Self.summaryWeight)
            let prior: Float = program.isCurated ? Self.curatedPrior : 1

            for (e, example) in program.examples.enumerated() {
                var weights = shared
                var length: Float = 0
                func add(_ words: [String], _ weight: Float) {
                    for word in words where !CheatText.stopwords.contains(word) {
                        weights[CheatText.stem(word), default: 0] += weight
                        length += weight
                    }
                }
                add(CheatText.words(example.description), Self.descriptionWeight)
                add(CheatText.words(example.intent), Self.intentWeight)
                add(CheatText.words(example.command), Self.commandWeight)

                let document = Int32(lengths.count)
                lengths.append(max(length, 1))
                priors.append(prior)
                programOf.append(Int32(p))
                exampleOf.append(Int32(e))
                for (stem, weight) in weights {
                    postings[stem, default: []].append(Posting(document: document, weight: weight))
                }
            }
        }
        self.postings = postings
        self.vocabulary = Array(postings.keys)
        self.lengths = lengths
        self.priors = priors
        self.programOf = programOf
        self.exampleOf = exampleOf
        self.averageLength = lengths.isEmpty ? 1 : max(lengths.reduce(0, +) / Float(lengths.count), 1)
    }

    var documentCount: Int { lengths.count }

    /// The examples that answer `terms` (stems; see `CheatText.queryTerms`), best
    /// first. Nothing if no term is anywhere. Stops and returns nothing if the
    /// token is cancelled.
    func rank(terms allTerms: [String], limit: Int = 5_000, token: CheatSearchToken? = nil) -> [Ranked] {
        let count = lengths.count
        // A pasted paragraph is not a question; and the count of words a document has
        // is kept in a byte.
        let terms = Array(allTerms.prefix(Self.maximumTerms))
        guard count > 0, !terms.isEmpty else { return [] }

        var sums = [Float](repeating: 0, count: count)
        var covered = [UInt8](repeating: 0, count: count)
        var best = [Float](repeating: 0, count: count)

        for term in terms {
            if token?.isCancelled == true { return [] }
            var touched: [Int32] = []
            func take(_ stem: String, weight: Float) {
                guard let list = postings[stem] else { return }
                let idf = log(1 + (Float(count) - Float(list.count) + 0.5) / (Float(list.count) + 0.5))
                for posting in list {
                    let d = Int(posting.document)
                    let norm = Self.k1 * (1 - Self.b + Self.b * lengths[d] / averageLength)
                    let value = weight * idf * posting.weight * (Self.k1 + 1) / (posting.weight + norm)
                    if best[d] == 0 { touched.append(posting.document) }
                    if value > best[d] { best[d] = value }
                }
            }

            if postings[term] != nil {
                take(term, weight: 1)
            } else {
                for near in closeStems(to: term) { take(near, weight: Self.typoWeight) }
            }
            for synonym in CheatSynonyms.related(to: term) { take(synonym, weight: Self.synonymWeight) }

            for document in touched {
                let d = Int(document)
                sums[d] += best[d]
                covered[d] += 1
                best[d] = 0
            }
        }

        var ranked: [Ranked] = []
        let total = Float(terms.count)
        for d in 0..<count where covered[d] > 0 {
            let share = Float(covered[d]) / total
            let score = sums[d] * pow(share, Self.coverageExponent) * priors[d]
            ranked.append(Ranked(program: Int(programOf[d]), example: Int(exampleOf[d]), score: score))
        }
        guard let top = ranked.map(\.score).max() else { return [] }
        ranked = ranked.filter { $0.score >= top * Self.relevanceFloor }
        // Best first; among equals, the order they were written in.
        ranked.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.program != b.program { return a.program < b.program }
            return a.example < b.example
        }
        return Array(ranked.prefix(limit))
    }

    /// The words in the index one letter away from `stem`, for a typing slip.
    /// Only for a word long enough that one letter is not most of it.
    private func closeStems(to stem: String) -> [String] {
        guard stem.count >= 5 else { return [] }
        let wanted = Array(stem)
        var near: [String] = []
        for word in vocabulary where abs(word.count - wanted.count) <= 1 {
            if Self.withinOneEdit(Array(word), wanted) {
                near.append(word)
                if near.count == 4 { break }
            }
        }
        return near
    }

    /// Whether `a` becomes `b` by changing, adding or dropping one letter, or
    /// by swapping two neighbours.
    static func withinOneEdit(_ a: [Character], _ b: [Character]) -> Bool {
        if a == b { return true }
        if abs(a.count - b.count) > 1 { return false }
        var i = 0
        while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
        if a.count == b.count {
            if a[(i + 1)...] == b[(i + 1)...] { return true }                       // one letter changed
            return i + 1 < a.count && a[i] == b[i + 1] && a[i + 1] == b[i]
                && a[(i + 2)...] == b[(i + 2)...]                                   // two swapped
        }
        let (longer, shorter) = a.count > b.count ? (a, b) : (b, a)
        return longer[(i + 1)...] == shorter[i...]                                  // one letter added or dropped
    }
}
