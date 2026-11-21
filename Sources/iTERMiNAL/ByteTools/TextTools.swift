import Foundation

// MARK: - ASCII table

/// One row of the ASCII (or Latin-1) table.
struct ASCIIEntry: Identifiable, Equatable {
    let code: Int
    /// What to draw: the character, or a control picture for one that has none.
    let glyph: String
    /// `NUL`, `LF`, `DEL` … for the control characters, otherwise nil.
    let abbreviation: String?
    let description: String
    /// How a C string writes it, when it has a short escape.
    let escape: String?

    var id: Int { code }
    var isControl: Bool { abbreviation != nil }
    var hex: String { String(code, radix: 16, uppercase: true).count < 2 ? "0" + String(code, radix: 16, uppercase: true) : String(code, radix: 16, uppercase: true) }
    var octal: String { String(code, radix: 8) }
    var binary: String {
        let text = String(code, radix: 2)
        return String(repeating: "0", count: max(0, 8 - text.count)) + text
    }
    /// The character itself, to copy. Nil for the controls, which have no printable form.
    var character: String? {
        isControl ? nil : String(UnicodeScalar(UInt8(code)))
    }
    /// ^A-style notation for the controls.
    var caret: String? {
        guard code < 32 || code == 127 else { return nil }
        return code == 127 ? "^?" : "^" + String(UnicodeScalar(UInt8(code + 64)))
    }
}

enum ASCIITable {
    private static let controls: [(String, String)] = [
        ("NUL", "Null"), ("SOH", "Start of Heading"), ("STX", "Start of Text"), ("ETX", "End of Text"),
        ("EOT", "End of Transmission"), ("ENQ", "Enquiry"), ("ACK", "Acknowledge"), ("BEL", "Bell (alert)"),
        ("BS", "Backspace"), ("HT", "Horizontal Tab"), ("LF", "Line Feed (newline)"), ("VT", "Vertical Tab"),
        ("FF", "Form Feed"), ("CR", "Carriage Return"), ("SO", "Shift Out"), ("SI", "Shift In"),
        ("DLE", "Data Link Escape"), ("DC1", "Device Control 1 (XON)"), ("DC2", "Device Control 2"),
        ("DC3", "Device Control 3 (XOFF)"), ("DC4", "Device Control 4"), ("NAK", "Negative Acknowledge"),
        ("SYN", "Synchronous Idle"), ("ETB", "End of Transmission Block"), ("CAN", "Cancel"),
        ("EM", "End of Medium"), ("SUB", "Substitute"), ("ESC", "Escape"), ("FS", "File Separator"),
        ("GS", "Group Separator"), ("RS", "Record Separator"), ("US", "Unit Separator"),
    ]

    private static let escapes: [Int: String] = [
        0: "\\0", 7: "\\a", 8: "\\b", 9: "\\t", 10: "\\n", 11: "\\v", 12: "\\f", 13: "\\r", 27: "\\e", 92: "\\\\", 34: "\\\"", 39: "\\'",
    ]

    /// Codes 0–127, or 0–255 with the rest read as Latin-1 (ISO 8859-1).
    static func entries(extended: Bool) -> [ASCIIEntry] {
        (0..<(extended ? 256 : 128)).map(entry)
    }

    static func entry(_ code: Int) -> ASCIIEntry {
        switch code {
        case 0..<32:
            let (name, text) = controls[code]
            return ASCIIEntry(code: code, glyph: String(UnicodeScalar(UInt32(0x2400 + code))!), abbreviation: name, description: text, escape: escapes[code])
        case 32:
            return ASCIIEntry(code: 32, glyph: "␣", abbreviation: nil, description: "Space", escape: nil)
        case 127:
            return ASCIIEntry(code: 127, glyph: "␡", abbreviation: "DEL", description: "Delete", escape: nil)
        case 128..<160:
            return ASCIIEntry(code: code, glyph: "·", abbreviation: "C1", description: "C1 control (Latin-1 has no printable character here)", escape: nil)
        case 160:
            return ASCIIEntry(code: 160, glyph: "⍽", abbreviation: nil, description: "No-break space", escape: nil)
        case 173:
            return ASCIIEntry(code: 173, glyph: "‐", abbreviation: nil, description: "Soft hyphen", escape: nil)
        default:
            let scalar = Unicode.Scalar(UInt32(code))!
            let name = scalar.properties.name?.capitalized ?? "Character"
            return ASCIIEntry(code: code, glyph: String(scalar), abbreviation: nil, description: name, escape: escapes[code])
        }
    }

