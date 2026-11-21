import Foundation

/// How the tools are grouped on the Byte Tools home screen.
enum ByteToolGroup: String, CaseIterable, Identifiable {
    case convert, numbers, text, data, more

    var id: String { rawValue }

    var title: String {
        switch self {
        case .convert: return "Convert"
        case .numbers: return "Numbers & bits"
        case .text: return "Text & encodings"
        case .data: return "Data formats"
        case .more: return "More tools"
        }
    }
}

/// What a tool's tile draws: a few characters, or a symbol from SF Symbols.
enum ByteToolGlyph: Equatable {
    case text(String)
    case symbol(String)
}

/// Every tool in the Byte Tools panel.
///
/// The first twenty are the tools of the two reference apps this panel was
/// modelled on (Binary, Decimal, Hex, Octal, Text, Bitwise, Base, ASCII table,
/// IEEE 754, Two's complement; Bits & bytes, Text → UTF-8, Base64, Float,
/// Varint / ZigZag, ASN.1 / DER, Punycode, URL encoding, URL anatomy, Hexdump),
/// with the universal converter in front and the usual extras behind.
enum ByteTool: String, CaseIterable, Identifiable {
    case universal
    case binary, decimal, hex, octal, baseN, twosComplement, bitsAndBytes, bitwise, float, varint
    case textConverter, utf8, asciiTable, base64, baseEncodings, urlEncoding, urlAnatomy, punycode, htmlEntities
    case hexdump, asn1
    case hashes, timestamp, uuid, jwt, xorCiphers, morse, byteOrder, sizes, ipAddress

    var id: String { rawValue }

    var group: ByteToolGroup {
        switch self {
        case .universal: return .convert
        case .binary, .decimal, .hex, .octal, .baseN, .twosComplement, .bitsAndBytes, .bitwise, .float, .varint:
            return .numbers
        case .textConverter, .utf8, .asciiTable, .base64, .baseEncodings, .urlEncoding, .urlAnatomy, .punycode, .htmlEntities:
            return .text
        case .hexdump, .asn1: return .data
        case .hashes, .timestamp, .uuid, .jwt, .xorCiphers, .morse, .byteOrder, .sizes, .ipAddress: return .more
        }
    }

    var title: String {
        switch self {
        case .universal: return "Universal Converter"
        case .binary: return "Binary Converter"
        case .decimal: return "Decimal Converter"
        case .hex: return "Hex Converter"
        case .octal: return "Octal Converter"
        case .baseN: return "Base Converter"
        case .twosComplement: return "Two's Complement"
        case .bitsAndBytes: return "Bits & Bytes"
        case .bitwise: return "Bitwise Calculator"
        case .float: return "IEEE 754 Float"
        case .varint: return "Varint / ZigZag"
        case .textConverter: return "Text Converter"
        case .utf8: return "Text → UTF-8"
        case .asciiTable: return "ASCII Table"
        case .base64: return "Base64"
        case .baseEncodings: return "Base32 / 58 / 85"
        case .urlEncoding: return "URL Encoding"
        case .urlAnatomy: return "URL Anatomy"
        case .punycode: return "Punycode (IDN)"
        case .htmlEntities: return "HTML Entities"
        case .hexdump: return "Hexdump"
        case .asn1: return "ASN.1 / DER"
        case .hashes: return "Hashes & Checksums"
        case .timestamp: return "Timestamps"
        case .uuid: return "UUID"
        case .jwt: return "JWT Decoder"
        case .xorCiphers: return "XOR & Ciphers"
        case .morse: return "Morse Code"
        case .byteOrder: return "Byte Order"
        case .sizes: return "Data Sizes"
        case .ipAddress: return "IP & CIDR"
        }
    }

