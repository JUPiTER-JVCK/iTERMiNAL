import Foundation

/// The five kinds of byte the map tells apart. Zeros and 0xFF are their own kinds because
/// they are what padding, empty space and erased flash are made of; the rest are split by what
/// a person would see if the byte were text.
enum ByteClass: Int, CaseIterable {
    /// 0x00.
    case zero
    /// 0xFF.
    case full
    /// Printable ASCII (0x20 to 0x7E), tab, line feed and carriage return.
    case text
    /// The other control codes: 0x01 to 0x1F without the three above, and 0x7F.
    case control
    /// 0x80 to 0xFE: not ASCII, so a byte of something other than plain text.
    case high

    static func of(_ byte: UInt8) -> ByteClass {
        table[Int(byte)]
    }

    /// The class of each of the 256 byte values.
    static let table: [ByteClass] = (0..<256).map { value in
        switch value {
        case 0x00: return .zero
        case 0xFF: return .full
        case 0x09, 0x0A, 0x0D, 0x20...0x7E: return .text
        case 0x80...0xFE: return .high
        default: return .control
        }
    }

    var title: String {
        switch self {
        case .zero: return "zeros"
        case .full: return "0xFF"
        case .text: return "text"
        case .control: return "control codes"
        case .high: return "bytes 80 to FE"
        }
    }

    /// What it is, in a line, for a legend.
    var detail: String {
        switch self {
        case .zero: return "0x00: padding, empty space"
        case .full: return "0xFF: erased or filled space"
        case .text: return "Printable ASCII, tab and line breaks"
        case .control: return "Other control codes"
        case .high: return "0x80 to 0xFE: not plain ASCII"
        }
    }

    /// How many bytes of each class a 256-bin histogram holds, indexed by `rawValue`.
    static func counts(inHistogram histogram: [Int]) -> [Int] {
        var counts = [Int](repeating: 0, count: allCases.count)
        for value in 0..<min(histogram.count, 256) where histogram[value] != 0 {
            counts[table[value].rawValue] += histogram[value]
        }
        return counts
    }
}

/// How random a run of bytes is, in bits per byte.
///
/// Shannon entropy of the byte values: 0 when every byte is the same, 8 when all 256 values
/// are equally likely. English text sits near 4, program code between 5 and 6.5, and
/// compressed, encrypted or random data close to 8, which is how it is told from the rest.
enum Entropy {
    static let maxBits = 8.0

    /// The entropy of a 256-bin histogram of byte counts: -sum(p * log2 p). 0 for no bytes.
    static func shannon(histogram: [Int]) -> Double {
        var total = 0
        for value in 0..<min(histogram.count, 256) { total += max(histogram[value], 0) }
        guard total > 0 else { return 0 }
        let size = Double(total)
        var bits = 0.0
        for value in 0..<min(histogram.count, 256) where histogram[value] > 0 {
            let p = Double(histogram[value]) / size
            bits -= p * log2(p)
        }
        return min(max(bits, 0), maxBits)
    }

    static func shannon(_ bytes: [UInt8]) -> Double {
        var histogram = [Int](repeating: 0, count: 256)
        for byte in bytes { histogram[Int(byte)] += 1 }
        return shannon(histogram: histogram)
    }

    /// `bits` with the shortfall of a small sample made good (the Miller-Madow correction).
    ///
    /// The entropy of a few hundred bytes reads low even when they are random: 256 random
    /// bytes score about 7.2, not 8, because some values turn up twice and others not at all.
    /// Adding `(values seen - 1) / (2 * bytes * ln 2)` puts it back, and for a run of a few
    /// thousand bytes or more the addition is too small to see. `distinct` is how many of the
    /// 256 values were seen.
    static func corrected(bits: Double, bytes: Int64, distinct: Int) -> Double {
        guard bytes > 0, distinct > 1 else { return min(max(bits, 0), maxBits) }
        let shortfall = Double(distinct - 1) / (2 * Double(bytes) * M_LN2)
        return min(max(bits + shortfall, 0), maxBits)
    }
}

/// An entropy figure put into words.
enum EntropyReading {
    /// Fewer bytes than this say too little about how random they are to be worth a word.
    static let fewestBytes: Int64 = 64

    /// What `bits` per byte, measured over `bytes` bytes of which `distinct` different values
    /// were seen, is typical of.
    ///
    /// These are rules of thumb for studying a file, not a verdict: a photograph's pixels, a
    /// font and a compressed archive can all read alike.
    static func describe(bits: Double, bytes: Int64, distinct: Int) -> String {
        guard bytes >= fewestBytes else { return "too few bytes to say" }
        switch Entropy.corrected(bits: bits, bytes: bytes, distinct: distinct) {
        case ..<0.5: return "almost all one value: zeros or padding"
        case ..<2.0: return "very repetitive: padding, long runs or sparse data"
        case ..<3.5: return "repetitive: tables, simple data or runs"
        case ..<5.2: return "text or structured data"
        case ..<6.8: return "program code or dense binary data"
        case ..<7.5: return "dense binary or lightly compressed data"
        default: return "random-looking: compressed, encrypted or noise"
        }
    }
}
