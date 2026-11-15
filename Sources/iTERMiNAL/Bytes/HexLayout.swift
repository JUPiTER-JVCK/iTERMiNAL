import Foundation

/// The base a byte is written in. Foundation only, like the rest of what decides
/// where the characters go, so CI checks it.
enum ByteRadix: String, CaseIterable, Equatable {
    case hex, decimal, octal, binary

    /// Characters one byte takes, always: cells are zero-padded so columns line up.
    var cellWidth: Int {
        switch self {
        case .hex: return 2
        case .decimal, .octal: return 3
        case .binary: return 8
        }
    }

    var title: String {
        switch self {
        case .hex: return "Hex"
        case .decimal: return "Decimal"
        case .octal: return "Octal"
        case .binary: return "Binary"
        }
    }

    /// `byte` as it prints, as ASCII, appended to `out`.
    func append(_ byte: UInt8, to out: inout [UInt8]) {
        switch self {
        case .hex:
            out.append(ByteRadix.hexDigits[Int(byte >> 4)])
            out.append(ByteRadix.hexDigits[Int(byte & 0x0F)])
        case .decimal:
            out.append(0x30 + byte / 100)
            out.append(0x30 + (byte / 10) % 10)
            out.append(0x30 + byte % 10)
        case .octal:
            out.append(0x30 + (byte >> 6))
            out.append(0x30 + ((byte >> 3) & 7))
            out.append(0x30 + (byte & 7))
        case .binary:
            var bit: UInt8 = 0x80
            while bit > 0 {
                out.append(byte & bit == 0 ? 0x30 : 0x31)
                bit >>= 1
            }
        }
    }

    /// `byte` as it prints.
    func cell(_ byte: UInt8) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(8)
        append(byte, to: &out)
        return String(decoding: out, as: UTF8.self)
    }

    static let hexDigits: [UInt8] = Array("0123456789ABCDEF".utf8)
}

/// Where everything in one row of the dump goes, in characters.
///
/// A row is `offset  cells  text`: the offset in hex, a gap, one cell per byte
/// with a space between and a wider gap every `groupSize` bytes, a gap, and the
/// bytes as text. Drawing and hit-testing both work in these columns and a
/// monospaced font turns them into points, so the one place that knows the layout
/// is this one, and it is checked here rather than by looking at it.
struct HexGeometry: Equatable {
    /// The widths a person can choose between, and the ones Auto picks from.
    static let bytesPerRowChoices = [4, 8, 16, 24, 32, 48, 64]

    var bytesPerRow: Int
    /// Bytes to a group, or 0 for none. A gap of one more space follows each.
    var groupSize: Int
    var radix: ByteRadix
    /// Hex digits in the offset column; see `offsetDigits(forLength:)`.
    var offsetDigits: Int
    var showsText: Bool

    init(bytesPerRow: Int, groupSize: Int = 8, radix: ByteRadix = .hex, offsetDigits: Int = 8, showsText: Bool = true) {
        self.bytesPerRow = max(1, bytesPerRow)
        self.groupSize = max(0, groupSize)
        self.radix = radix
        self.offsetDigits = max(1, offsetDigits)
        self.showsText = showsText
    }

    // MARK: Columns

    /// Two spaces between the offset and the cells, and between the cells and the text.
    static let gutter = 2

    var cellsStart: Int { offsetDigits + HexGeometry.gutter }

    /// The column where byte `index` of a row starts.
    func cellColumn(_ index: Int) -> Int {
        let groups = groupSize > 0 ? index / groupSize : 0
        return cellsStart + index * (radix.cellWidth + 1) + groups
    }

    /// One past the last column of the last cell.
    var cellsEnd: Int { cellColumn(bytesPerRow - 1) + radix.cellWidth }

    var textStart: Int { cellsEnd + HexGeometry.gutter }

    /// The column where byte `index` shows as text.
    func textColumn(_ index: Int) -> Int { textStart + index }

    /// How wide a row is.
    var totalColumns: Int { showsText ? textStart + bytesPerRow : cellsEnd }

    enum Hit: Equatable {
        case offset
        case cell(Int)
        case text(Int)
        case none
    }

