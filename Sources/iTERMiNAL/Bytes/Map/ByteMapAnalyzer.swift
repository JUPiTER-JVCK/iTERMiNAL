import Foundation

/// The one pass over a file that the map and the entropy graph are made from.
///
/// It reads each cell of the layout once, counts the byte values in it, and from the counts takes
/// everything: the kinds of byte in the cell, the entropy of each window and the byte histogram of
/// the whole. It runs on a background queue, can be stopped, and says how far it has got.
///
/// A file up to `Limits.budget` bytes is read whole. A bigger one is *sampled*: each cell gives
/// up one aligned run of `Limits.sampleSize` bytes, and there are only as many cells as the
/// budget pays a sample for, so a 50 GB file costs about as much to map as a 1 GB one. Sampling
/// is plain in the result (`isSampled`), so the panel can say so.
///
/// A pass that reads at least `Limits.parallelMinimum` bytes is shared among `Limits.workers`
/// threads. Each takes whole windows, so no window is split between two threads, and what they
/// find is the same to the bit as what one thread finds: the counts are sums of whole numbers, and
/// each window's entropy comes from that window's counts alone.
enum ByteMapAnalyzer {
    struct Limits {
        /// The most bytes a pass will read: 1 GiB.
        var budget: Int64 = 1 << 30
        /// The run read from each cell of a file too big to be read whole, and the unit its start
        /// is aligned to: the 64 KB a `FileByteSource` reads at a time, so a sample is one read.
        var sampleSize: Int64 = 64 * 1024
        var maxOrder = ByteMapLayout.maxOrder
        /// How many threads may read the source at once. One unless the caller asks for more,
        /// because more needs a source that is safe to read from several threads at the same time,
        /// which `ByteSource` does not promise. `FileByteSource` is, as are `DataByteSource` (it
        /// never changes) and `EditedBytesSource` (a copy of the edits, over a `FileByteSource`).
        /// Only threads that do not wait on one another are any faster, though: a `FileByteSource`
        /// opened with `caching: false`, or bytes in memory, not reads through a page cache's lock.
        var workers = 1
        /// The fewest bytes a pass must read before it is shared among `workers`. A smaller pass is
        /// over in a few milliseconds on one thread.
        var parallelMinimum: Int64 = 16 << 20
        /// About how much each thread reads before the threads all meet. Only then is the pass asked
        /// whether to stop, and only then does it say how far it has got, so this is also about how
        /// much more one thread reads once the pass is told to stop.
        var runBytes: Int64 = 4 << 20

        static let standard = Limits()
    }

    /// The analysis of `source`, or nil if it is empty or `isCancelled` said to stop.
    ///
    /// `progress` is called now and then with how far along the pass is, from 0 to 1. It and
    /// `isCancelled` are only ever called on the thread that called this, however many threads
    /// read the file.
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
        let pass = Pass(source: source, layout: layout, sampleSize: isSampled ? sampleSize : nil)

        var cells = [ByteMapCell](repeating: ByteMapCell(), count: layout.cellCount)
        var windowEntropy = [Double](repeating: 0, count: layout.windowCount)
        var windowBytes = [Int](repeating: 0, count: layout.windowCount)
        var windowDistinct = [Int](repeating: 0, count: layout.windowCount)
        var tally = Tally()

        let toRead = isSampled ? min(length, Int64(layout.cellCount) * sampleSize) : length
        let workers = toRead >= limits.parallelMinimum ? min(max(limits.workers, 1), layout.windowCount) : 1
        let perWindow = max(toRead / Int64(layout.windowCount), 1)
        let runWindows = Int(min(max(limits.runBytes / perWindow, 1), Int64(layout.windowCount)))

        let finished = cells.withUnsafeMutableBufferPointer { cellsOut in
            windowEntropy.withUnsafeMutableBufferPointer { entropyOut in
                windowBytes.withUnsafeMutableBufferPointer { bytesOut in
                    windowDistinct.withUnsafeMutableBufferPointer { distinctOut in
                        let out = Output(cells: cellsOut, entropy: entropyOut, bytes: bytesOut, distinct: distinctOut)
                        if workers == 1 {
                            return pass.count(windows: 0..<layout.windowCount, into: out, tally: &tally, isCancelled: isCancelled) { cell in
                                if cell % 128 == 0 { progress(Double(cell) / Double(layout.cellCount)) }
                            }
                        }
                        return pass.countShared(workers: workers, runWindows: runWindows, into: out, tally: &tally,
                                                isCancelled: isCancelled, progress: progress)
                    }
                }
            }
        }
        guard finished else { return nil }
        progress(1)