    /// The entries that match what was typed: a character, a decimal, hex (`0x41` or
    /// `41h`), binary (`01000001`), a control's short name (`lf`), or words from its description.
    static func filter(_ entries: [ASCIIEntry], query: String) -> [ASCIIEntry] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return entries }
        let lower = text.lowercased()
        // An exact reading — a character, a number, a control's name — is what was asked for, so it
        // wins over a word that merely appears in some description ("lf" is in "half").
        var codes = Set<Int>()
        if text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first, scalar.value < 256 {
            codes.insert(Int(scalar.value))
        }
        if let value = Int(lower), value < 256 { codes.insert(value) }
        if lower.hasPrefix("0x"), let value = Int(lower.dropFirst(2), radix: 16) { codes.insert(value) }
        if lower.hasSuffix("h"), let value = Int(lower.dropLast(), radix: 16), lower.count > 1, lower.dropLast().allSatisfy({ $0.isHexDigit }) { codes.insert(value) }
        if lower.count == 8, lower.allSatisfy({ $0 == "0" || $0 == "1" }), let value = Int(lower, radix: 2) { codes.insert(value) }
        if lower.hasPrefix("0b"), let value = Int(lower.dropFirst(2), radix: 2) { codes.insert(value) }
        let named = entries.filter { $0.abbreviation?.lowercased() == lower }
        let exact = entries.filter { codes.contains($0.code) } + named.filter { !codes.contains($0.code) }
        if !exact.isEmpty { return exact }
        let words = lower.split(separator: " ").map(String.init)
        return entries.filter { entry in
            !words.isEmpty && words.allSatisfy { entry.description.lowercased().contains($0) }
        }
    }
}

// MARK: - UTF-8, character by character

/// One Unicode scalar and the bytes it takes, for the "Text → UTF-8" tool.
struct CodePointCard: Identifiable, Equatable {
    let id: Int
    let scalar: Unicode.Scalar
    /// What to draw; controls and spaces get a visible stand-in.
    let glyph: String
    /// `U+0048`.
    let codePoint: String
    let utf8: [UInt8]
    let utf16Units: [UInt16]
    let name: String?

    var utf8Hex: String { ByteFormat.hex.encode(utf8, style: ByteStyle(delimiter: " ", prefix: "", uppercase: true)) }
    var utf16Hex: String {
        utf16Units.map { unit in
            let text = String(unit, radix: 16, uppercase: true)
            return String(repeating: "0", count: max(0, 4 - text.count)) + text
        }.joined(separator: " ")
    }
}

struct TextCounts: Equatable {
    /// What a person would count: user-perceived characters (grapheme clusters).
    let characters: Int
    let scalars: Int
    let utf8Bytes: Int
    let utf16Units: Int
}

enum UTF8Breakdown {
    static func counts(_ text: String) -> TextCounts {
        TextCounts(characters: text.count, scalars: text.unicodeScalars.count, utf8Bytes: text.utf8.count, utf16Units: text.utf16.count)
    }

    static func cards(_ text: String, limit: Int = 300) -> [CodePointCard] {
        text.unicodeScalars.prefix(limit).enumerated().map { index, scalar in
            let value = scalar.value
            let glyph: String
            switch value {
            case 0..<32: glyph = String(UnicodeScalar(0x2400 + value)!)
            case 32: glyph = "␣"
            case 127: glyph = "␡"
            case 0x80..<0xA0: glyph = "·"
            case 0xA0: glyph = "⍽"
            case 0x200B...0x200F, 0x2028...0x202E, 0x2060...0x2064, 0xFEFF: glyph = "◌"
            default: glyph = String(scalar)
            }
            let text = String(scalar)
            let hex = String(value, radix: 16, uppercase: true)
            return CodePointCard(
                id: index, scalar: scalar, glyph: glyph,
                codePoint: "U+" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex,
                utf8: Array(text.utf8), utf16Units: Array(text.utf16),
                name: scalar.properties.name ?? scalar.properties.nameAlias
            )
        }
    }
}

