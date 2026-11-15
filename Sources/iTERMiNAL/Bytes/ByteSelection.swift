import Foundation

/// The bytes the person has selected: one byte, or a run, with the end they are
/// moving (`head`, which is also where the cursor is) and the end that stays put
/// (`anchor`). Both ends are bytes, so a selection is never empty.
///
/// All the moves live here, away from the view, so what an arrow key does at the
/// start of a file, or a page key does near its end, is checked rather than seen.
struct ByteSelection: Equatable {
    var anchor: Int64
    var head: Int64

    init(anchor: Int64, head: Int64) {
        self.anchor = anchor
        self.head = head
    }

    /// One byte selected.
    init(at offset: Int64) {
        self.init(anchor: offset, head: offset)
    }

    var lowerBound: Int64 { min(anchor, head) }
    /// The last selected byte.
    var upperBound: Int64 { max(anchor, head) }
    var count: Int64 { upperBound - lowerBound + 1 }
    var range: Range<Int64> { lowerBound..<(upperBound + 1) }

    func contains(_ offset: Int64) -> Bool {
        offset >= lowerBound && offset <= upperBound
    }

    enum Move: Equatable {
        case left, right, up, down
        case pageUp, pageDown
        case rowStart, rowEnd
        case fileStart, fileEnd
    }

    /// Where `move` takes the selection in a file of `length` bytes. With
    /// `extending` the anchor stays and the selection grows or shrinks; without,
    /// the selection becomes the one byte it lands on. It never leaves the file.
    func moved(_ move: Move, extending: Bool, bytesPerRow: Int, rowsPerPage: Int, length: Int64) -> ByteSelection {
        guard length > 0 else { return self }
        let per = Int64(max(1, bytesPerRow))
        let page = per * Int64(max(1, rowsPerPage))
        let last = length - 1
        let target: Int64
        switch move {
        case .left: target = head - 1
        case .right: target = head + 1
        case .up: target = head - per
        case .down: target = head + per
        case .pageUp: target = head - page
        case .pageDown: target = head + page
        case .rowStart: target = head - head % per
        case .rowEnd: target = head - head % per + per - 1
        case .fileStart: target = 0
        case .fileEnd: target = last
        }
        let clamped = min(max(target, 0), last)
        return extending ? ByteSelection(anchor: anchor, head: clamped) : ByteSelection(at: clamped)
    }

    /// This selection with both ends inside a file of `length` bytes, or nil if
    /// there is no such byte. For a selection that outlived an edit that shortened the file.
    func limited(toLength length: Int64) -> ByteSelection? {
        guard length > 0 else { return nil }
        let last = length - 1
        return ByteSelection(anchor: min(max(anchor, 0), last), head: min(max(head, 0), last))
    }

    /// The part of row `row` that is selected, as positions in the row, or nil
    /// if none of it is.
    func indices(inRow row: Int64, bytesPerRow: Int) -> Range<Int>? {
        let per = Int64(max(1, bytesPerRow))
        let rowStart = row * per
        let rowEnd = rowStart + per
        let from = max(lowerBound, rowStart)
        let to = min(upperBound + 1, rowEnd)
        guard from < to else { return nil }
        return Int(from - rowStart)..<Int(to - rowStart)
    }
}
