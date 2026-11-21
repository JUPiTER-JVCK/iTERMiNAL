import Foundation

/// Why a piece of text could not be read as a format. The message is shown
/// as it is, under the field, so it names what is wrong rather than the format.
struct ByteFormatProblem: Error, Equatable {
    let message: String
}

/// How the byte-per-token formats are written: what goes between bytes, what
/// goes in front of each, and the case of hex digits.
struct ByteStyle: Equatable {
    var delimiter: String = " "
    var prefix: String = ""
    var uppercase: Bool = false

    static let standard = ByteStyle()
}

/// Every way the Byte Tools can write a run of bytes down, each able to go both
/// ways. Everything converts through `[UInt8]`, so any format reaches any other:
/// decode with one, encode with another.
///
/// Some formats are really about text (percent-encoding, HTML entities,
/// Punycode, escapes). Their bytes are the UTF-8 of the text, which is what
/// those formats carry on the web.
enum ByteFormat: String, CaseIterable, Identifiable {
    case text, hex, binary, octal, decimalBytes, decimalNumber
    case base64, base64url, base32, base58, ascii85
    case percent, htmlEntities, unicodeEscapes, punycode, hexdump

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: return "Text (UTF-8)"
        case .hex: return "Hex"
        case .binary: return "Binary"
        case .octal: return "Octal"
        case .decimalBytes: return "Decimal bytes"
        case .decimalNumber: return "Decimal number"
        case .base64: return "Base64"
        case .base64url: return "Base64 URL-safe"
        case .base32: return "Base32"
        case .base58: return "Base58"
        case .ascii85: return "Ascii85"
        case .percent: return "URL encoding"
        case .htmlEntities: return "HTML entities"
        case .unicodeEscapes: return "Unicode escapes"
        case .punycode: return "Punycode (IDN)"
        case .hexdump: return "Hexdump"
        }
    }

    /// A line saying what the format looks like, shown beside its title.
    var example: String {
        switch self {
        case .text: return "Hello"
        case .hex: return "48 65 6c 6c 6f"
        case .binary: return "01001000 01100101"
        case .octal: return "110 145 154 154 157"
        case .decimalBytes: return "72 101 108 108 111"
        case .decimalNumber: return "310939249775"
        case .base64: return "SGVsbG8="
        case .base64url: return "SGVsbG8"
        case .base32: return "JBSWY3DP"
        case .base58: return "9Ajdvzr"
        case .ascii85: return "87cURDZ"
        case .percent: return "Hello%20world"
        case .htmlEntities: return "caf&eacute; &amp; cr&#xE8;me"
        case .unicodeEscapes: return "\\u0048\\u00e9"
        case .punycode: return "xn--mnchen-3ya.de"
        case .hexdump: return "00000000  48 65 6c 6c 6f"
        }
    }

    // MARK: Writing

    func encode(_ bytes: [UInt8], style: ByteStyle = .standard) -> String {
        switch self {
        case .text: return ByteFormat.utf8Text(bytes)
        case .hex:
            let digits = style.uppercase ? Array("0123456789ABCDEF") : Array("0123456789abcdef")
            return bytes.map { style.prefix + String([digits[Int($0 >> 4)], digits[Int($0 & 15)]]) }
                .joined(separator: style.delimiter)
        case .binary:
            return bytes.map { style.prefix + ByteFormat.padded(String($0, radix: 2), to: 8) }
                .joined(separator: style.delimiter)
        case .octal:
            return bytes.map { style.prefix + ByteFormat.padded(String($0, radix: 8), to: 3) }
                .joined(separator: style.delimiter)
        case .decimalBytes:
            return bytes.map { style.prefix + String($0) }.joined(separator: style.delimiter)
        case .decimalNumber:
            return bytes.isEmpty ? "" : BigNumber(bytes: bytes).toString(base: 10)
        case .base64: return Base64Codec.encode(bytes, urlSafe: false, padded: true)
        case .base64url: return Base64Codec.encode(bytes, urlSafe: true, padded: false)
        case .base32: return Base32Codec.encode(bytes)
        case .base58: return Base58Codec.encode(bytes)
        case .ascii85: return Ascii85Codec.encode(bytes)
        case .percent: return PercentEncoding.encode(bytes, allowed: .unreserved)
        case .htmlEntities: return HTMLEntityEncoder.encode(ByteFormat.utf8Text(bytes))
        case .unicodeEscapes: return UnicodeEscapes.encode(ByteFormat.utf8Text(bytes))
        case .punycode: return Punycode.toASCII(ByteFormat.utf8Text(bytes))
        case .hexdump: return HexDump.format(bytes)
        }
    }

    // MARK: Reading

    func decode(_ text: String) -> Result<[UInt8], ByteFormatProblem> {
        switch self {
        case .text: return .success(Array(text.utf8))
        case .hex: return ByteFormat.decodeHex(text)
        case .binary: return ByteFormat.decodeBinary(text)
        case .octal: return ByteFormat.decodeOctal(text)
        case .decimalBytes: return ByteFormat.decodeDecimalBytes(text)
        case .decimalNumber: return ByteFormat.decodeDecimalNumber(text)
        case .base64, .base64url: return Base64Codec.decode(text)
        case .base32: return Base32Codec.decode(text)
        case .base58: return Base58Codec.decode(text)
        case .ascii85: return Ascii85Codec.decode(text)
        case .percent:
            return PercentEncoding.decode(text, plusIsSpace: false)
        case .htmlEntities: return .success(Array(HTMLEntities.decode(text).utf8))
        case .unicodeEscapes: return UnicodeEscapes.decode(text).map { Array($0.utf8) }
        case .punycode: return .success(Array(Punycode.toUnicode(text).utf8))
        case .hexdump:
            let bytes = HexDump.parse(text)
            return bytes.isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .failure(ByteFormatProblem(message: "No hex bytes found in that dump."))
                : .success(bytes)
        }
    }

    /// Reads `text` as `self` and writes it as `target`.
    func convert(_ text: String, to target: ByteFormat, style: ByteStyle = .standard) -> Result<String, ByteFormatProblem> {
        decode(text).map { target.encode($0, style: style) }
    }

    // MARK: Guessing

    /// What `text` most plausibly is, most likely first. Nothing is certain —
    /// "test" is valid Base64 — so this is a suggestion the person can
    /// override, and plain text is always the fallback at the end.
    static func detect(_ text: String) -> [ByteFormat] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [.text] }
        var found: [ByteFormat] = []
        let scalars = Array(trimmed.unicodeScalars)

        func all(_ allowed: (Unicode.Scalar) -> Bool) -> Bool { scalars.allSatisfy(allowed) }
        func isSpace(_ s: Unicode.Scalar) -> Bool { s == " " || s == "\n" || s == "\t" || s == "\r" }
        func isHexDigit(_ s: Unicode.Scalar) -> Bool { BigNumber.digitValue(s).map { $0 < 16 } ?? false }

        if trimmed.range(of: #"%[0-9A-Fa-f]{2}"#, options: .regularExpression) != nil { found.append(.percent) }
        if trimmed.contains("\\u") || trimmed.contains("\\x") { found.append(.unicodeEscapes) }
        if trimmed.range(of: #"&(#[0-9]+|#[xX][0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9]*);"#, options: .regularExpression) != nil {
            found.append(.htmlEntities)
        }
        if trimmed.lowercased().contains("xn--") { found.append(.punycode) }

        let compact = String(String.UnicodeScalarView(scalars.filter { !isSpace($0) && $0 != "_" }))
        if !compact.isEmpty, compact.unicodeScalars.allSatisfy({ $0 == "0" || $0 == "1" }), compact.count % 8 == 0, compact.count >= 8 {
            found.append(.binary)
        }
        // A hexdump has offsets and ASCII; spot the canonical shape.
        if trimmed.contains("\n"), trimmed.range(of: #"^[0-9A-Fa-f]{4,8}:?\s+(?:[0-9A-Fa-f]{2}\s)"#, options: [.regularExpression]) != nil {
            found.append(.hexdump)
        }
        let hasHexPrefix = trimmed.contains("0x") || trimmed.contains("0X") || trimmed.contains("\\x")
        let hexBody = all { isHexDigit($0) || isSpace($0) || $0 == ":" || $0 == "," || $0 == "x" || $0 == "X" || $0 == "\\" || $0 == "-" }
        if hexBody, case .success(let bytes) = decodeHex(trimmed), !bytes.isEmpty {
            let hasLetters = compact.contains { "abcdefABCDEF".contains($0) }
            let spaced = trimmed.contains(" ") || trimmed.contains(":") || trimmed.contains(",")
            if hasHexPrefix || hasLetters || (spaced && decimalLooksLikeHex(trimmed)) { found.append(.hex) }
        }
        if all({ ($0.value >= 0x30 && $0.value <= 0x39) || isSpace($0) || $0 == "," }), !found.contains(.hex) {
            let tokens = trimmed.split(whereSeparator: { " \n\t\r,".contains($0) })
            if tokens.count > 1, case .success = decodeDecimalBytes(trimmed) {
                found.append(.decimalBytes)
            } else if tokens.count == 1 {
                found.append(.decimalNumber)
            }
        }
        if !trimmed.contains(" "), case .success(let bytes) = Base64Codec.decode(trimmed), !bytes.isEmpty, trimmed.count >= 4 {
            let usesUrl = trimmed.contains("-") || trimmed.contains("_")
            let markers = trimmed.contains("=") || trimmed.contains("+") || trimmed.contains("/") || usesUrl
            let plausible = String(data: Data(bytes), encoding: .utf8).map { text in
                text.unicodeScalars.allSatisfy { $0.value >= 0x20 || $0 == "\n" || $0 == "\t" || $0 == "\r" }
            } ?? false
            if markers || plausible { found.append(usesUrl ? .base64url : .base64) }
        }
        if !trimmed.contains(" "), trimmed.count >= 8, trimmed.count % 8 == 0,
           trimmed.unicodeScalars.allSatisfy({ ($0.value >= 0x41 && $0.value <= 0x5A) || ($0.value >= 0x32 && $0.value <= 0x37) || $0 == "=" }),
           case .success = Base32Codec.decode(trimmed) {
            found.append(.base32)
        }
        found.append(.text)
        var seen = Set<ByteFormat>()
        return found.filter { seen.insert($0).inserted }
    }

    // MARK: Pieces

    /// The text of `bytes` read as UTF-8, with U+FFFD for what is not.
    static func utf8Text(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    /// Whether `bytes` are well-formed UTF-8, so showing them as text loses nothing.
    static func isValidUTF8(_ bytes: [UInt8]) -> Bool {
        String(data: Data(bytes), encoding: .utf8) != nil
    }

    private static func padded(_ text: String, to width: Int) -> String {
        text.count >= width ? text : String(repeating: "0", count: width - text.count) + text
    }

    /// Separators the readers skip: space, newline, tab, comma, colon, semicolon, dash, underscore.
    private static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { " \n\t\r,:;-_".contains($0) }).map(String.init)
    }

    private static func decimalLooksLikeHex(_ text: String) -> Bool {
        // "48 65 20" is two-digit tokens throughout; "72 101 108" is not.
        let parts = tokens(text)
        return !parts.isEmpty && parts.allSatisfy { $0.count == 2 }
    }

    static func decodeHex(_ text: String) -> Result<[UInt8], ByteFormatProblem> {
        var cleaned = text.replacingOccurrences(of: "\\x", with: " ").replacingOccurrences(of: "\\X", with: " ")
        cleaned = cleaned.replacingOccurrences(of: "0x", with: " ").replacingOccurrences(of: "0X", with: " ")
        cleaned = cleaned.replacingOccurrences(of: "$", with: " ").replacingOccurrences(of: "#", with: " ")
        let parts = tokens(cleaned)
        var bytes: [UInt8] = []
        for part in parts {
            var digits = part
            if digits.count % 2 == 1 {
                // "f 1 2" is the bytes 0f 01 02; a lone "abc" is a mistake.
                guard parts.count > 1 else {
                    return .failure(ByteFormatProblem(message: "Hex needs two digits per byte; this has an odd number (\(digits.count))."))
                }
                digits = "0" + digits
            }
            let chars = Array(digits.unicodeScalars)
            var i = 0
            while i < chars.count {
                guard let high = BigNumber.digitValue(chars[i]), high < 16,
                      let low = BigNumber.digitValue(chars[i + 1]), low < 16 else {
                    let bad = chars[i..<(i + 2)].map { String($0) }.joined()
                    return .failure(ByteFormatProblem(message: "“\(bad)” is not a hex digit pair."))
                }
                bytes.append(UInt8(high << 4 | low))
                i += 2
            }
        }
        return .success(bytes)
    }

    static func decodeBinary(_ text: String) -> Result<[UInt8], ByteFormatProblem> {
        var cleaned = text.replacingOccurrences(of: "0b", with: " ").replacingOccurrences(of: "0B", with: " ")
        cleaned = cleaned.replacingOccurrences(of: "%", with: " ")
        var bits: [Bool] = []
        for scalar in cleaned.unicodeScalars {
            switch scalar {
            case "0": bits.append(false)
            case "1": bits.append(true)
            case " ", "\n", "\t", "\r", ",", "_", ":", ";": continue
            default: return .failure(ByteFormatProblem(message: "“\(scalar)” is not a binary digit (only 0 and 1)."))
            }
        }
        if bits.isEmpty { return .success([]) }
        // A length that is not a whole number of bytes is read as a number: zeros are put in front.
        let extra = (8 - bits.count % 8) % 8
        bits.insert(contentsOf: [Bool](repeating: false, count: extra), at: 0)
        var bytes: [UInt8] = []
        var index = 0
        while index < bits.count {
            var value: UInt8 = 0
            for bit in bits[index..<(index + 8)] { value = value << 1 | (bit ? 1 : 0) }
            bytes.append(value)
            index += 8
        }
        return .success(bytes)
    }

    static func decodeOctal(_ text: String) -> Result<[UInt8], ByteFormatProblem> {
        let cleaned = text.replacingOccurrences(of: "0o", with: " ").replacingOccurrences(of: "0O", with: " ")
            .replacingOccurrences(of: "\\", with: " ")
        var parts = tokens(cleaned)
        if parts.count == 1, parts[0].count > 3, parts[0].count % 3 == 0 {
            // Run together, it is groups of three.
            let chars = Array(parts[0])
            parts = stride(from: 0, to: chars.count, by: 3).map { String(chars[$0..<($0 + 3)]) }
        }
        var bytes: [UInt8] = []
        for part in parts {
            guard let value = UInt16(part, radix: 8), value <= 255 else {
                return .failure(ByteFormatProblem(message: "“\(part)” is not an octal byte (000 to 377)."))
            }
            bytes.append(UInt8(value))
        }
        return .success(bytes)
    }

    static func decodeDecimalBytes(_ text: String) -> Result<[UInt8], ByteFormatProblem> {
        var bytes: [UInt8] = []
        for part in tokens(text.replacingOccurrences(of: "-", with: " ")) {
            guard let value = UInt16(part, radix: 10), value <= 255 else {
                return .failure(ByteFormatProblem(message: "“\(part)” is not a byte (0 to 255)."))
            }
            bytes.append(UInt8(value))
        }
        return .success(bytes)
    }

    static func decodeDecimalNumber(_ text: String) -> Result<[UInt8], ByteFormatProblem> {
        let digits = text.filter { !" \n\t\r,_".contains($0) }
        guard !digits.isEmpty else { return .success([]) }
        guard let number = BigNumber(digits: digits, base: 10) else {
            return .failure(ByteFormatProblem(message: "A decimal number holds only the digits 0 to 9."))
        }
        return .success(number.toBytes())
    }
}