        return ByteMapAnalysis(
            layout: layout,
            cells: cells,
            windowEntropy: windowEntropy,
            windowBytes: windowBytes,
            windowDistinct: windowDistinct,
            histogram: tally.histogram,
            isSampled: isSampled,
            sampleSize: isSampled ? sampleSize : 0,
            unreadBytes: tally.unread
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

    /// Adds how often each value occurs in `bytes` to `tables`: four tables of 256 counts end to
    /// end, each counting every fourth byte, so that in a run of one value each count does not have
    /// to wait for the one before it. A value's count is the sum of its four.
    static func countValues(_ bytes: [UInt8], into tables: inout [Int]) {
        precondition(tables.count == 1024, "four tables of 256 counts")
        bytes.withUnsafeBufferPointer { buffer in
            tables.withUnsafeMutableBufferPointer { counts in
                let total = buffer.count
                var index = 0
                while index + 4 <= total {
                    counts[Int(buffer[index])] &+= 1
                    counts[256 + Int(buffer[index + 1])] &+= 1
                    counts[512 + Int(buffer[index + 2])] &+= 1
                    counts[768 + Int(buffer[index + 3])] &+= 1
                    index += 4
                }
                while index < total {
                    counts[Int(buffer[index])] &+= 1
                    index += 1
                }
            }
        }
    }

    // MARK: The pass

    /// What every thread of a pass reads from and none of them changes.
    private struct Pass {
        let source: ByteSource
        let layout: ByteMapLayout
        /// The run read from each cell when the file is sampled; nil when it is read whole.
        let sampleSize: Int64?

        /// Counts each cell of `windows`, writes what it finds into `out` at those cells and
        /// windows, and adds it to `tally`. Gives false if `isCancelled`, asked before each cell,
        /// said to stop. `starting` is given each cell's index before the cell is read.
        func count(windows: Range<Int>, into out: Output, tally: inout Tally,
                   isCancelled: () -> Bool, starting: (Int) -> Void) -> Bool {
            let windowCells = layout.windowCells
            var tables = [Int](repeating: 0, count: 1024)
            var windowHistogram = [Int](repeating: 0, count: 256)
            for window in windows {
                for index in (window * windowCells)..<((window + 1) * windowCells) {
                    if isCancelled() { return false }
                    starting(index)

                    let span = layout.cellRange(index)
                    let sample = sampleSize.map { ByteMapAnalyzer.sampleRange(in: span, size: $0) } ?? span
                    let bytes = source.read(sample)
                    tally.unread += (sample.upperBound - sample.lowerBound) - Int64(bytes.count)

                    ByteMapAnalyzer.countValues(bytes, into: &tables)
                    var classCounts = [Int](repeating: 0, count: ByteClass.allCases.count)
                    tables.withUnsafeMutableBufferPointer { counts in
                        // Takes a value's count out of the tables, leaving them clear for the next cell.
                        func take(_ value: Int) {
                            let count = counts[value] + counts[256 + value] + counts[512 + value] + counts[768 + value]
                            guard count != 0 else { return }
                            classCounts[ByteClass.table[value].rawValue] += count
                            windowHistogram[value] += count
                            counts[value] = 0
                            counts[256 + value] = 0
                            counts[512 + value] = 0
                            counts[768 + value] = 0
                        }
                        // A cell of fewer bytes than there are values holds only its own: a map of a
                        // million bytes has 65,536 cells of about 15 bytes, and looking at all 256
                        // values after each cost more than counting the cell's bytes.
                        if bytes.count < 256 {
                            for byte in bytes { take(Int(byte)) }
                        } else {
                            for value in 0..<256 { take(value) }
                        }
                    }
                    out.cells[index] = ByteMapCell(classCounts: classCounts)
                }
                out.entropy[window] = Entropy.shannon(histogram: windowHistogram)
                out.bytes[window] = windowHistogram.reduce(0, +)
                out.distinct[window] = windowHistogram.reduce(0) { $1 > 0 ? $0 + 1 : $0 }
                for value in 0..<256 {
                    tally.histogram[value] += windowHistogram[value]
                    windowHistogram[value] = 0
                }
            }
            return true
        }

        /// Counts every window among `workers` threads, in rounds: in each, every thread takes a run
        /// of `runWindows` windows. Between rounds, on the calling thread, it asks `isCancelled` and
        /// reports progress, so neither is ever called from two threads or while a thread reads.
        func countShared(workers: Int, runWindows: Int, into out: Output, tally: inout Tally,
                         isCancelled: () -> Bool, progress: (Double) -> Void) -> Bool {
            let windowCount = layout.windowCount
            var partials = [Tally](repeating: Tally(), count: workers)
            var next = 0
            while next < windowCount {
                if isCancelled() { return false }
                progress(Double(next) / Double(windowCount))
                let first = next
                let runs = min(workers, (windowCount - first + runWindows - 1) / runWindows)
                partials.withUnsafeMutableBufferPointer { results in
                    DispatchQueue.concurrentPerform(iterations: runs) { run in
                        let lower = first + run * runWindows
                        let upper = min(lower + runWindows, windowCount)
                        var mine = Tally()
                        _ = count(windows: lower..<upper, into: out, tally: &mine, isCancelled: { false }, starting: { _ in })
                        results[run] = mine
                    }
                }
                for run in 0..<runs { tally.add(partials[run]) }
                next = min(first + runs * runWindows, windowCount)
            }
            return true
        }
    }

    /// Where a pass writes what it finds. Two threads never write the same cell or window.
    private struct Output {
        let cells: UnsafeMutableBufferPointer<ByteMapCell>
        let entropy: UnsafeMutableBufferPointer<Double>
        let bytes: UnsafeMutableBufferPointer<Int>
        let distinct: UnsafeMutableBufferPointer<Int>
    }

    /// The counts a pass, or one thread's share of it, adds up as it goes.
    private struct Tally {
        var histogram = [Int](repeating: 0, count: 256)
        var unread: Int64 = 0

        mutating func add(_ other: Tally) {
            for value in 0..<256 { histogram[value] += other.histogram[value] }
            unread += other.unread
        }
    }
}
