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

    /// For callers that match one query against many candidates and fold each
    /// candidate once, up front.
    static func match(needle: [Character], folded: [Character], original: [Character]) -> FuzzyMatch? {
        guard !needle.isEmpty else { return FuzzyMatch(score: 0, indices: []) }

        // Forward to find where the match can end, then back from there to
        // pull it as tight as it will go: "gst" in "git status" should land on
        // the "st" of "status", not on the first "s" it could reach.
        var matched = 0
        var end = -1
        for (offset, character) in folded.enumerated() where character == needle[matched] {
            matched += 1
            if matched == needle.count {
                end = offset
                break
            }
        }
        guard end >= 0 else { return nil }

        var indices = [Int](repeating: 0, count: needle.count)
        var cursor = end
        for slot in stride(from: needle.count - 1, through: 0, by: -1) {
            while folded[cursor] != needle[slot] { cursor -= 1 }
            indices[slot] = cursor
            cursor -= 1
        }

        return FuzzyMatch(score: score(indices, folded: folded, original: original, needleCount: needle.count), indices: indices)
    }

    private static func score(_ indices: [Int], folded: [Character], original: [Character], needleCount: Int) -> Int {
        var score = 0
        var previous = -2
        for (slot, index) in indices.enumerated() {
            score += 16
            if index == previous + 1 {
                score += 12                                 // runs of characters
            } else if slot > 0 {
                score -= min(index - previous - 1, 6)       // a gap costs a little
            }
            if index == 0 {
                score += 14                                 // the start of the command
            } else if isBoundary(before: original[index - 1], at: original[index]) {
                score += 10                                 // the start of a word
            }
            previous = index
        }
        score -= min(indices[0], 8)                         // a late start
        if folded.count == needleCount { score += 40 }      // the whole thing
        score -= min(folded.count / 8, 10)                  // shorter reads as closer
        return score
    }

    private static func isBoundary(before previous: Character, at character: Character) -> Bool {
        if " /-_.:=@".contains(previous) { return true }
        return previous.isLowercase && character.isUppercase
    }
}