// MARK: - Base64

enum Base64Codec {
    private static let standard = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
    private static let urlSafe = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8)

    static func encode(_ bytes: [UInt8], urlSafe useURL: Bool, padded: Bool) -> String {
        let alphabet = useURL ? urlSafe : standard
        var out: [UInt8] = []
        out.reserveCapacity((bytes.count + 2) / 3 * 4)
        var index = 0
        while index + 3 <= bytes.count {
            let n = UInt32(bytes[index]) << 16 | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2])
            out.append(alphabet[Int(n >> 18) & 63])
            out.append(alphabet[Int(n >> 12) & 63])
            out.append(alphabet[Int(n >> 6) & 63])
            out.append(alphabet[Int(n) & 63])
            index += 3
        }
        let rest = bytes.count - index
        if rest == 1 {
            let n = UInt32(bytes[index]) << 16
            out.append(alphabet[Int(n >> 18) & 63])
            out.append(alphabet[Int(n >> 12) & 63])
            if padded { out.append(contentsOf: [61, 61]) }
        } else if rest == 2 {
            let n = UInt32(bytes[index]) << 16 | UInt32(bytes[index + 1]) << 8
            out.append(alphabet[Int(n >> 18) & 63])
            out.append(alphabet[Int(n >> 12) & 63])
            out.append(alphabet[Int(n >> 6) & 63])
            if padded { out.append(61) }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Reads either alphabet, with or without padding, ignoring whitespace.
    static func decode(_ text: String) -> Result<[UInt8], ByteFormatProblem> {
        var values: [UInt8] = []
        var padding = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A: values.append(UInt8(scalar.value - 0x41))
            case 0x61...0x7A: values.append(UInt8(scalar.value - 0x61 + 26))
            case 0x30...0x39: values.append(UInt8(scalar.value - 0x30 + 52))
            case 0x2B, 0x2D: values.append(62)
            case 0x2F, 0x5F: values.append(63)
            case 0x3D: padding += 1
            case 0x20, 0x0A, 0x0D, 0x09: continue
            default:
                return .failure(ByteFormatProblem(message: "“\(scalar)” is not a Base64 character."))
            }
            if padding > 0, scalar.value != 0x3D, scalar.value != 0x20, scalar.value != 0x0A, scalar.value != 0x0D, scalar.value != 0x09 {
                return .failure(ByteFormatProblem(message: "Base64 has characters after its = padding."))
            }
        }
        if padding > 2 { return .failure(ByteFormatProblem(message: "Base64 ends in at most two = signs.")) }
        if values.count % 4 == 1 {
            return .failure(ByteFormatProblem(message: "That length cannot be Base64: one character is left over."))
        }
        var bytes: [UInt8] = []
        var index = 0
        while index < values.count {
            let group = Array(values[index..<min(index + 4, values.count)])
            var n: UInt32 = 0
            for i in 0..<4 { n = n << 6 | UInt32(i < group.count ? group[i] : 0) }
            bytes.append(UInt8(truncatingIfNeeded: n >> 16))
            if group.count > 2 { bytes.append(UInt8(truncatingIfNeeded: n >> 8)) }
            if group.count > 3 { bytes.append(UInt8(truncatingIfNeeded: n)) }
            index += 4
        }
        return .success(bytes)
    }
}

