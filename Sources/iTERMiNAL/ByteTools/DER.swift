import Foundation

/// One element of an ASN.1 encoding: a tag, a length, and either a value or
/// other elements nested inside.
struct ASN1Node: Equatable {
    enum TagClass: Int, Equatable {
        case universal = 0, application, contextSpecific, `private`

        var title: String {
            switch self {
            case .universal: return "UNIVERSAL"
            case .application: return "APPLICATION"
            case .contextSpecific: return "CONTEXT"
            case .private: return "PRIVATE"
            }
        }
    }

    /// Where the element starts in the data.
    let offset: Int
    let tagClass: TagClass
    let isConstructed: Bool
    let tagNumber: Int
    /// Bytes taken by the tag and length together.
    let headerLength: Int
    /// The length the element declared (the bytes of its value).
    let length: Int
    /// True for the BER form whose length is not stated and which ends at a 00 00.
    let isIndefinite: Bool
    let value: [UInt8]
    let children: [ASN1Node]

    /// The whole element: header and value.
    var totalLength: Int { headerLength + length + (isIndefinite ? 2 : 0) }

}

enum ASN1 {
    static let maxDepth = 24
    static let maxNodes = 4000

    // MARK: Reading

    /// Every top-level element in `bytes`.
    static func parse(_ bytes: [UInt8]) -> Result<[ASN1Node], ByteFormatProblem> {
        var budget = maxNodes
        var nodes: [ASN1Node] = []
        var position = 0
        while position < bytes.count {
            switch parseNode(bytes, at: position, base: 0, end: bytes.count, depth: 0, budget: &budget) {
            case .success(let node):
                nodes.append(node)
                position += node.totalLength
            case .failure(let problem):
                if nodes.isEmpty { return .failure(problem) }
                // Keep what read cleanly, and say what is left over.
                return .failure(ByteFormatProblem(message: "\(problem.message) (the \(nodes.count) element\(nodes.count == 1 ? "" : "s") before it read fine)"))
            }
        }
        return nodes.isEmpty ? .failure(ByteFormatProblem(message: "There are no bytes to read.")) : .success(nodes)
    }

    private static func parseNode(_ bytes: [UInt8], at start: Int, base: Int, end: Int, depth: Int, budget: inout Int) -> Result<ASN1Node, ByteFormatProblem> {
        func fail(_ text: String) -> Result<ASN1Node, ByteFormatProblem> {
            .failure(ByteFormatProblem(message: "At byte \(base + start): \(text)"))
        }
        guard depth <= maxDepth else { return fail("nested more than \(maxDepth) levels deep.") }
        guard budget > 0 else { return fail("more than \(maxNodes) elements; the rest is not shown.") }
        budget -= 1
        guard start < end else { return fail("expected a tag, found the end of the data.") }
        var index = start
        let first = bytes[index]
        index += 1
        let tagClass = ASN1Node.TagClass(rawValue: Int(first >> 6)) ?? .universal
        let constructed = first & 0x20 != 0
        var tagNumber = Int(first & 0x1F)
        if tagNumber == 0x1F {
            tagNumber = 0
            var count = 0
            while true {
                guard index < end else { return fail("the tag number is cut off.") }
                let byte = bytes[index]
                index += 1
                count += 1
                guard count <= 4 else { return fail("the tag number is too long.") }
                tagNumber = tagNumber << 7 | Int(byte & 0x7F)
                if byte & 0x80 == 0 { break }
            }
        }
        guard index < end else { return fail("the length is missing.") }
        let lengthByte = bytes[index]
        index += 1
        var length = 0
        var indefinite = false
        if lengthByte < 0x80 {
            length = Int(lengthByte)
        } else if lengthByte == 0x80 {
            guard constructed else { return fail("an indefinite length on a primitive element.") }
            indefinite = true
        } else {
            let count = Int(lengthByte & 0x7F)
            guard count <= 4 else { return fail("a length of \(count) bytes is too large.") }
            guard index + count <= end else { return fail("the length is cut off.") }
            for _ in 0..<count {
                length = length << 8 | Int(bytes[index])
                index += 1
            }
        }
        let header = index - start

        if indefinite {
            var children: [ASN1Node] = []
            var position = index
            while true {
                guard position + 1 < end else { return fail("an indefinite-length element is never closed.") }
                if bytes[position] == 0 && bytes[position + 1] == 0 { break }
                switch parseNode(bytes, at: position, base: base, end: end, depth: depth + 1, budget: &budget) {
                case .success(let child):
                    children.append(child)
                    position += child.totalLength
                case .failure(let problem):
                    return .failure(problem)
                }
            }
            let value = Array(bytes[index..<position])
            return .success(ASN1Node(offset: base + start, tagClass: tagClass, isConstructed: true, tagNumber: tagNumber,
                                     headerLength: header, length: position - index, isIndefinite: true, value: value, children: children))
        }

        guard length <= end - index else {
            return fail("the length says \(length) bytes but only \(end - index) remain.")
        }
        let valueEnd = index + length
        let value = Array(bytes[index..<valueEnd])
        var children: [ASN1Node] = []
        if constructed {
            var position = index
            while position < valueEnd {
                switch parseNode(bytes, at: position, base: base, end: valueEnd, depth: depth + 1, budget: &budget) {
                case .success(let child):
                    children.append(child)
                    position += child.totalLength
                case .failure(let problem):
                    return .failure(problem)
                }
            }
        }
        return .success(ASN1Node(offset: base + start, tagClass: tagClass, isConstructed: constructed, tagNumber: tagNumber,
                                 headerLength: header, length: length, isIndefinite: false, value: value, children: children))
    }

