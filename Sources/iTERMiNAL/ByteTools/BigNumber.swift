import Foundation

/// A non-negative whole number of any size, for the Byte Tools that have to
/// convert between bases without a 64-bit ceiling: a 256-bit key shown in
/// decimal, a 40-digit decimal turned into bytes.
///
/// Stored as little-endian 32-bit limbs with no leading (high) zero limbs, so
/// zero is the empty array and equal values are always equal arrays. Only what
/// the tools need is here: build from bytes or digits, print in any base from 2
/// to 36, and the two small-number steps those are built from. It is quadratic
/// in the number of digits, which is fine for the few thousand the panel
/// accepts.
struct BigNumber: Equatable {
    private(set) var limbs: [UInt32]

    static let zero = BigNumber(limbs: [])

    private init(limbs: [UInt32]) {
        self.limbs = limbs
        trim()
    }

    init(_ value: UInt64) {
        self.init(limbs: [UInt32(truncatingIfNeeded: value), UInt32(truncatingIfNeeded: value >> 32)])
    }

    /// Big-endian bytes, the way a number is written: `[0x01, 0x00]` is 256.
    init(bytes: [UInt8]) {
        var limbs: [UInt32] = []
        var index = bytes.count
        while index > 0 {
            var limb: UInt32 = 0
            var shift: UInt32 = 0
            // Up to four bytes, from the least significant end.
            var taken = 0
            while taken < 4 && index > 0 {
                index -= 1
                limb |= UInt32(bytes[index]) << shift
                shift += 8
                taken += 1
            }
            limbs.append(limb)
        }
        self.init(limbs: limbs)
    }

    /// The value of `digits` written in `base` (2 through 36), or nil when it
    /// is empty or holds a digit that base does not have. Case does not matter.
    init?(digits: String, base: Int) {
        guard (2...36).contains(base), !digits.isEmpty else { return nil }
        var number = BigNumber.zero
        for scalar in digits.unicodeScalars {
            guard let value = BigNumber.digitValue(scalar), value < base else { return nil }
            number.multiply(by: UInt32(base), add: UInt32(value))
        }
        self = number
    }

    var isZero: Bool { limbs.isEmpty }

    /// Bits needed to write it: 0 for zero, 8 for 255, 9 for 256.
    var bitLength: Int {
        guard let top = limbs.last else { return 0 }
        return (limbs.count - 1) * 32 + (32 - top.leadingZeroBitCount)
    }

    /// The value as a UInt64, or nil when it does not fit.
    var asUInt64: UInt64? {
        switch limbs.count {
        case 0: return 0
        case 1: return UInt64(limbs[0])
        case 2: return UInt64(limbs[0]) | UInt64(limbs[1]) << 32
        default: return nil
        }
    }

    /// Big-endian bytes with no leading zero bytes; zero is one zero byte, so
    /// the result is never empty.
    func toBytes() -> [UInt8] {
        guard !limbs.isEmpty else { return [0] }
        var bytes: [UInt8] = []
        for limb in limbs.reversed() {
            bytes.append(UInt8(truncatingIfNeeded: limb >> 24))
            bytes.append(UInt8(truncatingIfNeeded: limb >> 16))
            bytes.append(UInt8(truncatingIfNeeded: limb >> 8))
            bytes.append(UInt8(truncatingIfNeeded: limb))
        }
        let firstSet = bytes.firstIndex(where: { $0 != 0 }) ?? bytes.count - 1
        return Array(bytes[firstSet...])
    }

    /// The number written in `base` (2 through 36), no prefix.
    func toString(base: Int, uppercase: Bool = true) -> String {
        guard (2...36).contains(base) else { return "" }
        if isZero { return "0" }
        let alphabet = Array((uppercase ? "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ" : "0123456789abcdefghijklmnopqrstuvwxyz").utf8)
        // Peel off as many digits per division as fit a 32-bit limb: base^k <= 2^32.
        var chunkDigits = 1
        var chunk = UInt64(base)
        while chunk * UInt64(base) <= UInt64(UInt32.max) {
            chunk *= UInt64(base)
            chunkDigits += 1
        }
        var work = self
        var reversed: [UInt8] = []
        while !work.isZero {
            var remainder = work.divide(by: UInt32(chunk))
            for _ in 0..<chunkDigits {
                reversed.append(alphabet[Int(remainder % UInt32(base))])
                remainder /= UInt32(base)
                if work.isZero && remainder == 0 { break }
            }
        }
        while reversed.count > 1, reversed.last == alphabet[0] { reversed.removeLast() }
        return String(decoding: reversed.reversed(), as: UTF8.self)
    }

    /// self = self * factor + addend.
    mutating func multiply(by factor: UInt32, add addend: UInt32) {
        var carry = UInt64(addend)
        for index in limbs.indices {
            let product = UInt64(limbs[index]) * UInt64(factor) + carry
            limbs[index] = UInt32(truncatingIfNeeded: product)
            carry = product >> 32
        }
        if carry > 0 { limbs.append(UInt32(carry)) }
        trim()
    }

    /// self = self / divisor, returning the remainder. The divisor must not be
    /// zero.
    @discardableResult
    mutating func divide(by divisor: UInt32) -> UInt32 {
        precondition(divisor != 0, "division by zero")
        var remainder: UInt64 = 0
        for index in limbs.indices.reversed() {
            let current = (remainder << 32) | UInt64(limbs[index])
            limbs[index] = UInt32(current / UInt64(divisor))
            remainder = current % UInt64(divisor)
        }
        trim()
        return UInt32(remainder)
    }

    private mutating func trim() {
        while let last = limbs.last, last == 0 { limbs.removeLast() }
    }

    static func digitValue(_ scalar: Unicode.Scalar) -> Int? {
        switch scalar.value {
        case 0x30...0x39: return Int(scalar.value) - 0x30
        case 0x41...0x5A: return Int(scalar.value) - 0x41 + 10
        case 0x61...0x7A: return Int(scalar.value) - 0x61 + 10
        default: return nil
        }
    }
}
