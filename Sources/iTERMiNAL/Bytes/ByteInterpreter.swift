import Foundation

enum Endianness: String, CaseIterable, Equatable {
    case little, big

    var title: String {
        self == .little ? "Little-endian" : "Big-endian"
    }
}

/// One line of the inspector: what a name for the selected bytes reads as.
struct Interpretation: Equatable, Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

/// The selected bytes read as the things they might be: numbers of each size, a
/// character, text, a time, an address. The reading of a file is guessing, and
/// the guess is the point; a learner sees at a glance that `00 00 80 3F` is
/// 1.0 as a little-endian float and not as anything else. Foundation only, so
/// every reading is checked.
enum ByteInterpreter {
    /// Selections longer than this are read as text only up to this many bytes.
    static let maxTextBytes = 256

    /// What `bytes` might be. A reading appears only when there are enough bytes
    /// for it: a three-byte selection has no 32-bit rows.
    static func interpret(_ bytes: [UInt8], endianness: Endianness) -> [Interpretation] {
        guard !bytes.isEmpty else { return [] }
        var rows: [Interpretation] = []

        let first = bytes[0]
        rows.append(Interpretation(label: "uint8", value: unsigned(UInt64(first), width: 1)))
        rows.append(Interpretation(label: "int8", value: "\(Int8(bitPattern: first))"))
        rows.append(Interpretation(label: "binary", value: ByteRadix.binary.cell(first)))
        rows.append(Interpretation(label: "char", value: character(first)))

        if bytes.count >= 2 {
            let value = integer(bytes, width: 2, endianness)
            rows.append(Interpretation(label: "uint16", value: unsigned(value, width: 2)))
            rows.append(Interpretation(label: "int16", value: "\(Int16(bitPattern: UInt16(value)))"))
        }
        if bytes.count >= 4 {
            let value = integer(bytes, width: 4, endianness)
            let word = UInt32(value)
            rows.append(Interpretation(label: "uint32", value: unsigned(value, width: 4)))
            rows.append(Interpretation(label: "int32", value: "\(Int32(bitPattern: word))"))
            rows.append(Interpretation(label: "float32", value: "\(Float(bitPattern: word))"))
            rows.append(Interpretation(label: "Unix time", value: utcString(unixSeconds: Int64(word))))
        }
        if bytes.count >= 8 {
            let value = integer(bytes, width: 8, endianness)
            rows.append(Interpretation(label: "uint64", value: unsigned(value, width: 8)))
            rows.append(Interpretation(label: "int64", value: "\(Int64(bitPattern: value))"))
            rows.append(Interpretation(label: "float64", value: "\(Double(bitPattern: value))"))
            if let time = windowsTime(ticks: value) {
                rows.append(Interpretation(label: "Windows time", value: time))
            }
        }

        // Network order is network order, whatever the machine's: an address is
        // read the way it is written down.
        if bytes.count == 4 {
            rows.append(Interpretation(label: "IPv4", value: bytes.map { "\($0)" }.joined(separator: ".")))
        }
        if bytes.count == 6 {
            rows.append(Interpretation(label: "MAC", value: bytes.map { ByteRadix.hex.cell($0) }.joined(separator: ":")))
        }
        if let (value, size) = varint(bytes), size >= 2 {
            rows.append(Interpretation(label: "varint", value: "\(value) (\(size) bytes)"))
        }

        let text = Array(bytes.prefix(maxTextBytes))
        if let utf8 = String(validatingUTF8Bytes: text) {
            rows.append(Interpretation(label: "UTF-8", value: escaped(utf8)))
        }
        if text.count >= 2, text.count % 2 == 0 {
            var units: [UInt16] = []
            for i in stride(from: 0, to: text.count, by: 2) {
                units.append(UInt16(integer(Array(text[i..<(i + 2)]), width: 2, endianness)))
            }
            if let utf16 = String(validatingUTF16Units: units) {
                rows.append(Interpretation(label: "UTF-16", value: escaped(utf16)))
            }
        }
        return rows
    }

    // MARK: Pieces

