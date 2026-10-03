import Foundation

/// A query found inside a candidate: where its characters landed, and how good
/// a match that is.
struct FuzzyMatch: Equatable {
    var score: Int
    /// Offsets into the candidate's `Character`s, ascending, so a view can
    /// emphasise exactly the characters that matched.
    var indices: [Int]
}

/// The command palette's rule — every character of the query appears in order
/// somewhere in the candidate, case aside, spaces in the query ignored — plus a
/// score, so the best match can be listed first instead of the first one found.
///
/// The match returned is the best-scoring one there is, not merely the first or
/// the tightest: of all the ways the query's characters can be placed in the
/// candidate, the one `score(of:…)` rates highest.
enum FuzzyMatcher {
    /// One `Character` to one `Character`, so offsets into the folded text are
    /// offsets into the original too.
    static func folded(_ text: String) -> [Character] {
        text.map { fold($0) }
    }

    static func fold(_ character: Character) -> Character {
        if let ascii = character.asciiValue {
            return ascii >= 65 && ascii <= 90 ? Character(UnicodeScalar(ascii + 32)) : character
        }
        return character.lowercased().first ?? character
    }

    /// What a query looks for: folded, with its spaces dropped.
    static func needle(_ query: String) -> [Character] {
        folded(query).filter { $0 != " " }
    }

    static func match(_ query: String, in candidate: String) -> FuzzyMatch? {
        let original = Array(candidate)
        return match(needle: needle(query), folded: original.map { fold($0) }, original: original)
    }

    // MARK: Scoring

    /// What each character placed at `index` is worth on its own.
    private static func placement(at index: Int, in original: [Character]) -> Int {
        var value = 16
        if index == 0 {
            value += 14                                     // the start of the command
        } else if isBoundary(before: original[index - 1], at: original[index]) {
            value += 10                                     // the start of a word
        }
        return value
    }

    private static let consecutiveBonus = 12                // runs of characters
    private static let gapPenaltyCap = 6                    // a gap costs a little, up to this
    private static let leadingPenaltyCap = 8                // a late start costs a little too

    private static func isBoundary(before previous: Character, at character: Character) -> Bool {
        if " /-_.:=@".contains(previous) { return true }
        return previous.isLowercase && character.isUppercase
    }

    /// What a particular placement of the query is worth. `match` finds the
    /// placement with the most; this is the definition of "most", written out
    /// directly so it can be checked against.
    static func score(of indices: [Int], candidateLength: Int, original: [Character]) -> Int {
        guard !indices.isEmpty else { return 0 }
        var total = 0
        var previous = -2
        for (slot, index) in indices.enumerated() {
            total += placement(at: index, in: original)
            if index == previous + 1 {
                total += consecutiveBonus
            } else if slot > 0 {
                total -= min(index - previous - 1, gapPenaltyCap)
            }
            previous = index
        }
        total -= min(indices[0], leadingPenaltyCap)
        if candidateLength == indices.count { total += 40 }  // the whole thing
        total -= min(candidateLength / 8, 10)                // shorter reads as closer
        return total
    }

    // MARK: Matching

    /// For callers that match one query against many candidates and fold each
    /// candidate once, up front.
    static func match(needle: [Character], folded: [Character], original: [Character]) -> FuzzyMatch? {
        let m = needle.count
        guard m > 0 else { return FuzzyMatch(score: 0, indices: []) }
        let n = folded.count
        guard m <= n, containsInOrder(needle, in: folded) else { return nil }

        // best[i * n + j]: the most the first i + 1 query characters can score
        // with query character i placed on candidate character j; `none` if it
        // cannot be. `previous` remembers where character i - 1 went, to read
        // the placement back out.
        let none = Int.min
        var best = [Int](repeating: none, count: m * n)
        var previous = [Int](repeating: -1, count: m * n)

        for j in 0..<n where folded[j] == needle[0] {
            best[j] = placement(at: j, in: original) - min(j, leadingPenaltyCap)
        }

        // Which earlier position is the best to come from depends on how far
        // back it is: next door is a run, up to `gapPenaltyCap` back costs one
        // per skipped character, and anything further costs the same flat
        // amount — so the far ones reduce to a running best.
        var farScore = [Int](repeating: none, count: n)
        var farAt = [Int](repeating: -1, count: n)

        for i in 1..<max(m, 1) {
            let row = (i - 1) * n
            var runningScore = none
            var runningAt = -1
            for k in 0..<n {
                if best[row + k] != none, best[row + k] > runningScore {
                    runningScore = best[row + k]
                    runningAt = k
                }
                farScore[k] = runningScore
                farAt[k] = runningAt
            }

            for j in i..<n where folded[j] == needle[i] {
                var bestScore = none
                var bestFrom = -1
                if best[row + j - 1] != none {
                    bestScore = best[row + j - 1] + consecutiveBonus
                    bestFrom = j - 1
                }
                for gap in 1...gapPenaltyCap {
                    let k = j - 1 - gap
                    if k < 0 { break }
                    if best[row + k] != none, best[row + k] - gap > bestScore {
                        bestScore = best[row + k] - gap
                        bestFrom = k
                    }
                }
                let far = j - 2 - gapPenaltyCap
                if far >= 0, farScore[far] != none, farScore[far] - gapPenaltyCap > bestScore {
                    bestScore = farScore[far] - gapPenaltyCap
                    bestFrom = farAt[far]
                }
                if bestFrom >= 0 {
                    best[i * n + j] = bestScore + placement(at: j, in: original)
                    previous[i * n + j] = bestFrom
                }
            }
        }

        var end = -1
        var endScore = none
        let last = (m - 1) * n
        for j in 0..<n where best[last + j] != none && best[last + j] > endScore {
            endScore = best[last + j]
            end = j
        }
        guard end >= 0 else { return nil }

        var indices = [Int](repeating: 0, count: m)
        var at = end
        for i in stride(from: m - 1, through: 0, by: -1) {
            indices[i] = at
            at = previous[i * n + at]
        }

        var total = endScore
        if n == m { total += 40 }
        total -= min(n / 8, 10)
        return FuzzyMatch(score: total, indices: indices)
    }

    private static func containsInOrder(_ needle: [Character], in haystack: [Character]) -> Bool {
        var matched = 0
        for character in haystack where character == needle[matched] {
            matched += 1
            if matched == needle.count { return true }
        }
        return false
    }
}
