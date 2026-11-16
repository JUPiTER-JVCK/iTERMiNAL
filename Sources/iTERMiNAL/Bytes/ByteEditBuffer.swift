import Foundation

enum ByteEditError: Error, Equatable {
    /// So many separate edits that finding a byte would slow to a crawl. Saving
    /// starts the count again.
    case tooManyPieces
    /// More new bytes typed or pasted than are worth keeping in memory.
    case tooMuchAddedData
    /// Reading the original gave fewer bytes than it should have, at this
    /// offset of the edited content: the file changed underneath.
    case unreadable(offset: Int64)
}

/// A file's bytes with edits laid over them, without the file being loaded.
///
/// The content is a list of *pieces*, each a run of the original, a run of the
/// bytes added since, or a run of one repeated byte. An edit cuts the list at
/// two places and puts new pieces between: nothing is moved, so overwriting one
/// byte of a 4 GB file costs the same as overwriting one byte of a 4 KB one, and
/// the original is never read except to show it or to write it out.
///
/// A value type, on purpose. A background scan takes a copy and sees one
/// revision for as long as it runs, however the person keeps typing; and a model
/// that holds the buffer in a `@Published` property publishes on every edit
/// without any further wiring.
///
/// Every edit records the pieces it replaced and the ones it put in, so undo and
/// redo are exact and cost nothing in memory but those few pieces.
struct ByteEditBuffer {
    /// More pieces than this and an edit is refused. A hundred thousand is far
    /// beyond what a person makes by hand; it is a guard against a loop.
    static let maxPieces = 100_000
    /// More added bytes than this and an edit is refused.
    static let maxAddedBytes = 256 * 1024 * 1024

    struct Piece: Equatable {
        enum Origin: Equatable {
            /// `start` is an offset into the source.
            case original
            /// `start` is an offset into the added bytes.
            case added
            /// The one byte, `length` times; `start` is not used. A selection of
            /// any size can be filled for the price of one piece.
            case run(UInt8)
        }

        var origin: Origin
        var start: Int64
        var length: Int64

        /// The first `n` bytes of this piece.
        fileprivate func keeping(first n: Int64) -> Piece {
            Piece(origin: origin, start: start, length: n)
        }

        /// All but the first `n` bytes of this piece.
        fileprivate func dropping(first n: Int64) -> Piece {
            if case .run = origin {
                return Piece(origin: origin, start: 0, length: length - n)
            }
            return Piece(origin: origin, start: start + n, length: length - n)
        }
    }

    /// What an edit puts where the cut was made.
    private enum Content {
        case nothing
        case bytes([UInt8])
        case run(UInt8, count: Int64)
    }

    /// One cut: the pieces at `index` that were replaced, and what replaced them.
    private struct Edit {
        var index: Int
        var removed: [Piece]
        var inserted: [Piece]

        var removedLength: Int64 { removed.reduce(0) { $0 + $1.length } }
        var insertedLength: Int64 { inserted.reduce(0) { $0 + $1.length } }
    }

    /// One step of undo: a single edit, or the run of typing that was folded into one.
    private struct Group {
        var edits: [Edit]
    }

    /// The limits this buffer holds itself to; the two above unless a check
    /// lowers them to reach what they guard.
    var pieceLimit = ByteEditBuffer.maxPieces
    var addedByteLimit = ByteEditBuffer.maxAddedBytes

    let source: ByteSource
    private(set) var pieces: [Piece]
    private var added: [UInt8] = []
    /// How many bytes there are now.
    private(set) var length: Int64
    /// Changes with every edit, undo and redo, and with nothing else: a cache of
    /// anything derived from the content can be keyed on it.
    private(set) var revision = 0

    private var undoStack: [Group] = []
    private var redoStack: [Group] = []
    /// How many undo steps were applied when the content was last saved. Nil
    /// when that state can no longer be reached, because an edit was made after
    /// undoing past it.
    private var savedDepth: Int? = 0
    /// Whether the last edit may be continued by the next one into one undo step,
    /// and where that next edit has to start for it to be.
    private var runOpen = false
    private var runEnd: Int64?

    init(source: ByteSource) {
        self.source = source
        self.length = source.count
        self.pieces = source.count > 0 ? [Piece(origin: .original, start: 0, length: source.count)] : []
    }

    // MARK: State

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Whether the content differs from what was last saved (or opened). Undoing
    /// back to that state makes it clean again.
    var isDirty: Bool { savedDepth != undoStack.count }

    /// Notes that the content has just been written out.
    mutating func markSaved() {
        savedDepth = undoStack.count
        // Typing after a save is a new step, never a part of the saved one.
        runOpen = false
    }

    // MARK: Reading