    var subtitle: String {
        switch self {
        case .universal: return "Any format to every other"
        case .binary: return "Base 2 numbers"
        case .decimal: return "Base 10 numbers"
        case .hex: return "Base 16 numbers"
        case .octal: return "Base 8 numbers"
        case .baseN: return "Any base 2 to 36"
        case .twosComplement: return "Signed integer bit editor"
        case .bitsAndBytes: return "Flip the switches"
        case .bitwise: return "AND, OR, XOR, shift"
        case .float: return "Float bit breakdown"
        case .varint: return "LEB128 and zigzag"
        case .textConverter: return "Encode and decode text"
        case .utf8: return "Every code point's bytes"
        case .asciiTable: return "Character reference"
        case .base64: return "Step by step"
        case .baseEncodings: return "Base32, Base58, Ascii85"
        case .urlEncoding: return "Percent-encode and decode"
        case .urlAnatomy: return "Scheme, host, path, query"
        case .punycode: return "Domains with accents"
        case .htmlEntities: return "&amp; and friends"
        case .hexdump: return "Offset, hex, ASCII"
        case .asn1: return "Certificates and keys"
        case .hashes: return "MD5, SHA-2, CRC, HMAC"
        case .timestamp: return "Unix time and dates"
        case .uuid: return "Read and make UUIDs"
        case .jwt: return "Decode and check tokens"
        case .xorCiphers: return "XOR, Caesar, Vigenère"
        case .morse: return "Dots and dashes"
        case .byteOrder: return "Endianness"
        case .sizes: return "KB, KiB, MB, bits"
        case .ipAddress: return "IPv4, IPv6 and subnets"
        }
    }

    var glyph: ByteToolGlyph {
        switch self {
        case .universal: return .symbol("arrow.left.arrow.right")
        case .binary: return .text("01")
        case .decimal: return .text("#")
        case .hex: return .text("0x")
        case .octal: return .text("8")
        case .baseN: return .symbol("arrow.left.arrow.right.square")
        case .twosComplement: return .text("±")
        case .bitsAndBytes: return .symbol("switch.2")
        case .bitwise: return .text("&|")
        case .float: return .text("ƒ(x)")
        case .varint: return .text("7b")
        case .textConverter: return .text("Aa")
        case .utf8: return .text("U+")
        case .asciiTable: return .symbol("tablecells")
        case .base64: return .text("b64")
        case .baseEncodings: return .text("b32")
        case .urlEncoding: return .text("%")
        case .urlAnatomy: return .symbol("link")
        case .punycode: return .symbol("globe")
        case .htmlEntities: return .text("&;")
        case .hexdump: return .text("00")
        case .asn1: return .symbol("list.bullet.indent")
        case .hashes: return .symbol("number")
        case .timestamp: return .symbol("clock")
        case .uuid: return .text("ID")
        case .jwt: return .symbol("key")
        case .xorCiphers: return .text("⊕")
        case .morse: return .text("·–")
        case .byteOrder: return .symbol("arrow.left.and.right")
        case .sizes: return .symbol("ruler")
        case .ipAddress: return .text("IP")
        }
    }

    /// The tile's colour, as 0xRRGGBB.
    var tint: UInt32 {
        switch self {
        case .universal: return 0x5E9BFF
        case .binary: return 0x0A84FF
        case .decimal: return 0xFF9F0A
        case .hex: return 0xBF5AF2
        case .octal: return 0x30D158
        case .baseN: return 0x7D7AFF
        case .twosComplement: return 0x64D2FF
        case .bitsAndBytes: return 0x40C8E0
        case .bitwise: return 0x32D4C2
        case .float: return 0x2DD4A7
        case .varint: return 0xFFD60A
        case .textConverter: return 0xFF375F
        case .utf8: return 0xFF6482
        case .asciiTable: return 0xFF453A
        case .base64: return 0xFFB340
        case .baseEncodings: return 0xE8A33D
        case .urlEncoding: return 0x66D4CF
        case .urlAnatomy: return 0x5AC8FA
        case .punycode: return 0x34C759
        case .htmlEntities: return 0xFF7A59
        case .hexdump: return 0xAC8E68
        case .asn1: return 0xA2845E
        case .hashes: return 0xFF6B6B
        case .timestamp: return 0x8E8EF4
        case .uuid: return 0xDA8FFF
        case .jwt: return 0xFB5BA3
        case .xorCiphers: return 0xFF8A65
        case .morse: return 0xC7C7CC
        case .byteOrder: return 0x4DD0E1
        case .sizes: return 0x81C784
        case .ipAddress: return 0x26C6DA
        }
    }

