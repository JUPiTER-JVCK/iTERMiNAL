import Foundation

/// How a file is cut up for the map and the entropy graph.
///
/// The file is divided into `cellCount` runs of nearly equal length, one for each square of a
/// Hilbert-curve picture; and the cells are grouped, a power of two of them to a group, into
/// "windows", one for each point of the entropy graph. Both are plain arithmetic on the file's
/// length, so where a byte falls, and what a click means, is worked out here and checked, and
/// the views only draw.
///
/// - A file shorter than 4 bytes is one cell; otherwise there are as many cells as the largest
///   power of 4 that is not more than the file has bytes (so no cell is empty), up to `maxOrder`
///   steps of the curve. A file of 64 KB or more gets 256 by 256 cells; a small one gets about a
///   cell to a byte.
/// - A window is at least 256 bytes, enough for an entropy figure to mean something, and more as
///   the file grows, to 1 KiB from 256 KiB up: the entropy of a short run reads low even when it
///   is random (256 random bytes score about 7.2), and a graph whose random stretches sit well
///   short of 8 would mislead. There are at most 1,024 windows.
struct ByteMapLayout: Equatable {
    /// 2^8 = 256 cells a side, 65,536 in all.
    static let maxOrder = 8
    static let maxWindows = 1024

    /// The fewest bytes a window of a file of `length` may have: 256, or a 256th of the file if
    /// that is more, up to 1 KiB.
    static func minWindowBytes(forLength length: Int64) -> Int64 {
        min(max(length / 256, 256), 1024)
    }

    let length: Int64
    /// The steps of the Hilbert curve: the picture is `2^order` cells across.
    let order: Int
    /// A power of two, and a divisor of `cellCount`.
    let windowCount: Int

    init(length: Int64, maxOrder: Int = ByteMapLayout.maxOrder) {
        self.length = max(length, 0)
        let limit = min(max(maxOrder, 0), HilbertCurve.maxOrder)
        var order = 0
        while order < limit, Int64(HilbertCurve.cellCount(order: order + 1)) <= self.length {
            order += 1
        }
        self.order = order
        let cells = HilbertCurve.cellCount(order: order)
        let least = ByteMapLayout.minWindowBytes(forLength: self.length)
        let byBytes = Int(min(max(self.length / least, 1), Int64(ByteMapLayout.maxWindows)))
        let wanted = min(byBytes, cells)
        // The largest power of two that is not more than `wanted`.
        windowCount = 1 << (Int.bitWidth - 1 - wanted.leadingZeroBitCount)
    }

    /// Cells across the picture.
    var side: Int { 1 << order }
    var cellCount: Int { side * side }
    /// Cells in each window.
    var windowCells: Int { cellCount / windowCount }

    // MARK: Cells

    /// Where cell `index` starts, as `floor(index * length / cellCount)`, worked out so that it
    /// cannot overflow. `cellStart(cellCount)` is the length.
    func cellStart(_ index: Int) -> Int64 {
        let cells = Int64(cellCount)
        let i = Int64(min(max(index, 0), cellCount))
        let whole = length / cells
        let rest = length % cells
        return whole * i + (rest * i) / cells
    }

    /// The bytes of cell `index`, which touches the next one and leaves no byte out.
    func cellRange(_ index: Int) -> Range<Int64> {
        let i = min(max(index, 0), max(cellCount - 1, 0))
        return cellStart(i)..<cellStart(i + 1)
    }

    /// The cell that holds the byte at `offset`; one off either end is moved to the nearest cell.
    ///
    /// The cell is the greatest `i` with `floor(i * length / cellCount) <= offset`, which is
    /// `((offset + 1) * cellCount - 1) / length`; the product can be wider than 64 bits, so it
    /// is divided at full width.
    func cell(containing offset: Int64) -> Int {
        guard length > 0 else { return 0 }
        let position = min(max(offset, 0), length - 1)
        let product = (position + 1).multipliedFullWidth(by: Int64(cellCount))
        var high = product.high
        var low = product.low
        if low == 0 {
            high -= 1
            low = UInt64.max
        } else {
            low -= 1
        }
        let quotient = length.dividingFullWidth((high: high, low: low)).quotient
        return Int(min(max(quotient, 0), Int64(cellCount - 1)))
    }

