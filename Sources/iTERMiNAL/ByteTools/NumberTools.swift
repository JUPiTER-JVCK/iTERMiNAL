import Foundation

/// A whole number as typed: its sign, its size and the base it was written in.
struct ParsedInteger: Equatable {
    var isNegative: Bool
    var magnitude: BigNumber
    /// The base the text said (a 0x / 0b / 0o prefix) or the one it was read in.
    var base: Int

    var isZero: Bool { magnitude.isZero }
}

enum IntegerInput {
    /// Reads `text` as a whole number. A `0x`, `0b` or `0o` prefix (after an
    /// optional sign) chooses the base; otherwise `defaultBase` is used. Spaces,
    /// underscores and commas inside the number are ignored, so `1,000` and
    /// `0b1010_0101` read as they look.
    ///
    /// With `allowPrefixes` false the digits are always in `defaultBase`: in base
    /// 12 a `0b` is the digits 0 and B, not a binary marker.
    static func parse(_ text: String, defaultBase: Int = 10, allowPrefixes: Bool = true) -> Result<ParsedInteger, ByteFormatProblem> {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            return .failure(ByteFormatProblem(message: "Type a number."))
        }
        var negative = false
        if body.hasPrefix("-") {
            negative = true
            body.removeFirst()
        } else if body.hasPrefix("+") {
            body.removeFirst()
        }
        var base = defaultBase
        let lower = body.lowercased()
        if !allowPrefixes {
            // Digits only, in the base asked for.
        } else if lower.hasPrefix("0x") { base = 16; body.removeFirst(2) }
        else if lower.hasPrefix("0b") && defaultBase != 16 { base = 2; body.removeFirst(2) }
        else if lower.hasPrefix("0o") { base = 8; body.removeFirst(2) }
        else if lower.hasPrefix("#") || lower.hasPrefix("$") { base = 16; body.removeFirst() }
        body = body.filter { !" _,\n\t".contains($0) }
        guard !body.isEmpty else {
            return .failure(ByteFormatProblem(message: "Type a number after the prefix."))
        }
        guard let magnitude = BigNumber(digits: body, base: base) else {
            let digit = body.first(where: { char in
                guard let scalar = char.unicodeScalars.first, let value = BigNumber.digitValue(scalar) else { return true }
                return value >= base
            }) ?? "?"
            return .failure(ByteFormatProblem(message: "“\(digit)” is not a digit in base \(base)."))
        }
        return .success(ParsedInteger(isNegative: negative && !magnitude.isZero, magnitude: magnitude, base: base))
    }
}

/// How digits are grouped for reading: binary in nibbles, hex in bytes, decimal
/// in thousands, and so on, always counted from the right.
enum DigitGrouping {
    static func group(_ digits: String, size: Int, separator: String) -> String {
        guard size > 0, digits.count > size else { return digits }
        var parts: [String] = []
        var end = digits.endIndex
        while end > digits.startIndex {
            let start = digits.index(end, offsetBy: -size, limitedBy: digits.startIndex) ?? digits.startIndex
            parts.append(String(digits[start..<end]))
            end = start
        }
        return parts.reversed().joined(separator: separator)
    }

    /// The usual grouping for a base: 4 for binary, 2 for hex, 3 for octal and decimal, 0 for none.
    static func defaultSize(forBase base: Int) -> Int {
        switch base {
        case 2: return 4
        case 16: return 2
        case 8, 10: return 3
        default: return 0
        }
    }
}

enum NumberText {
    /// `magnitude` in `base`, with a minus sign if negative, optionally grouped.
    static func text(_ number: ParsedInteger, base: Int, grouped: Bool, uppercase: Bool = true) -> String {
        var digits = number.magnitude.toString(base: base, uppercase: uppercase)
        if base == 2, grouped, digits.count % 4 != 0 {
            digits = String(repeating: "0", count: 4 - digits.count % 4) + digits
        }
        if base == 16, grouped, digits.count % 2 != 0 { digits = "0" + digits }
        if grouped {
            let size = DigitGrouping.defaultSize(forBase: base)
            digits = DigitGrouping.group(digits, size: size, separator: base == 10 ? "," : " ")
        }
        return (number.isNegative ? "-" : "") + digits
    }