    /// Extra words a search should find this tool by.
    var keywords: [String] {
        switch self {
        case .universal: return ["convert", "any", "format", "encode", "decode", "detect"]
        case .binary: return ["base 2", "bits", "01"]
        case .decimal: return ["base 10", "integer"]
        case .hex: return ["base 16", "hexadecimal"]
        case .octal: return ["base 8", "chmod"]
        case .baseN: return ["radix", "base 36", "any base"]
        case .twosComplement: return ["signed", "negative", "int8", "int16", "int32", "int64", "invert"]
        case .bitsAndBytes: return ["toggle", "flip", "byte", "bit"]
        case .bitwise: return ["and", "or", "xor", "not", "shift", "rotate", "mask", "nand", "nor"]
        case .float: return ["ieee", "754", "double", "single", "half", "mantissa", "exponent", "float32", "float64", "nan", "infinity"]
        case .varint: return ["leb128", "protobuf", "zigzag", "uleb", "sleb", "wasm"]
        case .textConverter: return ["string", "encode", "decode", "text to binary", "text to hex"]
        case .utf8: return ["unicode", "code point", "emoji", "utf-16", "utf8"]
        case .asciiTable: return ["ascii", "control", "latin-1", "character", "chr"]
        case .base64: return ["base64", "b64", "atob", "btoa", "base64url"]
        case .baseEncodings: return ["base32", "base58", "ascii85", "a85", "bitcoin", "totp"]
        case .urlEncoding: return ["percent", "uri", "escape", "encodeuricomponent"]
        case .urlAnatomy: return ["url", "parse", "query", "host", "port", "scheme", "fragment", "split"]
        case .punycode: return ["idn", "xn--", "domain", "homograph", "unicode domain"]
        case .htmlEntities: return ["html", "entity", "escape", "&amp;", "xml"]
        case .hexdump: return ["xxd", "hexdump -c", "od", "dump", "offset"]
        case .asn1: return ["der", "ber", "oid", "x509", "certificate", "pem", "tlv", "rsa"]
        case .hashes: return ["md5", "sha1", "sha256", "sha512", "crc", "crc32", "adler", "fnv", "hmac", "checksum", "digest"]
        case .timestamp: return ["unix", "epoch", "date", "time", "iso 8601", "filetime", "millis"]
        case .uuid: return ["guid", "uuid4", "uuid7", "random"]
        case .jwt: return ["token", "bearer", "json web token", "claims", "hs256"]
        case .xorCiphers: return ["xor", "caesar", "rot13", "rot47", "atbash", "vigenere", "cipher", "ctf", "brute"]
        case .morse: return ["telegraph", "sos", "dot", "dash"]
        case .byteOrder: return ["endian", "endianness", "little", "big", "swap", "htonl", "ntohl", "bswap"]
        case .sizes: return ["kb", "kib", "mb", "mib", "gb", "bits", "storage", "bandwidth"]
        case .ipAddress: return ["ip", "ipv4", "ipv6", "cidr", "subnet", "netmask", "mask", "network", "broadcast", "ptr", "reverse dns", "address", "wildcard"]
        }
    }

    // MARK: Fields

    /// The key under which one of this tool's fields is stored in the shared field store.
    func key(_ field: String) -> String { rawValue + "." + field }

