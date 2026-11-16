import Foundation

/// The one pass over a file that the map and the entropy graph are made from.
///
/// It reads each cell of the layout in turn, once, counts the byte values in it, and from the
/// counts takes everything: the kinds of byte in the cell, the entropy of each window and the
/// byte histogram of the whole. It runs on a background queue, can be stopped between cells,
/// and says how far it has got.
///
/// A file up to `Limits.budget` bytes is read whole. A bigger one is *sampled*: each cell gives
/// up one aligned run of `Limits.sampleSize` bytes, and there are only as many cells as the
/// budget pays a sample for, so a 50 GB file costs about as much to map as a 1 GB one. Sampling
/// is plain in the result (`isSampled`), so the panel can say so.
enum ByteMapAnalyzer {
    struct Limits {
        /// The most bytes a pass will read: 1 GiB.
        var budget: Int64 = 1 << 30
        /// The run read from each cell of a file too big to be read whole, and the unit its start
        /// is aligned to: the 64 KB a `FileByteSource` reads at a time, so a sample is one read.
        var sampleSize: Int64 = 64 * 1024
        var maxOrder = ByteMapLayout.maxOrder

        static let standard = Limits()
    }

    /// The analysis of `source`, or nil if it is empty or `isCancelled` said to stop.
    ///
    /// `progress` is called now and then with how far along the pass is, from 0 to 1.
    static func analyze(
        _ source: ByteSource,
        limits: Limits = .standard,
        isCancelled: () -> Bool = { false },
        progress: (Double) -> Void = { _ in }
    ) -> ByteMapAnalysis? {
        let length = source.count
        guard length > 0 else { return nil }

        let budget = max(limits.budget, 1)
        // A sample is never more than the budget, so the budget always buys at least one.
        let sampleSize = min(max(limits.sampleSize, 1), budget)
        let isSampled = length > budget
        var maxOrder = limits.maxOrder
        if isSampled {
            // One sample to a cell, and no more samples than the budget buys.
            let samples = max(budget / sampleSize, 1)
            var affordable = 0
            while Int64(HilbertCurve.cellCount(order: affordable + 1)) <= samples, affordable < HilbertCurve.maxOrder {
                affordable += 1
            }
            maxOrder = min(maxOrder, affordable)
        }
        let layout = ByteMapLayout(length: length, maxOrder: maxOrder)
        let cellCount = layout.cellCount
        let windowCells = layout.windowCells

        var cells = [ByteMapCell](repeating: ByteMapCell(), count: cellCount)
        var windowEntropy: [Double] = []
        var windowBytes: [Int] = []
        var windowDistinct: [Int] = []
        windowEntropy.reserveCapacity(layout.windowCount)
        windowBytes.reserveCapacity(layout.windowCount)
        windowDistinct.reserveCapacity(layout.windowCount)

        var cellHistogram = [Int](repeating: 0, count: 256)
        var windowHistogram = [Int](repeating: 0, count: 256)
        var totalHistogram = [Int](repeating: 0, count: 256)
        var unread: Int64 = 0

        for index in 0..<cellCount {
            if isCancelled() { return nil }
            if index % 128 == 0 { progress(Double(index) / Double(cellCount)) }

            let span = layout.cellRange(index)
            let sample = isSampled ? sampleRange(in: span, size: sampleSize) : span
            let bytes = source.read(sample)
            unread += (sample.upperBound - sample.lowerBound) - Int64(bytes.count)

            bytes.withUnsafeBufferPointer { buffer in
                cellHistogram.withUnsafeMutableBufferPointer { counts in
                    for byte in buffer { counts[Int(byte)] &+= 1 }
                }
            }
            var classCounts = [Int](repeating: 0, count: ByteClass.allCases.count)
            for value in 0..<256 where cellHistogram[value] != 0 {
                let count = cellHistogram[value]
                classCounts[ByteClass.table[value].rawValue] += count
                windowHistogram[value] += count
                totalHistogram[value] += count
                cellHistogram[value] = 0
            }
            cells[index] = ByteMapCell(classCounts: classCounts)

            if (index + 1) % windowCells == 0 {
                windowEntropy.append(Entropy.shannon(histogram: windowHistogram))
                windowBytes.append(windowHistogram.reduce(0, +))
                windowDistinct.append(windowHistogram.reduce(0) { $1 > 0 ? $0 + 1 : $0 })
                for value in 0..<256 { windowHistogram[value] = 0 }
            }
        }
        progress(1)

        return ByteMapAnalysis(
            layout: layout,
            cells: cells,
            windowEntropy: windowEntropy,
            windowBytes: windowBytes,
            windowDistinct: windowDistinct,
            histogram: totalHistogram,
            isSampled: isSampled,
            sampleSize: isSampled ? sampleSize : 0,
            unreadBytes: unread
        )
    }

    /// The run of `size` bytes to read from `span`: the first aligned one in it, if there is
    /// room for one past the cell's start, and otherwise the first `size` bytes. The span of a
    /// sampled file is always longer than `size`.
    static func sampleRange(in span: Range<Int64>, size: Int64) -> Range<Int64> {
        let room = span.upperBound - span.lowerBound
        guard room > size else { return span }
        let pad = (size - span.lowerBound % size) % size
        let start = pad <= room - size ? span.lowerBound + pad : span.lowerBound
        return start..<(start + size)
    }
}