    /// The conventional prefix for a base, or "" for decimal and the rest.
    static func prefix(forBase base: Int) -> String {
        switch base {
        case 2: return "0b"
        case 8: return "0o"
        case 16: return "0x"
        default: return ""
        }
    }
}

// MARK: - Bit patterns

/// A fixed-width run of bits — the bits themselves, which are neither signed
/// nor unsigned until read one way or the other. Backs Bits & bytes (switches),
/// Two's complement, and the Bitwise calculator.
struct BitPattern: Equatable {
    static let widths = [8, 16, 32, 64]

    let width: Int
    /// The bits, held in the low `width` bits.
    private(set) var value: UInt64

    init(width: Int, value: UInt64) {
        precondition(width >= 1 && width <= 64)
        self.width = width
        self.value = value & BitPattern.mask(width)
    }

    static func mask(_ width: Int) -> UInt64 {
        width >= 64 ? UInt64.max : (UInt64(1) << UInt64(width)) - 1
    }

    var unsigned: UInt64 { value }

    /// The same bits read as a two's-complement number.
    var signed: Int64 {
        guard width < 64 else { return Int64(bitPattern: value) }
        let signBit = UInt64(1) << UInt64(width - 1)
        return value & signBit != 0 ? Int64(bitPattern: value | ~BitPattern.mask(width)) : Int64(value)
    }

    var isNegative: Bool { value >> UInt64(width - 1) & 1 == 1 }

    /// The bits from the highest to the lowest.
    var bits: [Bool] {
        (0..<width).reversed().map { value >> UInt64($0) & 1 == 1 }
    }

    /// The pattern with the bit at `index` (0 is the lowest) turned over.
    func flipping(_ index: Int) -> BitPattern {
        guard (0..<width).contains(index) else { return self }
        return BitPattern(width: width, value: value ^ (UInt64(1) << UInt64(index)))
    }

    /// Every bit turned over (the one's complement).
    var inverted: BitPattern { BitPattern(width: width, value: ~value) }

    /// Inverted, then one added — negation in two's complement.
    var negated: BitPattern { BitPattern(width: width, value: (~value) &+ 1) }

    /// The largest and smallest numbers this width can hold.
    static func signedRange(width: Int) -> (min: Int64, max: Int64) {
        width >= 64 ? (Int64.min, Int64.max) : (-(Int64(1) << Int64(width - 1)), (Int64(1) << Int64(width - 1)) - 1)
    }

    static func unsignedMax(width: Int) -> UInt64 { mask(width) }

    /// The bits a typed number stands for at this width. A negative number is
    /// written in two's complement; a positive one may use the whole width
    /// (200 fits 8 bits, and reads as −56 when taken as signed).
    static func from(_ number: ParsedInteger, width: Int) -> Result<BitPattern, ByteFormatProblem> {
        let range = signedRange(width: width)
        if number.isNegative {
            // magnitude <= 2^(width-1)
            let limit = UInt64(1) << UInt64(width - 1)
            guard let magnitude = number.magnitude.asUInt64, magnitude <= limit else {
                return .failure(ByteFormatProblem(message: "−\(number.magnitude.toString(base: 10)) does not fit in \(width) bits (\(range.min) to \(range.max))."))
            }
            return .success(BitPattern(width: width, value: (~magnitude) &+ 1))
        }
        guard let magnitude = number.magnitude.asUInt64, magnitude <= unsignedMax(width: width) else {
            return .failure(ByteFormatProblem(message: "\(number.magnitude.toString(base: 10)) does not fit in \(width) bits (0 to \(unsignedMax(width: width)))."))
        }
        return .success(BitPattern(width: width, value: magnitude))
    }

    /// The bytes of the pattern, most significant first.
    var bytes: [UInt8] {
        (0..<((width + 7) / 8)).reversed().map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
    }

    /// The smallest standard width that holds `byteCount` bytes, or nil beyond eight.
    static func width(forByteCount byteCount: Int) -> Int? {
        switch byteCount {
        case 1: return 8
        case 2: return 16
        case 3, 4: return 32
        case 5...8: return 64
        default: return nil
        }
    }