    /// What each field holds when the panel is first opened: an example that
    /// shows what the tool does, never an empty page.
    var defaults: [String: String] {
        switch self {
        case .universal: return ["input": "Hello, world", "from": "auto", "hexDelimiter": " ", "hexPrefix": "", "hexUpper": "0"]
        case .binary: return ["input": "11111111", "grouped": "1"]
        case .decimal: return ["input": "255", "grouped": "1"]
        case .hex: return ["input": "FF", "grouped": "1"]
        case .octal: return ["input": "377", "grouped": "1"]
        case .baseN: return ["input": "255", "from": "10", "to": "16"]
        case .twosComplement: return ["input": "-5", "width": "8"]
        case .bitsAndBytes: return ["input": "127", "width": "8"]
        case .bitwise: return ["a": "202", "b": "166", "op": "and", "width": "8"]
        case .float: return ["input": "0.1", "format": "32"]
        case .varint: return ["input": "300", "hex": "AC 02"]
        case .textConverter: return ["input": "Hello", "from": "text", "to": "binary", "hexDelimiter": " ", "hexPrefix": "", "hexUpper": "0"]
        case .utf8: return ["input": "Hello wörld 🎉"]
        case .asciiTable: return ["query": "", "extended": "0"]
        case .base64: return ["input": "Hello world", "mode": "encode", "variant": "standard", "kind": "text"]
        case .baseEncodings: return ["input": "Hello", "format": "base32", "mode": "encode", "kind": "text"]
        case .urlEncoding: return ["input": "name=Zoë & friends/100%", "mode": "encode", "set": "component"]
        case .urlAnatomy: return ["input": "https://user:p%40ss@example.com:8443/docs/intro?q=two%20words&lang=en#section-3"]
        case .punycode: return ["input": "münchen.de"]
        case .htmlEntities: return ["input": "<p class=\"a\">café & crème</p>", "mode": "encode", "scope": "ascii"]
        case .hexdump: return ["input": "Apex: the bytes are real.", "kind": "text", "mode": "dump", "layout": "canonical", "perLine": "16", "upper": "0"]
        case .asn1: return ["input": "30 14 02 03 01 00 01 06 09 2A 86 48 86 F7 0D 01 01 01 0C 02 68 69", "mode": "parse",
                            "buildType": "integer", "buildValue": "65537", "wrap": "none"]
        case .hashes: return ["input": "hello", "kind": "text", "hmacKey": "", "keyKind": "text", "compare": ""]
        case .timestamp: return ["input": "", "unit": "auto"]
        case .uuid: return ["input": ""]
        case .jwt: return ["input": ByteTool.sampleJWT, "secret": "your-256-bit-secret"]
        case .xorCiphers: return ["input": "Hello, world", "kind": "text", "mode": "xor", "key": "key", "keyKind": "text", "shift": "3"]
        case .morse: return ["input": "SOS", "mode": "encode"]
        case .byteOrder: return ["input": "12 34 56 78"]
        case .sizes: return ["input": "1", "unit": "GiB"]
        case .ipAddress: return ["input": "192.168.1.10/24"]
        }
    }

    /// The jwt.io example token, signed with `your-256-bit-secret`.
    static let sampleJWT = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"

    /// Every tool's example fields, under their full keys.
    static var allDefaults: [String: String] {
        var all: [String: String] = [:]
        for tool in ByteTool.allCases {
            for (field, value) in tool.defaults { all[tool.key(field)] = value }
        }
        return all
    }

    // MARK: Carrying bytes between tools

    /// The most bytes a tool takes from another before it refuses, so a large
    /// file sent from one tool cannot freeze another that lays out every byte.
    static let carryLimit = 4096