    /// The bytes in `range`, limited to what there is. Like a `ByteSource`, a
    /// failed read of the original gives the readable prefix, never a hole.
    func read(_ range: Range<Int64>) -> [UInt8] {
        let lower = min(max(range.lowerBound, 0), length)
        let upper = min(max(range.upperBound, lower), length)
        guard lower < upper else { return [] }

        var result: [UInt8] = []
        result.reserveCapacity(Int(upper - lower))
        var (index, delta) = locate(lower)
        var remaining = upper - lower
        while remaining > 0, index < pieces.count {
            let piece = pieces[index]
            let take = min(piece.length - delta, remaining)
            switch piece.origin {
            case .original:
                let from = piece.start + delta
                let got = source.read(from..<(from + take))
                result.append(contentsOf: got)
                if Int64(got.count) < take { return result }
            case .added:
                let from = Int(piece.start + delta)
                result.append(contentsOf: added[from..<(from + Int(take))])
            case .run(let value):
                result.append(contentsOf: repeatElement(value, count: Int(take)))
            }
            remaining -= take
            index += 1
            delta = 0
        }
        return result
    }

    /// The content in order, in pieces of at most `chunkSize` bytes, for writing
    /// it out. Throws what `sink` throws, and `unreadable` if the original comes
    /// back short: a save must never write a file with a hole in it.
    func stream(chunkSize: Int = 1 << 20, _ sink: (ArraySlice<UInt8>) throws -> Void) throws {
        let chunk = Int64(max(1, chunkSize))
        var position: Int64 = 0
        for piece in pieces {
            var done: Int64 = 0
            while done < piece.length {
                let take = min(chunk, piece.length - done)
                switch piece.origin {
                case .original:
                    let from = piece.start + done
                    let got = source.read(from..<(from + take))
                    guard Int64(got.count) == take else { throw ByteEditError.unreadable(offset: position + done) }
                    try sink(got[...])
                case .added:
                    let from = Int(piece.start + done)
                    try sink(added[from..<(from + Int(take))])
                case .run(let value):
                    try sink([UInt8](repeating: value, count: Int(take))[...])
                }
                done += take
            }
            position += piece.length
        }
    }

    // MARK: Editing

    /// Replaces the bytes from `offset` with `bytes`, without changing the length:
    /// what lies past the end is dropped. Returns how many were written.
    ///
    /// With `coalescing`, an edit that starts where the last one ended, and was
    /// also made with it, joins that one into a single step of undo — so typing a
    /// run of bytes is undone as a run.
    ///
    /// `continuingRun` joins the open run wherever this edit is, for the second digit of a byte
    /// typed in two: it changes the byte that was just written, which is before where the run ends.
    /// The run's end does not move in that case.
    @discardableResult
    mutating func overwrite(at offset: Int64, with bytes: [UInt8], coalescing: Bool = false, continuingRun: Bool = false) throws -> Int {
        guard offset >= 0, offset < length, !bytes.isEmpty else { return 0 }
        let count = Int(min(Int64(bytes.count), length - offset))
        let end = offset + Int64(count)
        let continues = continuingRun && runOpen
        try replace(offset..<end, with: .bytes(Array(bytes[0..<count])),
                    joiningRun: coalescing && runOpen && (runEnd == offset || continues),
                    opensRun: coalescing, runEnd: continues ? max(end, runEnd ?? end) : end)
        return count
    }

    /// Puts `bytes` in at `offset`, moving what follows along. An offset past the
    /// end is the end.
    mutating func insert(at offset: Int64, bytes: [UInt8], coalescing: Bool = false) throws {
        guard !bytes.isEmpty else { return }
        let at = min(max(offset, 0), length)
        let end = at + Int64(bytes.count)
        try replace(at..<at, with: .bytes(bytes),
                    joiningRun: coalescing && runOpen && runEnd == at,
                    opensRun: coalescing, runEnd: end)
    }

    /// Removes `range`, limited to what there is.
    mutating func delete(_ range: Range<Int64>) throws {
        let lower = min(max(range.lowerBound, 0), length)
        let upper = min(max(range.upperBound, lower), length)
        guard lower < upper else { return }
        try replace(lower..<upper, with: .nothing, joiningRun: false, opensRun: false, runEnd: nil)
    }

    /// Sets every byte of `range`, limited to what there is, to `value`. Costs one
    /// piece however long the range is.
    mutating func fill(_ range: Range<Int64>, with value: UInt8) throws {
        let lower = min(max(range.lowerBound, 0), length)
        let upper = min(max(range.upperBound, lower), length)
        guard lower < upper else { return }
        try replace(lower..<upper, with: .run(value, count: upper - lower),
                    joiningRun: false, opensRun: false, runEnd: nil)
    }