    /// What is at `column` of a row.
    func hit(column: Int) -> Hit {
        if column < cellsStart { return .offset }
        if column < cellsEnd {
            let relative = column - cellsStart
            let stride = radix.cellWidth + 1
            if groupSize > 0 {
                let groupWidth = groupSize * stride + 1
                let group = relative / groupWidth
                let within = min((relative % groupWidth) / stride, groupSize - 1)
                return .cell(group * groupSize + within)
            }
            return .cell(relative / stride)
        }
        if showsText, column >= textStart, column < textStart + bytesPerRow {
            return .text(column - textStart)
        }
        return .none
    }

    // MARK: Rows

    func rowCount(forLength length: Int64) -> Int64 {
        guard length > 0 else { return 0 }
        let per = Int64(bytesPerRow)
        return length / per + (length % per == 0 ? 0 : 1)
    }

    func rowStart(_ row: Int64) -> Int64 {
        row * Int64(bytesPerRow)
    }

    /// The row `offset` is in, and its place in it.
    func location(of offset: Int64) -> (row: Int64, index: Int) {
        let per = Int64(bytesPerRow)
        return (offset / per, Int(offset % per))
    }

    /// How many bytes row `row` has: all of them, but fewer on the last row.
    func bytesInRow(_ row: Int64, length: Int64) -> Int {
        let remaining = length - rowStart(row)
        return Int(max(0, min(Int64(bytesPerRow), remaining)))
    }

    /// The text of the row that starts at `offset`.
    ///
    /// `bytes` is what could be read for it, which may be fewer than `expected`
    /// — the last row of a file is short, and a file that shrank under the panel
    /// comes back short everywhere. Bytes expected but not read print as `?`, so
    /// a hole looks like one; bytes past `expected` print as blanks, so the text
    /// column keeps its place.
    func rowText(offset: Int64, bytes: [UInt8], expected: Int) -> String {
        var line = [UInt8](repeating: 0x20, count: totalColumns)
        let digits = HexGeometry.offsetText(offset, digits: offsetDigits)
        for (i, digit) in digits.enumerated() { line[i] = digit }

        var cell: [UInt8] = []
        cell.reserveCapacity(8)
        for index in 0..<max(0, min(expected, bytesPerRow)) {
            let column = cellColumn(index)
            if index < bytes.count {
                cell.removeAll(keepingCapacity: true)
                radix.append(bytes[index], to: &cell)
                for (i, digit) in cell.enumerated() { line[column + i] = digit }
                if showsText { line[textColumn(index)] = HexGeometry.textByte(bytes[index]) }
            } else {
                for i in 0..<radix.cellWidth { line[column + i] = 0x3F }
                if showsText { line[textColumn(index)] = 0x3F }
            }
        }
        return String(decoding: line, as: UTF8.self)
    }

    /// The offset column's text: uppercase hex, zero-padded, as ASCII.
    static func offsetText(_ offset: Int64, digits: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0x30, count: digits)
        var value = UInt64(max(0, offset))
        var i = digits - 1
        while value > 0, i >= 0 {
            out[i] = ByteRadix.hexDigits[Int(value & 0xF)]
            value >>= 4
            i -= 1
        }
        return out
    }

    /// A byte as the text column shows it: itself if it is printable ASCII, a dot if not.
    static func textByte(_ byte: UInt8) -> UInt8 {
        isPrintable(byte) ? byte : 0x2E
    }

    static func isPrintable(_ byte: UInt8) -> Bool {
        byte >= 0x20 && byte <= 0x7E
    }

    /// Enough digits for the offset of the last byte: eight up to 4 GB, then twelve,
    /// then sixteen. Depends only on the length, so the column never changes width
    /// as it is scrolled.
    static func offsetDigits(forLength length: Int64) -> Int {
        let last = max(length - 1, 0)
        if last <= 0xFFFF_FFFF { return 8 }
        if last <= 0xFFFF_FFFF_FFFF { return 12 }
        return 16
    }

    /// The most bytes a row can have and still fit `columns` characters, from the
    /// widths on offer; the narrowest if none do.
    static func fitting(columns: Int, groupSize: Int, radix: ByteRadix, offsetDigits: Int, showsText: Bool) -> Int {
        var best = bytesPerRowChoices[0]
        for candidate in bytesPerRowChoices {
            let geometry = HexGeometry(bytesPerRow: candidate, groupSize: groupSize, radix: radix,
                                       offsetDigits: offsetDigits, showsText: showsText)
            if geometry.totalColumns <= columns { best = candidate }
        }
        return best
    }
}