// MARK: - Base64, three bytes at a time

/// One group of up to three bytes and how Base64 turns it into four characters.
struct Base64Group: Equatable {
    let bytes: [UInt8]
    /// The bits, in groups of six; the last may be shorter and is padded with zeros for the lookup.
    let bitGroups: [String]
    /// The alphabet index of each character, nil for a `=` pad.
    let indices: [Int?]
    let characters: [String]
}

enum Base64Steps {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
    private static let urlAlphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    static func groups(_ bytes: [UInt8], urlSafe: Bool, padded: Bool, limit: Int = 200) -> [Base64Group] {
        let table = urlSafe ? urlAlphabet : alphabet
        return stride(from: 0, to: bytes.count, by: 3).prefix(limit).map { start in
            let chunk = Array(bytes[start..<min(start + 3, bytes.count)])
            var bits = ""
            for byte in chunk {
                let text = String(byte, radix: 2)
                bits += String(repeating: "0", count: 8 - text.count) + text
            }
            var bitGroups: [String] = []
            var indices: [Int?] = []
            var characters: [String] = []
            var position = bits.startIndex
            while position < bits.endIndex {
                let end = bits.index(position, offsetBy: 6, limitedBy: bits.endIndex) ?? bits.endIndex
                let piece = String(bits[position..<end])
                bitGroups.append(piece)
                let value = Int(piece.padding(toLength: 6, withPad: "0", startingAt: 0), radix: 2) ?? 0
                indices.append(value)
                characters.append(String(table[value]))
                position = end
            }
            if padded {
                while characters.count < 4 {
                    indices.append(nil)
                    characters.append("=")
                }
            }
            return Base64Group(bytes: chunk, bitGroups: bitGroups, indices: indices, characters: characters)
        }
    }
}

// MARK: - XOR and the simple ciphers

enum Ciphers {
    /// `data` XORed with `key`, the key repeating. An empty key changes nothing.
    static func xor(_ data: [UInt8], key: [UInt8]) -> [UInt8] {
        guard !key.isEmpty else { return data }
        return data.enumerated().map { $0.element ^ key[$0.offset % key.count] }
    }

