import Foundation

/// The automatic names for Spaces — "Space 1", "Space 2"…
/// Foundation only, so the naming is checked off a Mac.
enum SpaceName {
    /// The lowest "Space N" not already taken.
    ///
    /// Counting the spaces instead (`count + 1`) hands out a name that is
    /// already in use as soon as one in the middle has gone: with Space 1 and
    /// Space 2 open and Space 1 closed, the next would be a second "Space 2".
    /// Every terminal that is not a split now opens a Space of its own, so
    /// they come and go constantly.
    static func next(avoiding existing: [String]) -> String {
        let taken = Set(existing)
        var number = 1
        while taken.contains("Space \(number)") { number += 1 }
        return "Space \(number)"
    }
}