// MARK: - Base32

enum Base32Codec {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)

    static func encode(_ bytes: [UInt8]) -> String {
        var out: [UInt8] = []
        var buffer: UInt32 = 0
        var bits = 0
        for byte in bytes {
            buffer = buffer << 8 | UInt32(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[Int(buffer >> UInt32(bits - 5)) & 31])
                bits -= 5
            }
            buffer &= (1 << UInt32(bits)) - 1
        }
        if bits > 0 { out.append(alphabet[Int(buffer << UInt32(5 - bits)) & 31]) }
        while out.count % 8 != 0 { out.append(61) }
        return String(decoding: out, as: UTF8.self)
    }

    static func decode(_ text: String) -> Result<[UInt8], ByteFormatProblem> {
        var bytes: [UInt8] = []
        var buffer: UInt32 = 0
        var bits = 0
        for scalar in text.uppercased().unicodeScalars {
            let value: UInt32
            switch scalar.value {
            case 0x41...0x5A: value = scalar.value - 0x41
            case 0x32...0x37: value = scalar.value - 0x32 + 26
            case 0x3D, 0x20, 0x0A, 0x0D, 0x09: continue
            default: return .failure(ByteFormatProblem(message: "“\(scalar)” is not a Base32 character (A–Z and 2–7)."))
            }
            buffer = buffer << 5 | value
            bits += 5
            if bits >= 8 {
                bytes.append(UInt8(truncatingIfNeeded: buffer >> UInt32(bits - 8)))
                bits -= 8
                buffer &= (1 << UInt32(bits)) - 1
            }
        }
        return .success(bytes)
    }
}