    init?(bytes: [UInt8]) {
        guard let width = BitPattern.width(forByteCount: bytes.count) else { return nil }
        var value: UInt64 = 0
        for byte in bytes { value = value << 8 | UInt64(byte) }
        self.init(width: width, value: value)
    }
}

// MARK: - Bitwise operations

enum BitwiseOperation: String, CaseIterable, Identifiable {
    case and, or, xor, nand, nor, xnor, not
    case shiftLeft, shiftRight, arithmeticShiftRight, rotateLeft, rotateRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .and: return "AND"
        case .or: return "OR"
        case .xor: return "XOR"
        case .nand: return "NAND"
        case .nor: return "NOR"
        case .xnor: return "XNOR"
        case .not: return "NOT"
        case .shiftLeft: return "A << n"
        case .shiftRight: return "A >> n"
        case .arithmeticShiftRight: return "A >>> n"
        case .rotateLeft: return "ROL"
        case .rotateRight: return "ROR"
        }
    }

    var symbol: String {
        switch self {
        case .and: return "&"
        case .or: return "|"
        case .xor: return "^"
        case .nand: return "~&"
        case .nor: return "~|"
        case .xnor: return "~^"
        case .not: return "~"
        case .shiftLeft: return "<<"
        case .shiftRight: return ">>"
        case .arithmeticShiftRight: return ">>>"
        case .rotateLeft: return "ROL"
        case .rotateRight: return "ROR"
        }
    }

    /// The second field is a number of places, not a second operand.
    var secondIsCount: Bool {
        switch self {
        case .shiftLeft, .shiftRight, .arithmeticShiftRight, .rotateLeft, .rotateRight: return true
        default: return false
        }
    }

    /// There is no second field at all.
    var isUnary: Bool { self == .not }

    var explanation: String {
        switch self {
        case .and: return "1 only where both have a 1 — keeps the bits of A that B also has (a mask)."
        case .or: return "1 where either has a 1 — turns on the bits of B."
        case .xor: return "1 where they differ — flips the bits of A that B has set."
        case .nand: return "AND, then every bit turned over."
        case .nor: return "OR, then every bit turned over."
        case .xnor: return "1 where they are the same."
        case .not: return "Every bit of A turned over (the one's complement)."
        case .shiftLeft: return "Slide the bits left, filling with 0 — multiplies by 2 for each place."
        case .shiftRight: return "Slide the bits right, filling with 0 — divides by 2, rounding down."
        case .arithmeticShiftRight: return "Slide right, copying the sign bit in — divides a signed number by 2."
        case .rotateLeft: return "Slide left; what falls off the top comes back at the bottom."
        case .rotateRight: return "Slide right; what falls off the bottom comes back at the top."
        }
    }

    /// `a` (and `b`) at `width`. `b` is the count for shifts and rotates, taken
    /// modulo the width for rotates; a shift by the width or more gives 0 (or
    /// the sign, for the arithmetic shift).
    func apply(_ a: BitPattern, _ b: BitPattern) -> BitPattern {
        let width = a.width
        let mask = BitPattern.mask(width)
        let x = a.unsigned
        let y = b.unsigned & mask
        let count = Int(min(b.unsigned, UInt64(width)))
        let result: UInt64
        switch self {
        case .and: result = x & y
        case .or: result = x | y
        case .xor: result = x ^ y
        case .nand: result = ~(x & y)
        case .nor: result = ~(x | y)
        case .xnor: result = ~(x ^ y)
        case .not: result = ~x
        case .shiftLeft: result = count >= width ? 0 : x << UInt64(count)
        case .shiftRight: result = count >= width ? 0 : x >> UInt64(count)
        case .arithmeticShiftRight:
            let signed = a.signed
            result = UInt64(bitPattern: count >= width ? (signed < 0 ? -1 : 0) : signed >> Int64(count))
        case .rotateLeft:
            let n = Int(b.unsigned % UInt64(width))
            result = n == 0 ? x : (x << UInt64(n)) | (x >> UInt64(width - n))
        case .rotateRight:
            let n = Int(b.unsigned % UInt64(width))
            result = n == 0 ? x : (x >> UInt64(n)) | (x << UInt64(width - n))
        }
        return BitPattern(width: width, value: result & mask)
    }
}