    /// Bytes from what was pasted: PEM, hex or Base64.
    static func bytes(fromText text: String) -> Result<[UInt8], ByteFormatProblem> {
        var body = text
        if body.contains("-----BEGIN") {
            body = body.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                .filter { !$0.hasPrefix("-----") && !$0.contains(":") }
                .joined()
            return Base64Codec.decode(body)
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let hexLike = trimmed.unicodeScalars.allSatisfy { ($0.value < 128 && (BigNumber.digitValue($0).map { $0 < 16 } ?? false)) || " \n\t\r:,xX\\".unicodeScalars.contains($0) }
        if hexLike, case .success(let bytes) = ByteFormat.decodeHex(trimmed) { return .success(bytes) }
        return Base64Codec.decode(trimmed)
    }

    // MARK: Describing

    static let universalNames: [Int: String] = [
        1: "BOOLEAN", 2: "INTEGER", 3: "BIT STRING", 4: "OCTET STRING", 5: "NULL", 6: "OBJECT IDENTIFIER",
        7: "ObjectDescriptor", 9: "REAL", 10: "ENUMERATED", 12: "UTF8String", 13: "RELATIVE-OID",
        16: "SEQUENCE", 17: "SET", 18: "NumericString", 19: "PrintableString", 20: "TeletexString",
        22: "IA5String", 23: "UTCTime", 24: "GeneralizedTime", 26: "VisibleString", 27: "GeneralString",
        28: "UniversalString", 30: "BMPString",
    ]

    static func name(of node: ASN1Node) -> String {
        switch node.tagClass {
        case .universal: return universalNames[node.tagNumber] ?? "tag \(node.tagNumber)"
        case .contextSpecific: return "[\(node.tagNumber)]"
        case .application: return "[APPLICATION \(node.tagNumber)]"
        case .private: return "[PRIVATE \(node.tagNumber)]"
        }
    }

    /// The tag byte as hex (the first byte, for a one-byte tag).
    static func tagHex(of node: ASN1Node, in bytes: [UInt8]) -> String {
        guard node.offset < bytes.count else { return "" }
        return hex([bytes[node.offset]], limit: 1)
    }

    /// What the value of a primitive element means, in words. Empty for
    /// elements that only hold others.
    static func summary(of node: ASN1Node) -> String {
        guard !node.isConstructed else { return "" }
        guard node.tagClass == .universal else {
            return printable(node.value).map { "“\($0)”" } ?? hex(node.value)
        }
        let v = node.value
        switch node.tagNumber {
        case 1:
            return v.count == 1 ? (v[0] == 0 ? "FALSE" : "TRUE") : hex(v)
        case 2, 10:
            return integerText(v)
        case 3:
            guard let unused = v.first else { return "" }
            let content = Array(v.dropFirst())
            return "\(content.count * 8 - Int(unused)) bits" + (unused > 0 ? " (\(unused) unused)" : "") + " · " + hex(content, limit: 24)
        case 4:
            return hex(v, limit: 32) + (printable(v).map { " “\($0)”" } ?? "")
        case 5:
            return ""
        case 6:
            let dotted = oidString(v)
            return oidNames[dotted].map { "\(dotted) (\($0))" } ?? dotted
        case 12, 19, 20, 22, 26, 18, 27:
            return "“\(String(decoding: v, as: UTF8.self))”"
        case 30:
            let units = stride(from: 0, to: v.count - 1, by: 2).map { UInt16(v[$0]) << 8 | UInt16(v[$0 + 1]) }
            return "“\(String(decoding: units, as: UTF16.self))”"
        case 28:
            var text = String.UnicodeScalarView()
            for start in stride(from: 0, to: v.count - 3, by: 4) {
                let code = UInt32(v[start]) << 24 | UInt32(v[start + 1]) << 16 | UInt32(v[start + 2]) << 8 | UInt32(v[start + 3])
                if let scalar = Unicode.Scalar(code) { text.append(scalar) }
            }
            return "“\(String(text))”"
        case 23, 24:
            let text = String(decoding: v, as: UTF8.self)
            return time(text, generalized: node.tagNumber == 24).map { "\(text) → \($0)" } ?? text
        default:
            return hex(v, limit: 32)
        }
    }

    /// A value read as an ASN.1 INTEGER: two's complement, most significant first.
    static func integerText(_ bytes: [UInt8]) -> String {
        guard !bytes.isEmpty else { return "" }
        let negative = bytes[0] & 0x80 != 0
        if bytes.count <= 8 {
            var value: UInt64 = negative ? UInt64.max : 0
            for byte in bytes { value = value << 8 | UInt64(byte) }
            let signed = Int64(bitPattern: value)
            return bytes.count > 2 ? "\(signed) (0x\(hex(bytes, separator: "")))" : "\(signed)"
        }
        // Long integers (keys, serial numbers): the magnitude, shown in hex as well.
        var magnitudeBytes = bytes
        if negative {
            magnitudeBytes = bytes.map { ~$0 }
            var carry = true
            for index in magnitudeBytes.indices.reversed() where carry {
                magnitudeBytes[index] = magnitudeBytes[index] &+ 1
                carry = magnitudeBytes[index] == 0
            }
        }
        let decimal = BigNumber(bytes: magnitudeBytes).toString(base: 10)
        return (negative ? "-" : "") + decimal + " (\(bytes.count * 8) bits)"
    }

    /// An OID's bytes as dotted numbers: 2A 86 48 → 1.2.840.
    static func oidString(_ bytes: [UInt8]) -> String {
        guard !bytes.isEmpty else { return "" }
        var parts: [String] = []
        var value = BigNumber.zero
        var first = true
        for byte in bytes {
            value.multiply(by: 128, add: UInt32(byte & 0x7F))
            if byte & 0x80 == 0 {
                if first {
                    // The first byte folds the first two arcs: 40 * a + b.
                    let combined = value.asUInt64 ?? 0
                    let a = combined < 40 ? 0 : combined < 80 ? 1 : 2
                    parts.append(String(a))
                    parts.append(String(combined - UInt64(a) * 40))
                    first = false
                } else {
                    parts.append(value.toString(base: 10))
                }
                value = .zero
            }
        }
        return parts.joined(separator: ".")
    }

    /// An ASCII reading of `bytes` when every byte is printable, else nil.
    static func printable(_ bytes: [UInt8]) -> String? {
        guard !bytes.isEmpty, bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func hex(_ bytes: [UInt8], limit: Int = 16, separator: String = " ") -> String {
        let digits = Array("0123456789ABCDEF")
        let shown = bytes.prefix(limit).map { String([digits[Int($0 >> 4)], digits[Int($0 & 15)]]) }.joined(separator: separator)
        return bytes.count > limit ? shown + "… (\(bytes.count) bytes)" : shown
    }

    /// `230101000000Z` → `2023-01-01 00:00:00 UTC`.
    static func time(_ text: String, generalized: Bool) -> String? {
        let digits = text.hasSuffix("Z") ? String(text.dropLast()) : text
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        var chars = Array(digits)
        var year = 0
        if generalized {
            guard chars.count >= 12 else { return nil }
            year = Int(String(chars[0..<4])) ?? 0
            chars.removeFirst(4)
        } else {
            guard chars.count >= 10 else { return nil }
            let yy = Int(String(chars[0..<2])) ?? 0
            year = yy >= 50 ? 1900 + yy : 2000 + yy
            chars.removeFirst(2)
        }
        func pair(_ index: Int) -> String { index + 1 < chars.count ? String(chars[index...(index + 1)]) : "00" }
        return "\(year)-\(pair(0))-\(pair(2)) \(pair(4)):\(pair(6)):\(chars.count >= 10 ? pair(8) : "00") UTC"
    }

    /// If a BIT STRING or OCTET STRING holds more ASN.1 (as a public key or an
    /// extension value does), its elements.
    static func nested(in node: ASN1Node) -> [ASN1Node]? {
        guard node.tagClass == .universal, !node.isConstructed else { return nil }
        var content = node.value
        var skip = 0
        if node.tagNumber == 3 {
            guard content.first == 0 else { return nil }
            content.removeFirst()
            skip = 1
        } else if node.tagNumber != 4 {
            return nil
        }
        guard content.count >= 2, [0x30, 0x31, 0x02, 0x06, 0x04, 0x0C, 0x13, 0x16, 0x03, 0xA0, 0xA1, 0xA3].contains(content[0]) else { return nil }
        var budget = 400
        var nodes: [ASN1Node] = []
        var position = 0
        while position < content.count {
            guard case .success(let child) = parseNode(content, at: position, base: node.offset + node.headerLength + skip, end: content.count, depth: 1, budget: &budget) else { return nil }
            nodes.append(child)
            position += child.totalLength
        }
        return nodes.isEmpty ? nil : nodes
    }

    /// A flat, indented listing of the tree for display and copying.
    struct Line: Equatable {
        let depth: Int
        let offset: Int
        let name: String
        let length: Int
        let summary: String
        let isConstructed: Bool
        let childCount: Int
    }

    static func lines(_ nodes: [ASN1Node], depth: Int = 0, revealNested: Bool = true) -> [Line] {
        var out: [Line] = []
        for node in nodes {
            out.append(Line(depth: depth, offset: node.offset, name: name(of: node), length: node.length,
                            summary: summary(of: node), isConstructed: node.isConstructed, childCount: node.children.count))
            out.append(contentsOf: lines(node.children, depth: depth + 1, revealNested: revealNested))
            if revealNested, let inside = nested(in: node) {
                out.append(contentsOf: lines(inside, depth: depth + 1, revealNested: revealNested))
            }
        }
        return out
    }

    // MARK: Writing (DER)

    /// A tag, a definite length in the shortest form, and the content.
    static func tlv(tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        var out = [tag]
        if content.count < 128 {
            out.append(UInt8(content.count))
        } else {
            var lengthBytes: [UInt8] = []
            var rest = content.count
            while rest > 0 {
                lengthBytes.insert(UInt8(rest & 0xFF), at: 0)
                rest >>= 8
            }
            out.append(0x80 | UInt8(lengthBytes.count))
            out.append(contentsOf: lengthBytes)
        }
        return out + content
    }

    /// An INTEGER in its shortest two's-complement form.
    static func integer(_ number: ParsedInteger) -> [UInt8] {
        var bytes = number.magnitude.toBytes()
        if number.isNegative {
            // Two's complement of the magnitude, in as few bytes as hold the sign.
            if bytes[0] & 0x80 != 0 || bytes.count == 1 { bytes.insert(0, at: 0) }
            var inverted = bytes.map { ~$0 }
            var carry = true
            for index in inverted.indices.reversed() where carry {
                inverted[index] = inverted[index] &+ 1
                carry = inverted[index] == 0
            }
            bytes = inverted
            // Trim redundant leading 0xFF bytes.
            while bytes.count > 1, bytes[0] == 0xFF, bytes[1] & 0x80 != 0 { bytes.removeFirst() }
        } else if bytes[0] & 0x80 != 0 {
            bytes.insert(0, at: 0)
        }
        return tlv(tag: 0x02, bytes)
    }

    /// An OBJECT IDENTIFIER from dotted numbers, or nil if it is not one.
    static func objectIdentifier(_ dotted: String) -> [UInt8]? {
        let arcs = dotted.split(separator: ".").compactMap { BigNumber(digits: String($0), base: 10) }
        guard arcs.count == dotted.split(separator: ".").count, arcs.count >= 2,
              let a = arcs[0].asUInt64, let b = arcs[1].asUInt64, a <= 2, a == 2 || b < 40 else { return nil }
        var content = base128(BigNumber(a * 40 + b))
        for arc in arcs.dropFirst(2) { content += base128(arc) }
        return tlv(tag: 0x06, content)
    }

    private static func base128(_ number: BigNumber) -> [UInt8] {
        var work = number
        var groups: [UInt8] = []
        repeat {
            groups.append(UInt8(work.divide(by: 128)))
        } while !work.isZero
        var out: [UInt8] = []
        for (index, group) in groups.enumerated().reversed() {
            out.append(index == 0 ? group : group | 0x80)
        }
        return out
    }

    /// The kinds of element the builder can write.
    static let buildTypes: [(id: String, title: String)] = [
        ("integer", "INTEGER"), ("oid", "OBJECT IDENTIFIER"), ("utf8", "UTF8String"), ("printable", "PrintableString"),
        ("ia5", "IA5String"), ("boolean", "BOOLEAN"), ("null", "NULL"), ("octets", "OCTET STRING"), ("bits", "BIT STRING"),
    ]

    /// One element of `type` holding `value`, as DER. `value` is a number for an
    /// INTEGER, dotted numbers (or a name from the table) for an OID, text for
    /// the strings, `true` or `false` for a BOOLEAN, and hex for the byte strings.
    static func build(type: String, value: String) -> Result<[UInt8], ByteFormatProblem> {
        switch type {
        case "integer":
            return IntegerInput.parse(value).map { integer($0) }
        case "oid":
            let wanted = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let dotted = oidNames.first(where: { $0.value.lowercased() == wanted.lowercased() || $0.value.lowercased().hasPrefix(wanted.lowercased() + " (") })?.key ?? wanted
            guard let encoded = objectIdentifier(dotted) else {
                return .failure(ByteFormatProblem(message: "An OID is dotted numbers like 1.2.840.113549 — at least two, the first 0, 1 or 2 (and under 40 unless it is 2)."))
            }
            return .success(encoded)
        case "utf8": return .success(tlv(tag: 0x0C, Array(value.utf8)))
        case "ia5", "printable":
            let allowed = type == "ia5" ? { (byte: UInt8) in byte < 0x80 } : { (byte: UInt8) in
                (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || " '()+,-./:=?".utf8.contains(byte)
            }
            let bytes = Array(value.utf8)
            guard bytes.allSatisfy(allowed) else {
                return .failure(ByteFormatProblem(message: type == "ia5" ? "IA5String is ASCII only." : "PrintableString has only letters, digits and space ' ( ) + , - . / : = ?"))
            }
            return .success(tlv(tag: type == "ia5" ? 0x16 : 0x13, bytes))
        case "boolean":
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes": return .success([0x01, 0x01, 0xFF])
            case "false", "0", "no": return .success([0x01, 0x01, 0x00])
            default: return .failure(ByteFormatProblem(message: "A BOOLEAN is true or false."))
            }
        case "null": return .success([0x05, 0x00])
        case "octets": return ByteFormat.decodeHex(value).map { tlv(tag: 0x04, $0) }
        case "bits": return ByteFormat.decodeHex(value).map { tlv(tag: 0x03, [0x00] + $0) }
        default: return .failure(ByteFormatProblem(message: "Unknown type."))
        }
    }

    /// `content` wrapped in a SEQUENCE or SET (`wrap` is "sequence" or "set"); anything else leaves it as it is.
    static func wrap(_ element: [UInt8], as wrap: String) -> [UInt8] {
        switch wrap {
        case "sequence": return tlv(tag: 0x30, element)
        case "set": return tlv(tag: 0x31, element)
        default: return element
        }
    }

    /// The name for a well-known object identifier.
    static let oidNames: [String: String] = [
        "1.2.840.113549.1.1.1": "rsaEncryption",
        "1.2.840.113549.1.1.5": "sha1WithRSAEncryption",
        "1.2.840.113549.1.1.10": "RSASSA-PSS",
        "1.2.840.113549.1.1.11": "sha256WithRSAEncryption",
        "1.2.840.113549.1.1.12": "sha384WithRSAEncryption",
        "1.2.840.113549.1.1.13": "sha512WithRSAEncryption",
        "1.2.840.113549.1.9.1": "emailAddress",
        "1.2.840.113549.1.7.1": "pkcs7-data",
        "1.2.840.113549.1.7.2": "pkcs7-signedData",
        "1.2.840.113549.2.5": "md5",
        "1.2.840.10045.2.1": "ecPublicKey",
        "1.2.840.10045.3.1.7": "prime256v1 (P-256)",
        "1.2.840.10045.4.3.2": "ecdsa-with-SHA256",
        "1.2.840.10045.4.3.3": "ecdsa-with-SHA384",
        "1.2.840.10045.4.3.4": "ecdsa-with-SHA512",
        "1.3.132.0.34": "secp384r1 (P-384)",
        "1.3.132.0.35": "secp521r1 (P-521)",
        "1.3.132.0.10": "secp256k1",
        "1.3.101.110": "X25519",
        "1.3.101.112": "Ed25519",
        "1.3.14.3.2.26": "sha1",
        "2.16.840.1.101.3.4.2.1": "sha256",
        "2.16.840.1.101.3.4.2.2": "sha384",
        "2.16.840.1.101.3.4.2.3": "sha512",
        "2.5.4.3": "commonName",
        "2.5.4.5": "serialNumber",
        "2.5.4.6": "countryName",
        "2.5.4.7": "localityName",
        "2.5.4.8": "stateOrProvinceName",
        "2.5.4.10": "organizationName",
        "2.5.4.11": "organizationalUnitName",
        "2.5.29.14": "subjectKeyIdentifier",
        "2.5.29.15": "keyUsage",
        "2.5.29.17": "subjectAltName",
        "2.5.29.19": "basicConstraints",
        "2.5.29.31": "cRLDistributionPoints",
        "2.5.29.32": "certificatePolicies",
        "2.5.29.35": "authorityKeyIdentifier",
        "2.5.29.37": "extKeyUsage",
        "1.3.6.1.5.5.7.1.1": "authorityInfoAccess",
        "1.3.6.1.5.5.7.3.1": "serverAuth",
        "1.3.6.1.5.5.7.3.2": "clientAuth",
        "1.3.6.1.5.5.7.48.1": "ocsp",
        "1.3.6.1.5.5.7.48.2": "caIssuers",
    ]
}
