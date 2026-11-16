import Foundation

/// Looks through a file for bytes, a piece at a time, without ever holding more than a piece.
///
/// A JPEG's compressed image and a PDF's objects have no lengths to jump by: where they end is
/// found by reading until a marker or a keyword turns up. A scanner does that reading in
/// 64 KB pieces, counts what it has read against a budget so a huge or hostile file cannot
/// keep a parser busy for ever, and can be stopped.
final class SourceScanner {
    static let pieceSize = 64 * 1024

    let source: ByteSource
    /// Bytes this scanner may still read.
    private(set) var budget: Int64
    private let isCancelled: () -> Bool
    private var piece = ByteWindow(base: 0, bytes: [])

    init(source: ByteSource, budget: Int64, isCancelled: @escaping () -> Bool = { false }) {
        self.source = source
        self.budget = max(budget, 0)
        self.isCancelled = isCancelled
    }

    /// True once the budget is spent or the parse was stopped: a search that came back empty
    /// then means "not looked for", not "not there".
    var isExhausted: Bool { budget <= 0 || isCancelled() }

    /// The byte at `offset`, or nil past the end of the file or of the budget.
    func byte(at offset: Int64) -> UInt8? {
        guard offset >= 0, offset < source.count else { return nil }
        if !piece.has(offset, 1) {
            guard !isExhausted else { return nil }
            let aligned = offset - offset % Int64(SourceScanner.pieceSize)
            piece = ByteWindow(source: source, at: aligned, count: SourceScanner.pieceSize)
            budget -= Int64(piece.bytes.count)
            guard piece.has(offset, 1) else { return nil }
        }
        return piece.bytes[Int(offset - piece.base)]
    }

    /// Up to `count` bytes from `offset`: fewer at the end of the file or of the budget.
    func bytes(at offset: Int64, count: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(max(0, min(count, 4096)))
        var at = offset
        while out.count < count, let value = byte(at: at) {
            out.append(value)
            at += 1
        }
        return out
    }

    /// Whether the bytes at `offset` are exactly `pattern`.
    func matches(_ pattern: [UInt8], at offset: Int64) -> Bool {
        for (index, wanted) in pattern.enumerated() where byte(at: offset + Int64(index)) != wanted {
            return false
        }
        return true
    }

    /// Where `pattern` first starts at or after `from` and wholly before `end`; nil if it does
    /// not, or if the budget ran out first.
    func find(_ pattern: [UInt8], from: Int64, end: Int64) -> Int64? {
        guard let first = pattern.first else { return nil }
        let last = min(end, source.count) - Int64(pattern.count)
        var at = max(from, 0)
        while at <= last {
            guard let value = byte(at: at) else { return nil }
            if value == first, matches(pattern, at: at) { return at }
            at += 1
        }
        return nil
    }

    /// The first offset at or after `from`, and before `end`, whose byte satisfies `test`.
    func first(from: Int64, end: Int64, where test: (UInt8) -> Bool) -> Int64? {
        var at = max(from, 0)
        let stop = min(end, source.count)
        while at < stop {
            guard let value = byte(at: at) else { return nil }
            if test(value) { return at }
            at += 1
        }
        return nil
    }
}
