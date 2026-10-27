import Foundation

/// What the right-click menu needs to offer a link: which cell was clicked,
/// whether what is there opens as a web page, and how to show it. Foundation
/// only, so it is checked off a Mac; `InstrumentedTerminalView` asks SwiftTerm
/// what is at the cell and `TerminalContextMenu` builds the items.
enum TerminalLinks {
    /// The size of one cell, from the size SwiftTerm gives for the whole grid
    /// (`getOptimalFrameSize()`, which is cells times cells with the scrollbar's
    /// width added when it is showing — here it is hidden). Nil for a grid with
    /// nothing in it or a size that is not a number.
    static func cellSize(gridWidth: Double, gridHeight: Double, cols: Int, rows: Int) -> (width: Double, height: Double)? {
        guard cols > 0, rows > 0, gridWidth.isFinite, gridHeight.isFinite, gridWidth > 0, gridHeight > 0 else { return nil }
        return (gridWidth / Double(cols), gridHeight / Double(rows))
    }

    /// The cell under a point, counted from the grid's top left corner.
    ///
    /// `x` runs from the left and `y` from the *bottom* of a view of `viewHeight`,
    /// which is how AppKit gives a point in a view that is not flipped and how
    /// SwiftTerm reads one. A point outside the grid — in the padding around
    /// it, or in the strip left over when the view is not a whole number of
    /// cells — is nil, not the nearest cell: a click beside a link is not on it.
    static func cell(
        x: Double, y: Double, viewHeight: Double,
        cellWidth: Double, cellHeight: Double,
        cols: Int, rows: Int
    ) -> (col: Int, row: Int)? {
        guard x.isFinite, y.isFinite, viewHeight.isFinite,
              cellWidth > 0, cellHeight > 0, cols > 0, rows > 0 else { return nil }
        let fromTop = viewHeight - y
        guard x >= 0, fromTop >= 0 else { return nil }
        let col = Int((x / cellWidth).rounded(.down))
        let row = Int((fromTop / cellHeight).rounded(.down))
        guard col < cols, row < rows else { return nil }
        return (col, row)
    }

    /// The page a link opens, when it is one: `http` or `https`, with a host.
    /// Anything else — a file path, `file:`, a scheme another program claims —
    /// is nil. The menu only offers to open a web page: a program can print a
    /// link whose text says one thing and whose address is another, and a
    /// right-click that opened any address at all would be a way to have a
    /// click start something. Copying is offered for every kind.
    static func webURL(_ link: String) -> URL? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// `link` as it is shown at the top of the menu: what the item will really
    /// open, which for a hyperlink a program printed is not necessarily what the
    /// text on the screen says. Control and invisible formatting characters —
    /// a newline, a zero-width space, a right-to-left override — are replaced by
    /// a dot so they can neither break the menu nor make the address read as
    /// something else, and a long one loses its middle, not its end.
    static func preview(_ link: String, limit: Int = 64) -> String {
        let shown = String(String.UnicodeScalarView(link.unicodeScalars.map { scalar -> Unicode.Scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned:
                return "·"
            default:
                return scalar
            }
        }))
        let characters = Array(shown)
        guard limit >= 8, characters.count > limit else { return shown }
        let head = (limit - 1) / 2
        let tail = limit - 1 - head
        return String(characters.prefix(head)) + "…" + String(characters.suffix(tail))
    }
}
