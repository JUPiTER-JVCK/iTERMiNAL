import Foundation

/// Punycode (RFC 3492) and the internationalised domain names built on it.
///
/// A domain label with characters outside ASCII is written as `xn--` and the
/// Punycode of the label: `münchen` becomes `xn--mnchen-3ya`. This is the
/// bare algorithm and the label-by-label wrapper; it does not apply the full
/// UTS #46 mapping tables, only lowercase and canonical composition, which is
/// what turns the common cases into the name a resolver would see.
enum Punycode {
    private static let base = 36
    private static let tMin = 1
    private static let tMax = 26
    private static let skew = 38
    private static let damp = 700
    private static let initialBias = 72
    private static let initialN = 128

    private static func adapt(_ delta: Int, _ points: Int, _ first: Bool) -> Int {
        var delta = first ? delta / damp : delta / 2
        delta += delta / points
        var k = 0
        while delta > ((base - tMin) * tMax) / 2 {
            delta /= base - tMin
            k += base
        }
        return k + (base - tMin + 1) * delta / (delta + skew)
    }

    private static func digit(_ value: Int) -> Character {
        Character(UnicodeScalar(UInt8(value < 26 ? 97 + value : 48 + value - 26)))
    }

    private static func value(of scalar: Unicode.Scalar) -> Int? {
        switch scalar.value {
        case 0x30...0x39: return Int(scalar.value) - 0x30 + 26
        case 0x41...0x5A: return Int(scalar.value) - 0x41
        case 0x61...0x7A: return Int(scalar.value) - 0x61
        default: return nil
        }
    }

    private static func threshold(_ k: Int, _ bias: Int) -> Int {
        k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
    }

    /// The Punycode of one string of code points, without the `xn--` in front;
    /// nil if the arithmetic overflows (a absurdly long label).
    static func encode(_ input: String) -> String? {
        let scalars = input.unicodeScalars.map { Int($0.value) }
        var output = scalars.filter { $0 < 128 }.map { Character(UnicodeScalar(UInt8($0))) }
        let basicCount = output.count
        var handled = basicCount
        if basicCount > 0 { output.append("-") }
        var n = initialN
        var delta = 0
        var bias = initialBias
        while handled < scalars.count {
            guard let m = scalars.filter({ $0 >= n }).min() else { break }
            let (step, overflow) = (m - n).multipliedReportingOverflow(by: handled + 1)
            let (sum, overflow2) = delta.addingReportingOverflow(step)
            if overflow || overflow2 { return nil }
            delta = sum
            n = m
            for c in scalars {
                if c < n { delta += 1 }
                if c == n {
                    var q = delta
                    var k = base
                    while true {
                        let t = threshold(k, bias)
                        if q < t { break }
                        output.append(digit(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(digit(q))
                    bias = adapt(delta, handled + 1, handled == basicCount)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1
            n += 1
        }
        return String(output)
    }

    /// The code points a Punycode string stands for, or nil if it is not valid Punycode.
    static func decode(_ input: String) -> String? {
        let scalars = Array(input.unicodeScalars)
        var output: [Int] = []
        var position = 0
        if let delimiter = scalars.lastIndex(of: "-") {
            for scalar in scalars[0..<delimiter] {
                guard scalar.value < 128 else { return nil }
                output.append(Int(scalar.value))
            }
            position = delimiter + 1
        }
        var n = initialN
        var i = 0
        var bias = initialBias
        while position < scalars.count {
            let oldI = i
            var w = 1
            var k = base
            while true {
                guard position < scalars.count, let digit = value(of: scalars[position]) else { return nil }
                position += 1
                let (product, overflow) = digit.multipliedReportingOverflow(by: w)
                let (sum, overflow2) = i.addingReportingOverflow(product)
                if overflow || overflow2 { return nil }
                i = sum
                let t = threshold(k, bias)
                if digit < t { break }
                let (next, overflow3) = w.multipliedReportingOverflow(by: base - t)
                if overflow3 { return nil }
                w = next
                k += base
            }
            let count = output.count + 1
            bias = adapt(i - oldI, count, oldI == 0)
            let (carry, overflow4) = n.addingReportingOverflow(i / count)
            if overflow4 { return nil }
            n = carry
            i %= count
            guard Unicode.Scalar(UInt32(truncatingIfNeeded: n)) != nil, n <= 0x10FFFF else { return nil }
            output.insert(n, at: i)
            i += 1
        }
        var result = String.UnicodeScalarView()
        for code in output {
            guard let scalar = Unicode.Scalar(UInt32(code)) else { return nil }
            result.append(scalar)
        }
        return String(result)
    }

    // MARK: Domain names

    private static let labelDots: Set<Character> = [".", "\u{3002}", "\u{FF0E}", "\u{FF61}"]

    /// One label, before and after.
    struct Label: Equatable {
        let unicode: String
        let ascii: String
        /// True when the label needed Punycode (or came in as it).
        let isInternationalised: Bool
    }

    /// Each dot-separated label of `domain`, written both ways.
    static func labels(of domain: String) -> [Label] {
        domain.split(omittingEmptySubsequences: false, whereSeparator: { labelDots.contains($0) }).map { raw in
            let label = String(raw)
            if label.lowercased().hasPrefix("xn--") {
                let body = String(label.dropFirst(4))
                if let decoded = decode(body) {
                    return Label(unicode: decoded, ascii: label.lowercased(), isInternationalised: true)
                }
                return Label(unicode: label, ascii: label, isInternationalised: false)
            }
            if label.unicodeScalars.allSatisfy({ $0.value < 128 }) {
                return Label(unicode: label, ascii: label, isInternationalised: false)
            }
            let normalised = label.precomposedStringWithCanonicalMapping.lowercased()
            let ascii = encode(normalised).map { "xn--" + $0 } ?? label
            return Label(unicode: normalised, ascii: ascii, isInternationalised: true)
        }
    }

    /// `münchen.de` → `xn--mnchen-3ya.de`.
    static func toASCII(_ domain: String) -> String {
        labels(of: domain).map(\.ascii).joined(separator: ".")
    }

    /// `xn--mnchen-3ya.de` → `münchen.de`.
    static func toUnicode(_ domain: String) -> String {
        labels(of: domain).map(\.unicode).joined(separator: ".")
    }

    /// Whether the name mixes scripts in one label — the shape a look-alike
    /// (homograph) domain takes, such as a Cyrillic а among Latin letters.
    static func mixesScripts(_ label: String) -> Bool {
        var seen = Set<String>()
        for scalar in label.unicodeScalars where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F: seen.insert("Latin")
            case 0x370...0x3FF, 0x1F00...0x1FFF: seen.insert("Greek")
            case 0x400...0x52F: seen.insert("Cyrillic")
            case 0x531...0x58F: seen.insert("Armenian")
            case 0x590...0x5FF: seen.insert("Hebrew")
            case 0x600...0x6FF: seen.insert("Arabic")
            case 0x3040...0x30FF: seen.insert("Kana")
            case 0x4E00...0x9FFF: seen.insert("Han")
            case 0xAC00...0xD7AF: seen.insert("Hangul")
            default: seen.insert("Other")
            }
        }
        return seen.count > 1
    }
}
