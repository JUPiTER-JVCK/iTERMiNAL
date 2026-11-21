import Foundation

/// The IEEE 754 binary formats the Float tool shows. Half precision is
/// handled here by hand rather than with `Float16`, which does not exist on
/// Intel Macs and this app is built for both.
enum FloatFormat: Int, CaseIterable, Identifiable {
    case half = 16, single = 32, double = 64

    var id: Int { rawValue }
    var totalBits: Int { rawValue }

    var title: String {
        switch self {
        case .half: return "16-bit half"
        case .single: return "32-bit float"
        case .double: return "64-bit double"
        }
    }

    var exponentBits: Int {
        switch self {
        case .half: return 5
        case .single: return 8
        case .double: return 11
        }
    }

    var mantissaBits: Int { totalBits - 1 - exponentBits }
    var bias: Int { (1 << (exponentBits - 1)) - 1 }
    var maxExponentField: UInt64 { (UInt64(1) << UInt64(exponentBits)) - 1 }
}

/// One float, taken apart into sign, exponent and mantissa.
struct FloatBits: Equatable {
    enum Category: Equatable {
        case zero, subnormal, normal, infinity, nan
    }

    let format: FloatFormat
    /// All the bits, in the low `format.totalBits`.
    let bits: UInt64

    init(format: FloatFormat, bits: UInt64) {
        self.format = format
        self.bits = format == .double ? bits : bits & ((UInt64(1) << UInt64(format.totalBits)) - 1)
    }

    /// The nearest float of `format` to `value`, ties to even.
    init(format: FloatFormat, value: Double) {
        switch format {
        case .double: self.init(format: .double, bits: value.bitPattern)
        case .single: self.init(format: .single, bits: UInt64(Float(value).bitPattern))
        case .half: self.init(format: .half, bits: UInt64(FloatBits.halfBits(value)))
        }
    }

    var isNegative: Bool { bits >> UInt64(format.totalBits - 1) & 1 == 1 }

    var exponentField: UInt64 {
        (bits >> UInt64(format.mantissaBits)) & format.maxExponentField
    }

    var mantissaField: UInt64 {
        bits & ((UInt64(1) << UInt64(format.mantissaBits)) - 1)
    }

    var category: Category {
        if exponentField == format.maxExponentField { return mantissaField == 0 ? .infinity : .nan }
        if exponentField == 0 { return mantissaField == 0 ? .zero : .subnormal }
        return .normal
    }

    /// For NaN: whether the top mantissa bit is set, which makes it a quiet one.
    var isQuietNaN: Bool {
        category == .nan && mantissaField >> UInt64(format.mantissaBits - 1) & 1 == 1
    }

    /// The power of two the number is scaled by. Subnormals use the smallest.
    var unbiasedExponent: Int {
        switch category {
        case .zero, .subnormal: return 1 - format.bias
        default: return Int(exponentField) - format.bias
        }
    }