    /// Where cell `index` is in the picture: its column and its row, from the top left.
    func point(ofCell index: Int) -> (x: Int, y: Int) {
        HilbertCurve.point(order: order, index: index)
    }

    /// The cell at a column and row of the picture.
    func cell(atX x: Int, y: Int) -> Int {
        HilbertCurve.index(order: order, x: x, y: y)
    }

    // MARK: Windows

    /// The bytes of window `index`: the cells it is made of.
    func windowRange(_ index: Int) -> Range<Int64> {
        let w = min(max(index, 0), windowCount - 1)
        return cellStart(w * windowCells)..<cellStart((w + 1) * windowCells)
    }

    func window(containing offset: Int64) -> Int {
        cell(containing: offset) / windowCells
    }

    func window(ofCell index: Int) -> Int {
        min(max(index, 0), cellCount - 1) / windowCells
    }
}

/// How many bytes of each class were seen in one cell.
struct ByteMapCell: Equatable {
    var zero = 0
    var full = 0
    var text = 0
    var control = 0
    var high = 0

    init() {}

    /// From counts indexed by `ByteClass.rawValue`.
    init(classCounts counts: [Int]) {
        func count(_ byteClass: ByteClass) -> Int {
            byteClass.rawValue < counts.count ? counts[byteClass.rawValue] : 0
        }
        zero = count(.zero)
        full = count(.full)
        text = count(.text)
        control = count(.control)
        high = count(.high)
    }

    /// Bytes behind this cell: all of them, or the sample taken from it.
    var total: Int { zero + full + text + control + high }

    subscript(byteClass: ByteClass) -> Int {
        switch byteClass {
        case .zero: return zero
        case .full: return full
        case .text: return text
        case .control: return control
        case .high: return high
        }
    }
}

/// What a pass over a file found: for each cell, which kinds of byte it holds; for each window,
/// how random it is; and how often each byte value occurs.
struct ByteMapAnalysis {
    let layout: ByteMapLayout
    /// In curve order, `layout.cellCount` of them.
    let cells: [ByteMapCell]
    /// Bits per byte, for each of the `layout.windowCount` windows.
    let windowEntropy: [Double]
    /// Bytes read for each window, and how many different values were among them.
    let windowBytes: [Int]
    let windowDistinct: [Int]
    /// 256 counts, indexed by byte value, of the bytes read.
    let histogram: [Int]
    /// When true only a sample of each cell was read, because the file is bigger than the pass
    /// is willing to read whole.
    let isSampled: Bool
    /// How many bytes are read from each cell when sampled; 0 when every byte was read.
    let sampleSize: Int64
    /// Bytes that could not be read, such as when the file shrank during the pass.
    let unreadBytes: Int64
    let readBytes: Int64
    /// Entropy of everything read, in bits per byte, and how many values it holds.
    let entropy: Double
    let distinctValues: Int

    var length: Int64 { layout.length }

    init(layout: ByteMapLayout, cells: [ByteMapCell], windowEntropy: [Double], windowBytes: [Int],
         windowDistinct: [Int], histogram: [Int], isSampled: Bool, sampleSize: Int64, unreadBytes: Int64) {
        self.layout = layout
        self.cells = cells
        self.windowEntropy = windowEntropy
        self.windowBytes = windowBytes
        self.windowDistinct = windowDistinct
        self.histogram = histogram
        self.isSampled = isSampled
        self.sampleSize = sampleSize
        self.unreadBytes = unreadBytes
        readBytes = Int64(histogram.reduce(0, +))
        entropy = Entropy.shannon(histogram: histogram)
        distinctValues = histogram.reduce(0) { $1 > 0 ? $0 + 1 : $0 }
    }
}