    /// Takes back the last step. False when there is none.
    @discardableResult
    mutating func undo() -> Bool {
        guard let group = undoStack.popLast() else { return false }
        for edit in group.edits.reversed() {
            pieces.replaceSubrange(edit.index..<(edit.index + edit.inserted.count), with: edit.removed)
            length += edit.removedLength - edit.insertedLength
        }
        redoStack.append(group)
        runOpen = false
        revision += 1
        return true
    }

    /// Puts back the step last taken back. False when there is none.
    @discardableResult
    mutating func redo() -> Bool {
        guard let group = redoStack.popLast() else { return false }
        for edit in group.edits {
            pieces.replaceSubrange(edit.index..<(edit.index + edit.removed.count), with: edit.inserted)
            length += edit.insertedLength - edit.removedLength
        }
        undoStack.append(group)
        runOpen = false
        revision += 1
        return true
    }

    // MARK: What changed

    /// The runs of bytes whose content differs from the original at the same place, or nil if the length is
    /// different or anything has moved, so that the file cannot be had by changing those runs alone. A save
    /// that finds a list writes only those runs into a copy of the file.
    func changedRanges() -> [Range<Int64>]? {
        guard length == source.count else { return nil }
        var position: Int64 = 0
        var runs: [Range<Int64>] = []
        for piece in pieces {
            let range = position..<(position + piece.length)
            if case .original = piece.origin, piece.start == position {
                // Unchanged.
            } else if case .original = piece.origin {
                // The original, but from somewhere else.
                return nil
            } else if let last = runs.last, last.upperBound == range.lowerBound {
                runs[runs.count - 1] = last.lowerBound..<range.upperBound
            } else {
                runs.append(range)
            }
            position += piece.length
        }
        return runs
    }

    // MARK: The piece list

    /// The piece holding `offset`, and how far into it. An offset at the end, or
    /// past it, is one past the last piece. An offset on the boundary between two
    /// pieces belongs to the second.
    private func locate(_ offset: Int64) -> (index: Int, delta: Int64) {
        var position: Int64 = 0
        for (index, piece) in pieces.enumerated() {
            if offset < position + piece.length { return (index, offset - position) }
            position += piece.length
        }
        return (pieces.count, 0)
    }

    /// Cuts out `range` (already limited to the content) and puts `content` where
    /// it was, as one edit. Nothing changes if it is refused.
    private mutating func replace(
        _ range: Range<Int64>,
        with content: Content,
        joiningRun: Bool,
        opensRun: Bool,
        runEnd newRunEnd: Int64?
    ) throws {
        let (first, firstDelta) = locate(range.lowerBound)
        let (last, lastDelta) = locate(range.upperBound)

        // The pieces the cut touches: from the one it starts in, through the one
        // it ends in, unless it ends exactly where that one begins.
        var removeStart = first
        let removeEnd = (last < pieces.count && lastDelta > 0) ? last + 1 : last

        var replacement: [Piece] = []
        if first < pieces.count, firstDelta > 0 {
            replacement.append(pieces[first].keeping(first: firstDelta))
        }
        var addedBytes: [UInt8] = []
        switch content {
        case .nothing:
            break
        case .bytes(let bytes):
            replacement.append(Piece(origin: .added, start: Int64(added.count), length: Int64(bytes.count)))
            addedBytes = bytes
        case .run(let value, let count):
            replacement.append(Piece(origin: .run(value), start: 0, length: count))
        }
        if last < pieces.count, lastDelta > 0 {
            replacement.append(pieces[last].dropping(first: lastDelta))
        }

        // Typed bytes land one after another in the added bytes, so what was just
        // typed and what is being typed are one piece, not two.
        if removeStart > 0, let leading = replacement.first,
           case .added = leading.origin, case .added = pieces[removeStart - 1].origin,
           pieces[removeStart - 1].start + pieces[removeStart - 1].length == leading.start {
            var joined = pieces[removeStart - 1]
            joined.length += leading.length
            replacement[0] = joined
            removeStart -= 1
        }

        guard pieces.count - (removeEnd - removeStart) + replacement.count <= pieceLimit else {
            throw ByteEditError.tooManyPieces
        }
        guard added.count + addedBytes.count <= addedByteLimit else {
            throw ByteEditError.tooMuchAddedData
        }

        let edit = Edit(index: removeStart, removed: Array(pieces[removeStart..<removeEnd]), inserted: replacement)
        pieces.replaceSubrange(removeStart..<removeEnd, with: replacement)
        added.append(contentsOf: addedBytes)
        length += edit.insertedLength - edit.removedLength

        // An edit made after undoing past the saved state buries it for good.
        if let saved = savedDepth, saved > undoStack.count { savedDepth = nil }
        if joiningRun, !undoStack.isEmpty {
            undoStack[undoStack.count - 1].edits.append(edit)
        } else {
            undoStack.append(Group(edits: [edit]))
        }
        redoStack.removeAll()
        runOpen = opensRun
        runEnd = newRunEnd
        revision += 1
    }
}