    /// The value in a Double, which holds every half and single exactly.
    var value: Double {
        switch format {
        case .double: return Double(bitPattern: bits)
        case .single: return Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits)))
        case .half:
            switch category {
            case .nan: return Double.nan
            case .infinity: return isNegative ? -Double.infinity : Double.infinity
            case .zero: return isNegative ? -0.0 : 0.0
            case .subnormal:
                let magnitude = Double(mantissaField) * pow(2.0, Double(unbiasedExponent - format.mantissaBits))
                return isNegative ? -magnitude : magnitude
            case .normal:
                let significand = 1.0 + Double(mantissaField) / Double(UInt64(1) << UInt64(format.mantissaBits))
                let magnitude = significand * pow(2.0, Double(unbiasedExponent))
                return isNegative ? -magnitude : magnitude
            }
        }
    }

    /// The exact value the bits stand for, written as a decimal, so what is
    /// really stored shows: 0.1 as a 32-bit float is 0.10000000149011612.
    var storedText: String {
        let v = value
        if v.isNaN { return "NaN" }
        if v.isInfinite { return v < 0 ? "−∞" : "∞" }
        return "\(v)"
    }

    /// The bits in hex, padded to the width.
    var hex: String {
        let digits = format.totalBits / 4
        let text = String(bits, radix: 16, uppercase: true)
        return "0x" + String(repeating: "0", count: max(0, digits - text.count)) + text
    }

    /// The bits from the highest to the lowest.
    var bitList: [Bool] {
        (0..<format.totalBits).reversed().map { bits >> UInt64($0) & 1 == 1 }
    }

    func flipping(_ index: Int) -> FloatBits {
        guard (0..<format.totalBits).contains(index) else { return self }
        return FloatBits(format: format, bits: bits ^ (UInt64(1) << UInt64(index)))
    }

    /// How far the stored value is from `exact`, when `exact` is what was typed.
    func error(from exact: Double) -> Double? {
        let v = value
        guard v.isFinite, exact.isFinite else { return nil }
        return v - exact
    }

    /// The largest finite value and the smallest positive normal, for the format.
    static func limits(_ format: FloatFormat) -> (maxFinite: Double, minNormal: Double) {
        let maxFinite = FloatBits(format: format, bits: ((format.maxExponentField - 1) << UInt64(format.mantissaBits)) | ((UInt64(1) << UInt64(format.mantissaBits)) - 1)).value
        let minNormal = FloatBits(format: format, bits: UInt64(1) << UInt64(format.mantissaBits)).value
        return (maxFinite, minNormal)
    }

    // MARK: Half precision

    /// The 16 bits of the half-precision float nearest to `v`, ties to even.
    static func halfBits(_ v: Double) -> UInt16 {
        let sign: UInt16 = v.sign == .minus ? 0x8000 : 0
        if v.isNaN { return sign | 0x7E00 }
        let a = abs(v)
        if a.isInfinite || a >= 65520 { return sign | 0x7C00 }
        // Below half the smallest subnormal (2^-24) rounds to zero.
        if a < 0x1p-25 || a == 0 { return sign }
        let exponent = Int(a.exponent)
        if exponent < -14 {
            // Subnormal: a multiple of 2^-24. A result of 1024 is the smallest normal, and the same bits.
            let m = (a * 0x1p24).rounded(.toNearestOrEven)
            return sign | UInt16(m)
        }
        var e = exponent
        var m = ((a / pow(2.0, Double(e)) - 1.0) * 1024.0).rounded(.toNearestOrEven)
        if m >= 1024 {
            e += 1
            m = 0
        }
        if e > 15 { return sign | 0x7C00 }
        return sign | UInt16((e + 15) << 10) | UInt16(m)
    }

    // MARK: Reading what was typed

    /// A float typed as a decimal (`0.1`, `-2.5e10`, `inf`, `nan`) or as bits
    /// (`0x3DCCCCCD`), at `format`.
    static func parse(_ text: String, format: FloatFormat) -> Result<FloatBits, ByteFormatProblem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(ByteFormatProblem(message: "Type a number, or hex bits like 0x3F800000.")) }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("0x") && !lower.contains("p") {
            let digits = lower.dropFirst(2).filter { $0 != "_" && $0 != " " }
            guard let bits = UInt64(digits, radix: 16) else {
                return .failure(ByteFormatProblem(message: "“\(trimmed)” is not hex."))
            }
            if digits.count > format.totalBits / 4 {
                return .failure(ByteFormatProblem(message: "\(format.title) is \(format.totalBits / 4) hex digits; that is \(digits.count)."))
            }
            return .success(FloatBits(format: format, bits: bits))
        }
        switch lower {
        case "inf", "+inf", "infinity", "∞": return .success(FloatBits(format: format, value: .infinity))
        case "-inf", "-infinity", "−∞": return .success(FloatBits(format: format, value: -.infinity))
        case "nan": return .success(FloatBits(format: format, value: .nan))
        default: break
        }
        guard let value = Double(trimmed.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: ",", with: "")) else {
            return .failure(ByteFormatProblem(message: "“\(trimmed)” is not a number."))
        }
        return .success(FloatBits(format: format, value: value))
    }
}