    /// Letters moved `shift` places along the alphabet, case kept, everything else untouched.
    static func caesar(_ text: String, shift: Int) -> String {
        let amount = ((shift % 26) + 26) % 26
        return String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            switch scalar.value {
            case 0x41...0x5A: return UnicodeScalar((scalar.value - 0x41 + UInt32(amount)) % 26 + 0x41)!
            case 0x61...0x7A: return UnicodeScalar((scalar.value - 0x61 + UInt32(amount)) % 26 + 0x61)!
            default: return scalar
            }
        }))
    }

    /// Every printable ASCII character moved 47 places within the 94 (ROT47).
    static func rot47(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            (0x21...0x7E).contains(scalar.value) ? UnicodeScalar((scalar.value - 0x21 + 47) % 94 + 0x21)! : scalar
        }))
    }

    /// The alphabet reversed: A↔Z, B↔Y.
    static func atbash(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            switch scalar.value {
            case 0x41...0x5A: return UnicodeScalar(0x5A - (scalar.value - 0x41))!
            case 0x61...0x7A: return UnicodeScalar(0x7A - (scalar.value - 0x61))!
            default: return scalar
            }
        }))
    }

    /// Vigenère: a Caesar shift per letter, taken from the repeating key (letters only).
    static func vigenere(_ text: String, key: String, decrypt: Bool) -> String {
        let shifts = key.unicodeScalars.compactMap { scalar -> Int? in
            switch scalar.value {
            case 0x41...0x5A: return Int(scalar.value - 0x41)
            case 0x61...0x7A: return Int(scalar.value - 0x61)
            default: return nil
            }
        }
        guard !shifts.isEmpty else { return text }
        var index = 0
        return String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            let base: UInt32
            switch scalar.value {
            case 0x41...0x5A: base = 0x41
            case 0x61...0x7A: base = 0x61
            default: return scalar
            }
            let shift = shifts[index % shifts.count] * (decrypt ? -1 : 1)
            index += 1
            return UnicodeScalar((UInt32((Int(scalar.value - base) + shift + 26) % 26)) + base)!
        }))
    }

    /// One try of the single-byte XOR break.
    struct XORGuess: Equatable {
        let key: UInt8
        let text: String
        let score: Double
    }

    /// Every single-byte key, best-looking English first: the standard first move
    /// against a message XORed with one repeated byte.
    static func singleByteXORGuesses(_ data: [UInt8], count: Int = 5) -> [XORGuess] {
        guard !data.isEmpty else { return [] }
        let weights: [Character: Double] = [
            " ": 13, "e": 12.7, "t": 9.1, "a": 8.2, "o": 7.5, "i": 7.0, "n": 6.7, "s": 6.3, "h": 6.1, "r": 6.0,
            "d": 4.3, "l": 4.0, "u": 2.8, "c": 2.8, "m": 2.4, "w": 2.4, "f": 2.2, "g": 2.0, "y": 2.0, "p": 1.9, "b": 1.5,
        ]
        let guesses = (0...255).map { key -> XORGuess in
            let plain = data.map { $0 ^ UInt8(key) }
            var score = 0.0
            for byte in plain {
                if byte == 10 || byte == 13 || byte == 9 {
                    score += 0.5
                } else if byte < 32 || byte > 126 {
                    score -= 15
                } else {
                    score += weights[UnicodeScalar(byte).properties.lowercaseMapping.first ?? " "] ?? 0.3
                }
            }
            return XORGuess(key: UInt8(key), text: ByteFormat.utf8Text(plain), score: score / Double(data.count))
        }
        return Array(guesses.sorted { $0.score > $1.score }.prefix(count))
    }
}

// MARK: - Morse

enum Morse {
    private static let table: [Character: String] = [
        "A": ".-", "B": "-...", "C": "-.-.", "D": "-..", "E": ".", "F": "..-.", "G": "--.", "H": "....", "I": "..",
        "J": ".---", "K": "-.-", "L": ".-..", "M": "--", "N": "-.", "O": "---", "P": ".--.", "Q": "--.-", "R": ".-.",
        "S": "...", "T": "-", "U": "..-", "V": "...-", "W": ".--", "X": "-..-", "Y": "-.--", "Z": "--..",
        "0": "-----", "1": ".----", "2": "..---", "3": "...--", "4": "....-", "5": ".....", "6": "-....", "7": "--...",
        "8": "---..", "9": "----.", ".": ".-.-.-", ",": "--..--", "?": "..--..", "'": ".----.", "!": "-.-.--", "/": "-..-.",
        "(": "-.--.", ")": "-.--.-", "&": ".-...", ":": "---...", ";": "-.-.-.", "=": "-...-", "+": ".-.-.", "-": "-....-",
        "_": "..--.-", "\"": ".-..-.", "$": "...-..-", "@": ".--.-.",
    ]

    private static let reverse: [String: Character] = Dictionary(uniqueKeysWithValues: table.map { ($0.value, $0.key) })

    /// Letters separated by a space, words by ` / `. Characters Morse has no code for are dropped.
    static func encode(_ text: String) -> String {
        text.uppercased().split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map { word in
            word.compactMap { table[$0] }.joined(separator: " ")
        }.filter { !$0.isEmpty }.joined(separator: " / ")
    }

    /// Reads dots and dashes (also `·` `−` `_`), letters split by spaces, words by `/` or several spaces.
    static func decode(_ text: String) -> String {
        let normal = text.replacingOccurrences(of: "·", with: ".").replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
        let words = normal.components(separatedBy: CharacterSet(charactersIn: "/|\n"))
            .flatMap { $0.components(separatedBy: "   ") }
        return words.map { word in
            word.split(separator: " ").map { reverse[String($0)].map(String.init) ?? "?" }.joined()
        }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
