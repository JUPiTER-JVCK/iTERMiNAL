import Foundation

/// Tells whether a name the network is advertising is the same machine as one
/// that was saved. Foundation only, so it is checked off a Mac.
///
/// A saved host is usually written the way DNS has it (`studio-mac.local`) and a
/// Bonjour service the way its owner typed it (`Studio Mac`, `Sam’s MacBook Pro`),
/// so both are reduced to their letters and digits before they are compared.
enum ServiceNameMatch {
    /// `Sam’s MacBook Pro` and `Sams-MacBook-Pro.local` both become `samsmacbookpro`.
    static func key(_ text: String) -> String {
        var lowered = text.lowercased()
        for suffix in [".local.", ".local"] where lowered.hasSuffix(suffix) {
            lowered = String(lowered.dropLast(suffix.count))
            break
        }
        return String(lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Whether the two name the same machine: equal once reduced, or one inside
    /// the other when it is long enough (four characters) not to be a coincidence.
    static func matches(_ first: String, _ second: String) -> Bool {
        let left = key(first)
        let right = key(second)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left == right { return true }
        let (short, long) = left.count <= right.count ? (left, right) : (right, left)
        return short.count >= 4 && long.contains(short)
    }
}