// MARK: - Base58 (Bitcoin alphabet)

enum Base58Codec {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)

    static func encode(_ bytes: [UInt8]) -> String {
        let zeros = bytes.prefix(while: { $0 == 0 }).count
        var number = BigNumber(bytes: Array(bytes.dropFirst(zeros)))
        var digits: [UInt8] = []
        while !number.isZero {
            digits.append(alphabet[Int(number.divide(by: 58))])
        }
        let out = [UInt8](repeating: alphabet[0], count: zeros) + digits.reversed()
        return String(decoding: out, as: UTF8.self)
    }

    static func decode(_ text: String) -> Result<[UInt8], ByteFormatProblem> {
        let input = Array(text.utf8).filter { $0 != 0x20 && $0 != 0x0A && $0 != 0x09 && $0 != 0x0D }
        var number = BigNumber.zero
        for byte in input {
            guard let value = alphabet.firstIndex(of: byte) else {
                return .failure(ByteFormatProblem(message: "“\(String(UnicodeScalar(byte)))” is not in the Base58 alphabet (no 0, O, I or l)."))
            }
            number.multiply(by: 58, add: UInt32(value))
        }
        let zeros = input.prefix(while: { $0 == alphabet[0] }).count
        let body = number.isZero ? [] : number.toBytes()
        return .success([UInt8](repeating: 0, count: zeros) + body)
    }
}