    /// The fields to set so that this tool starts from `bytes`, or nil when
    /// the tool cannot take them (the ASCII table has nothing to put them in;
    /// a 64-bit editor cannot hold nine bytes). Keys are the tool's own field
    /// names; `key(_:)` makes them full.
    func seed(from bytes: [UInt8]) -> [String: String]? {
        guard bytes.count <= ByteTool.carryLimit else { return nil }
        let hex = ByteFormat.hex.encode(bytes, style: ByteStyle(delimiter: " ", prefix: "", uppercase: true))
        let compactHex = ByteFormat.hex.encode(bytes, style: ByteStyle(delimiter: "", prefix: "", uppercase: true))
        let isText = ByteFormat.isValidUTF8(bytes) && !bytes.contains(where: { $0 < 0x20 && $0 != 0x0A && $0 != 0x09 && $0 != 0x0D }) && !bytes.isEmpty
        let text = ByteFormat.utf8Text(bytes)
        let number = bytes.isEmpty ? BigNumber.zero : BigNumber(bytes: bytes)

        switch self {
        case .universal:
            return isText ? ["input": text, "from": "text"] : ["input": hex, "from": "hex"]
        case .binary: return ["input": number.toString(base: 2)]
        case .decimal: return ["input": number.toString(base: 10)]
        case .hex: return ["input": number.toString(base: 16)]
        case .octal: return ["input": number.toString(base: 8)]
        case .baseN: return ["input": number.toString(base: 16), "from": "16"]
        case .twosComplement, .bitsAndBytes:
            guard let pattern = BitPattern(bytes: bytes) else { return nil }
            return ["input": "0x" + compactHex, "width": String(pattern.width)]
        case .bitwise:
            guard let pattern = BitPattern(bytes: bytes) else { return nil }
            return ["a": "0x" + compactHex, "width": String(pattern.width)]
        case .float:
            switch bytes.count {
            case 2: return ["input": "0x" + compactHex, "format": "16"]
            case 4: return ["input": "0x" + compactHex, "format": "32"]
            case 8: return ["input": "0x" + compactHex, "format": "64"]
            default: return nil
            }
        case .varint: return ["hex": hex]
        case .textConverter:
            return ["input": hex, "from": "hex", "to": isText ? "text" : "base64"]
        case .utf8: return ["input": text]
        case .asciiTable: return nil
        case .base64: return ["input": isText ? text : hex, "kind": isText ? "text" : "hex", "mode": "encode"]
        case .baseEncodings: return ["input": isText ? text : hex, "kind": isText ? "text" : "hex", "mode": "encode"]
        case .urlEncoding: return ["input": text, "mode": "encode"]
        case .urlAnatomy: return ["input": text]
        case .punycode: return ["input": text]
        case .htmlEntities: return ["input": text, "mode": "encode"]
        case .hexdump: return ["input": hex, "kind": "hex", "mode": "dump"]
        case .asn1: return ["input": hex, "mode": "parse"]
        case .hashes: return ["input": hex, "kind": "hex"]
        case .timestamp:
            guard bytes.count <= 8, !bytes.isEmpty else { return nil }
            return ["input": number.toString(base: 10)]
        case .uuid:
            guard bytes.count == 16, let info = UUIDInfo(bytes: bytes) else { return nil }
            return ["input": info.canonical]
        case .jwt: return isText ? ["input": text] : nil
        case .xorCiphers: return ["input": hex, "kind": "hex"]
        case .morse: return ["input": text, "mode": "encode"]
        case .byteOrder:
            guard [1, 2, 4, 8].contains(bytes.count) else { return nil }
            return ["input": hex]
        case .sizes: return ["input": String(bytes.count), "unit": "B"]
        case .ipAddress:
            guard bytes.count == 4 || bytes.count == 16, let info = IPAddressInfo(bytes: bytes) else { return nil }
            return ["input": info.text]
        }
    }

    /// Whether `bytes` could be sent to this tool, for greying out a menu entry.
    func accepts(_ bytes: [UInt8]) -> Bool { seed(from: bytes) != nil }

    // MARK: Finding tools

    /// The tools that match `query`: by title, subtitle or any keyword, every word of the query needing to match.
    static func matching(_ query: String) -> [ByteTool] {
        let words = query.lowercased().split(whereSeparator: { $0 == " " }).map(String.init)
        guard !words.isEmpty else { return ByteTool.allCases }
        return ByteTool.allCases.filter { tool in
            let haystack = ([tool.title, tool.subtitle] + tool.keywords).joined(separator: " ").lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    static func tools(in group: ByteToolGroup) -> [ByteTool] {
        ByteTool.allCases.filter { $0.group == group }
    }
}