    /// The first `width` bytes as a number in the given byte order.
    static func integer(_ bytes: [UInt8], width: Int, _ endianness: Endianness) -> UInt64 {
        var value: UInt64 = 0
        let slice = bytes.prefix(width)
        switch endianness {
        case .little:
            for byte in slice.reversed() { value = (value << 8) | UInt64(byte) }
        case .big:
            for byte in slice { value = (value << 8) | UInt64(byte) }
        }
        return value
    }

    /// `value` in decimal, and in hex beside it, as wide as the number is.
    private static func unsigned(_ value: UInt64, width: Int) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        let padded = String(repeating: "0", count: max(0, width * 2 - digits.count)) + digits
        return "\(value) (0x\(padded))"
    }

    private static func character(_ byte: UInt8) -> String {
        switch byte {
        case 0x20: return "space"
        case 0x00: return "NUL"
        case 0x0A: return "LF"
        case 0x0D: return "CR"
        case 0x09: return "TAB"
        case 0x1B: return "ESC"
        case 0x7F: return "DEL"
        default:
            if HexGeometry.isPrintable(byte) { return "'\(Character(UnicodeScalar(byte)))'" }
            return "not printable"
        }
    }

    /// Control characters spelled out, so a selection with a newline in it is one line.
    private static func escaped(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += "\\x" + ByteRadix.hex.cell(UInt8(scalar.value))
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    /// An unsigned LEB128 number — the varint of protobuf and WebAssembly — at the
    /// start of `bytes`, and how many bytes it takes; nil if it does not end within
    /// them or does not fit in 64 bits.
    static func varint(_ bytes: [UInt8]) -> (UInt64, Int)? {
        var value: UInt64 = 0
        for (index, byte) in bytes.enumerated() {
            guard index < 10 else { return nil }
            let part = UInt64(byte & 0x7F)
            if index == 9 && part > 1 { return nil }
            value |= part << UInt64(7 * index)
            if byte & 0x80 == 0 { return (value, index + 1) }
        }
        return nil
    }

    // MARK: Time

    /// "2009-02-13 23:31:30 UTC" for seconds since 1970. Worked out by hand from
    /// the calendar's own arithmetic, so it needs no locale, no time zone and no
    /// `Date`, and reads the same on every machine.
    static func utcString(unixSeconds: Int64) -> String {
        var days = unixSeconds / 86_400
        var rest = unixSeconds % 86_400
        if rest < 0 {
            rest += 86_400
            days -= 1
        }
        // Days since 1970-01-01 to a calendar date: Howard Hinnant's civil_from_days.
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d UTC",
                      Int(year), Int(month), Int(day), Int(rest / 3600), Int(rest % 3600 / 60), Int(rest % 60))
    }

    /// A Windows FILETIME — 100-nanosecond ticks since 1601 — as a date, if it
    /// lands between 1980 and 2100, which is where a real one does; nil otherwise,
    /// since most 64-bit numbers are not dates and a row of nonsense helps no one.
    static func windowsTime(ticks: UInt64) -> String? {
        let seconds = Int64(ticks / 10_000_000) - 11_644_473_600
        guard seconds >= 315_532_800, seconds < 4_102_444_800 else { return nil }
        return utcString(unixSeconds: seconds)
    }
}

private extension String {
    /// The text `bytes` is, if it is valid UTF-8 from end to end.
    init?(validatingUTF8Bytes bytes: [UInt8]) {
        var decoder = UTF8()
        var iterator = bytes.makeIterator()
        var scalars = String.UnicodeScalarView()
        decoding: while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar): scalars.append(scalar)
            case .emptyInput: break decoding
            case .error: return nil
            }
        }
        self = String(scalars)
    }

    /// The text `units` is, if it is valid UTF-16 from end to end.
    init?(validatingUTF16Units units: [UInt16]) {
        var decoder = UTF16()
        var iterator = units.makeIterator()
        var scalars = String.UnicodeScalarView()
        decoding: while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar): scalars.append(scalar)
            case .emptyInput: break decoding
            case .error: return nil
            }
        }
        self = String(scalars)
    }
}