// MARK: - Ascii85

enum Ascii85Codec {
    static func encode(_ bytes: [UInt8]) -> String {
        var out: [UInt8] = []
        var index = 0
        while index < bytes.count {
            let count = min(4, bytes.count - index)
            var n: UInt32 = 0
            for i in 0..<4 { n = n << 8 | UInt32(i < count ? bytes[index + i] : 0) }
            if count == 4 && n == 0 {
                out.append(0x7A) // z
            } else {
                var chars = [UInt8](repeating: 0, count: 5)
                var value = n
                for i in stride(from: 4, through: 0, by: -1) {
                    chars[i] = UInt8(value % 85) + 33
                    value /= 85
                }
                out.append(contentsOf: chars[0..<(count + 1)])
            }
            index += 4
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func decode(_ text: String) -> Result<[UInt8], ByteFormatProblem> {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("<~") { body.removeFirst(2) }
        if body.hasSuffix("~>") { body.removeLast(2) }
        var bytes: [UInt8] = []
        var group: [UInt8] = []
        func flush(_ count: Int) {
            var n: UInt64 = 0
            for i in 0..<5 { n = n * 85 + UInt64(i < group.count ? group[i] : 84) }
            let word = UInt32(truncatingIfNeeded: n)
            let all = [UInt8(truncatingIfNeeded: word >> 24), UInt8(truncatingIfNeeded: word >> 16),
                       UInt8(truncatingIfNeeded: word >> 8), UInt8(truncatingIfNeeded: word)]
            bytes.append(contentsOf: all[0..<count])
            group.removeAll()
        }
        for scalar in body.unicodeScalars {
            switch scalar.value {
            case 0x20, 0x0A, 0x0D, 0x09: continue
            case 0x7A:
                guard group.isEmpty else { return .failure(ByteFormatProblem(message: "A z can only stand in for a whole group of four zero bytes.")) }
                bytes.append(contentsOf: [0, 0, 0, 0])
            case 33...117:
                group.append(UInt8(scalar.value) - 33)
                if group.count == 5 {
                    var n: UInt64 = 0
                    for digit in group { n = n * 85 + UInt64(digit) }
                    guard n <= UInt64(UInt32.max) else { return .failure(ByteFormatProblem(message: "That group is too large to be four bytes.")) }
                    flush(4)
                }
            default:
                return .failure(ByteFormatProblem(message: "“\(scalar)” is not an Ascii85 character (! to u)."))
            }
        }
        if group.count == 1 { return .failure(ByteFormatProblem(message: "One character is left over; a final group needs at least two.")) }
        if group.count > 1 { flush(group.count - 1) }
        return .success(bytes)
    }
}

// MARK: - Percent-encoding

enum PercentEncoding {
    /// Which bytes stay as they are.
    enum Allowed {
        /// Letters, digits and - . _ ~ — what a URL component keeps.
        case unreserved
        /// What `encodeURIComponent` leaves: unreserved plus ! ' ( ) *.
        case uriComponent
        /// What `encodeURI` leaves: a whole URL's own punctuation too.
        case uri

        func keeps(_ byte: UInt8) -> Bool {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E: return true
            default: break
            }
            switch self {
            case .unreserved: return false
            case .uriComponent: return "!'()*".utf8.contains(byte)
            case .uri: return "!'()*;,/?:@&=+$#".utf8.contains(byte)
            }
        }
    }

    static func encode(_ bytes: [UInt8], allowed: Allowed, spaceAsPlus: Bool = false) -> String {
        let digits = Array("0123456789ABCDEF".utf8)
        var out: [UInt8] = []
        for byte in bytes {
            if spaceAsPlus, byte == 0x20 {
                out.append(0x2B)
            } else if allowed.keeps(byte) {
                out.append(byte)
            } else {
                out.append(0x25)
                out.append(digits[Int(byte >> 4)])
                out.append(digits[Int(byte & 15)])
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Turns %XX back into bytes. A `%` not followed by two hex digits is an
    /// error, because quietly keeping it would hide a truncated string.
    static func decode(_ text: String, plusIsSpace: Bool) -> Result<[UInt8], ByteFormatProblem> {
        let input = Array(text.utf8)
        var out: [UInt8] = []
        var index = 0
        while index < input.count {
            let byte = input[index]
            if byte == 0x25 {
                guard index + 2 < input.count,
                      let high = BigNumber.digitValue(Unicode.Scalar(input[index + 1])), high < 16,
                      let low = BigNumber.digitValue(Unicode.Scalar(input[index + 2])), low < 16 else {
                    return .failure(ByteFormatProblem(message: "A % must be followed by two hex digits (at character \(index + 1))."))
                }
                out.append(UInt8(high << 4 | low))
                index += 3
            } else {
                out.append(plusIsSpace && byte == 0x2B ? 0x20 : byte)
                index += 1
            }
        }
        return .success(out)
    }
}

// MARK: - HTML entities

enum HTMLEntityEncoder {
    /// The five characters markup reserves become named entities, and anything
    /// outside printable ASCII becomes a numeric one, so the result is safe in
    /// an ASCII-only document.
    static func encode(_ text: String, asciiOnly: Bool = true) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            case "\n", "\t", "\r": out.unicodeScalars.append(scalar)
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F || (asciiOnly && scalar.value > 0x7E) {
                    out += "&#x" + String(scalar.value, radix: 16, uppercase: true) + ";"
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}

// MARK: - Unicode escapes

enum UnicodeEscapes {
    /// Printable ASCII stays; everything else is `\uXXXX`, with a surrogate pair
    /// for anything above U+FFFF — what JSON, JavaScript and Java read.
    static func encode(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value >= 0x20 && scalar.value <= 0x7E {
                    out.unicodeScalars.append(scalar)
                } else {
                    for unit in String(scalar).utf16 {
                        let hex = String(unit, radix: 16, uppercase: false)
                        out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                    }
                }
            }
        }
        return out
    }

    /// Reads `\uXXXX` (and surrogate pairs), `\u{X…}`, `\UXXXXXXXX`, `\xHH` and
    /// the usual one-letter escapes. Anything else is kept as written.
    static func decode(_ text: String) -> Result<String, ByteFormatProblem> {
        let chars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        var units: [UInt16] = []
        func flushUnits() {
            guard !units.isEmpty else { return }
            out.append(contentsOf: String(decoding: units, as: UTF16.self).unicodeScalars)
            units.removeAll()
        }
        func hex(_ from: Int, _ count: Int) -> UInt32? {
            guard from + count <= chars.count else { return nil }
            var value: UInt32 = 0
            for i in from..<(from + count) {
                guard let digit = BigNumber.digitValue(chars[i]), digit < 16 else { return nil }
                value = value << 4 | UInt32(digit)
            }
            return value
        }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            guard c == "\\", i + 1 < chars.count else {
                flushUnits()
                out.append(c)
                i += 1
                continue
            }
            let next = chars[i + 1]
            switch next {
            case "u":
                if i + 2 < chars.count, chars[i + 2] == "{" {
                    var j = i + 3
                    var value: UInt32 = 0
                    var count = 0
                    while j < chars.count, let digit = BigNumber.digitValue(chars[j]), digit < 16, count < 8 {
                        value = value << 4 | UInt32(digit)
                        j += 1
                        count += 1
                    }
                    guard j < chars.count, chars[j] == "}", count > 0, let scalar = Unicode.Scalar(value) else {
                        return .failure(ByteFormatProblem(message: "A \\u{…} escape needs hex digits and a closing brace, naming a real code point."))
                    }
                    flushUnits()
                    out.append(scalar)
                    i = j + 1
                } else if let value = hex(i + 2, 4) {
                    units.append(UInt16(value))
                    i += 6
                } else {
                    return .failure(ByteFormatProblem(message: "\\u must be followed by four hex digits."))
                }
            case "U":
                guard let value = hex(i + 2, 8), let scalar = Unicode.Scalar(value) else {
                    return .failure(ByteFormatProblem(message: "\\U must be followed by eight hex digits naming a real code point."))
                }
                flushUnits()
                out.append(scalar)
                i += 10
            case "x":
                guard let value = hex(i + 2, 2), let scalar = Unicode.Scalar(value) else {
                    return .failure(ByteFormatProblem(message: "\\x must be followed by two hex digits."))
                }
                flushUnits()
                out.append(scalar)
                i += 4
            case "n": flushUnits(); out.append("\n"); i += 2
            case "t": flushUnits(); out.append("\t"); i += 2
            case "r": flushUnits(); out.append("\r"); i += 2
            case "0": flushUnits(); out.append("\0"); i += 2
            case "\\", "\"", "'", "/": flushUnits(); out.append(next); i += 2
            default:
                flushUnits()
                out.append(c)
                i += 1
            }
        }
        flushUnits()
        return .success(String(out))
    }
}
