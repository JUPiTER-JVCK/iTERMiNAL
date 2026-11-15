import Foundation

/// Read-only random access to a run of bytes, wherever they come from.
///
/// Everything in the Bytes panel reads through this and never asks for "the
/// file": a 4 GB video is as cheap to open as a 4 KB note, because only the few
/// kilobytes on screen are ever fetched. Foundation only, so the rules are
/// checked in CI; showing the bytes is `BytesViewerPane`'s.
protocol ByteSource: AnyObject {
    /// How many bytes there are. Fixed for the life of the source.
    var count: Int64 { get }

    /// The bytes in `range`, limited to what exists.
    ///
    /// A range that runs past the end gives the bytes up to it; one that is
    /// empty or wholly outside gives none. It never throws and never traps.
    /// When bytes cannot be read (the file shrank, the disk went away) the
    /// result is the readable *prefix* of the range, never one with a hole in
    /// it, so a caller that gets fewer bytes than it asked for knows exactly
    /// which are missing: the last ones.
    func read(_ range: Range<Int64>) -> [UInt8]
}

extension ByteSource {
    /// `range` limited to `0..<count`.
    func clamped(_ range: Range<Int64>) -> Range<Int64> {
        let lower = min(max(range.lowerBound, 0), count)
        let upper = min(max(range.upperBound, lower), count)
        return lower..<upper
    }
}

/// Bytes held in memory: for the checks, and for anything small made on the spot.
final class DataByteSource: ByteSource {
    private let bytes: [UInt8]

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    var count: Int64 { Int64(bytes.count) }

    func read(_ range: Range<Int64>) -> [UInt8] {
        let limited = clamped(range)
        guard !limited.isEmpty else { return [] }
        return Array(bytes[Int(limited.lowerBound)..<Int(limited.upperBound)])
    }
}
