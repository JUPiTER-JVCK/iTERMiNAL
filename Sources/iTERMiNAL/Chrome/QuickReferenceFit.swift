import Foundation

/// How many of the quick reference's hints fit on its line, worked out from
/// each hint's width: the longest run from the first that the room holds, and
/// the note after them only once every hint is in. Foundation only, so it is
/// checked off a Mac.
///
/// The line used to be a `ViewThatFits` with a row for every count that might
/// fit, which builds and measures n(n+1)/2 hints at each redraw — 561 buttons
/// for git's 33 subcommands — on the main thread while someone types. Now each
/// hint is measured once, on a copy of the row that is never drawn, and only
/// the row that fits is built.
enum QuickReferenceFit {
    /// Rounding in the measured widths, which come from SwiftUI's layout: a
    /// row that fits in principle must not lose its last hint to it.
    static let tolerance: CGFloat = 0.5

    /// How many hints to show.
    ///
    /// - Parameters:
    ///   - widths: each hint's width, in order; nil for one not measured yet,
    ///     which ends the run, so nothing that might not fit is shown.
    ///   - hasNote: whether a note follows the hints. It is shown only with
    ///     every hint, as `ViewThatFits` showed it, so a note that does not fit
    ///     after them costs the last hint. With no hints at all it is the whole
    ///     line, and is shown whatever the room.
    ///   - noteWidth: the note's width; nil while not measured.
    ///   - spacing: the gap between neighbours.
    ///   - room: the width there is.
    static func count(widths: [CGFloat?], hasNote: Bool, noteWidth: CGFloat?, spacing: CGFloat, room: CGFloat) -> Int {
        var used: CGFloat = 0
        var fitted = 0
        for width in widths {
            guard let width else { break }
            let next = used + (fitted == 0 ? 0 : spacing) + width
            guard next <= room + tolerance else { break }
            used = next
            fitted += 1
        }
        guard hasNote, fitted == widths.count, fitted > 0 else { return fitted }
        guard let noteWidth, used + spacing + noteWidth <= room + tolerance else { return fitted - 1 }
        return fitted
    }
}
