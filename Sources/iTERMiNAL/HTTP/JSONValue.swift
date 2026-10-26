import Foundation

/// A JSON document that keeps what `JSONSerialization` throws away: the order
/// of an object's keys, and a number exactly as it was written (`1.0` stays
/// `1.0`, a 20-digit id stays whole).
///
/// A person comparing a table to the response it came from expects its columns
/// in the server's order; getting them alphabetised, or an id rounded, would be
/// a bug they would never find.
enum JSONValue: Equatable {
    struct Member: Equatable {
        let key: String
        let value: JSONValue
    }

    case object([Member])
    case array([JSONValue])
    case string(String)
    /// The digits as written.
    case number(String)
    case bool(Bool)
    case null

    // MARK: Reading

    struct ParseError: LocalizedError, Equatable {
        let message: String
        /// Byte offset in the input.
        let position: Int
        var errorDescription: String? { "\(message) (at byte \(position))" }
    }

    /// Nesting deeper than this is refused: a hostile document is not given the
    /// stack.
    static let maxDepth = 200

    /// One JSON value, with nothing after it but whitespace.
    static func parse(_ data: Data) throws -> JSONValue {
        var reader = Reader(Array(data))
        reader.skipByteOrderMark()
        let value = try reader.readValue(depth: 0)
        reader.skipSpace()
        guard reader.atEnd else { throw ParseError(message: "Unexpected data after the value", position: reader.position) }
        return value
    }

    /// A JSON document, or JSON Lines — one value per line, which is what a
    /// streaming API sends — read as an array.
    static func parseDocument(_ data: Data) throws -> JSONValue {
        do {
            return try parse(data)
        } catch let first as ParseError {
            let lines = String(decoding: data, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard lines.count >= 2 else { throw first }
            var values: [JSONValue] = []
            for line in lines {
                guard let value = try? parse(Data(line.utf8)) else { throw first }
                values.append(value)
            }
            return .array(values)
        }
    }

    private struct Reader {
        let bytes: [UInt8]
        var position = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        var atEnd: Bool { position >= bytes.count }

        mutating func skipByteOrderMark() {
            if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { position = 3 }
        }

        mutating func skipSpace() {
            while position < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[position]) { position += 1 }
        }

        func fail(_ message: String) -> ParseError { ParseError(message: message, position: position) }

        mutating func readValue(depth: Int) throws -> JSONValue {
            guard depth <= JSONValue.maxDepth else { throw fail("Nested too deeply") }
            skipSpace()
            guard position < bytes.count else { throw fail("The document ends where a value was expected") }
            switch bytes[position] {
            case UInt8(ascii: "{"): return try readObject(depth: depth)
            case UInt8(ascii: "["): return try readArray(depth: depth)
            case UInt8(ascii: "\""): return .string(try readString())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return try readNumber()
            }
        }

        mutating func expect(_ word: String) throws {
            let expected = Array(word.utf8)
            guard position + expected.count <= bytes.count, Array(bytes[position..<(position + expected.count)]) == expected else {
                throw fail("Expected \(word)")
            }
            position += expected.count
        }

        mutating func readNumber() throws -> JSONValue {
            let start = position
            while position < bytes.count, "+-0123456789.eE".utf8.contains(bytes[position]) { position += 1 }
            guard position > start else { throw fail("Unexpected character") }
            let text = String(decoding: bytes[start..<position], as: UTF8.self)
            guard Double(text) != nil else {
                position = start
                throw fail("\"\(text)\" is not a number")
            }
            return .number(text)
        }

        mutating func readString() throws -> String {
            position += 1   // "
            var out: [UInt8] = []
            while position < bytes.count {
                let byte = bytes[position]
                if byte == UInt8(ascii: "\"") {
                    position += 1
                    return String(decoding: out, as: UTF8.self)
                }
                guard byte == UInt8(ascii: "\\") else {
                    out.append(byte)
                    position += 1
                    continue
                }
                position += 1
                guard position < bytes.count else { break }
                let escape = bytes[position]
                position += 1
                switch escape {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try readHex4()
                    // A high surrogate must be followed by a low one.
                    if (0xD800...0xDBFF).contains(scalar) {
                        if position + 1 < bytes.count, bytes[position] == UInt8(ascii: "\\"), bytes[position + 1] == UInt8(ascii: "u") {
                            position += 2
                            let low = try readHex4()
                            if (0xDC00...0xDFFF).contains(low) {
                                scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                            } else {
                                scalar = 0xFFFD
                            }
                        } else {
                            scalar = 0xFFFD
                        }
                    } else if (0xDC00...0xDFFF).contains(scalar) {
                        scalar = 0xFFFD
                    }
                    out.append(contentsOf: Array(String(Unicode.Scalar(scalar) ?? "\u{FFFD}").utf8))
                default:
                    throw fail("Unknown escape \\\(Character(Unicode.Scalar(escape)))")
                }
            }
            throw fail("The string is never closed")
        }

        mutating func readHex4() throws -> UInt32 {
            guard position + 4 <= bytes.count,
                  let value = UInt32(String(decoding: bytes[position..<(position + 4)], as: UTF8.self), radix: 16) else {
                throw fail("Expected four hex digits after \\u")
            }
            position += 4
            return value
        }

        mutating func readArray(depth: Int) throws -> JSONValue {
            position += 1   // [
            var items: [JSONValue] = []
            skipSpace()
            if position < bytes.count, bytes[position] == UInt8(ascii: "]") {
                position += 1
                return .array(items)
            }
            while true {
                items.append(try readValue(depth: depth + 1))
                skipSpace()
                guard position < bytes.count else { throw fail("The array is never closed") }
                if bytes[position] == UInt8(ascii: ",") { position += 1; continue }
                if bytes[position] == UInt8(ascii: "]") { position += 1; return .array(items) }
                throw fail("Expected , or ] in the array")
            }
        }

        mutating func readObject(depth: Int) throws -> JSONValue {
            position += 1   // {
            var members: [Member] = []
            skipSpace()
            if position < bytes.count, bytes[position] == UInt8(ascii: "}") {
                position += 1
                return .object(members)
            }
            while true {
                skipSpace()
                guard position < bytes.count, bytes[position] == UInt8(ascii: "\"") else { throw fail("Expected a key in quotes") }
                let key = try readString()
                skipSpace()
                guard position < bytes.count, bytes[position] == UInt8(ascii: ":") else { throw fail("Expected : after the key") }
                position += 1
                members.append(Member(key: key, value: try readValue(depth: depth + 1)))
                skipSpace()
                guard position < bytes.count else { throw fail("The object is never closed") }
                if bytes[position] == UInt8(ascii: ",") { position += 1; continue }
                if bytes[position] == UInt8(ascii: "}") { position += 1; return .object(members) }
                throw fail("Expected , or } in the object")
            }
        }
    }

    // MARK: Writing

    /// On one line.
    var compact: String {
        switch self {
        case .object(let members):
            return "{" + members.map { "\(ResultExport.quoted($0.key)):\($0.value.compact)" }.joined(separator: ",") + "}"
        case .array(let items):
            return "[" + items.map(\.compact).joined(separator: ",") + "]"
        case .string(let text): return ResultExport.quoted(text)
        case .number(let text): return text
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "null"
        }
    }

    /// Indented, in the order it was read.
    func pretty(indent: Int = 2) -> String {
        var out = ""
        write(into: &out, level: 0, indent: indent)
        return out
    }

    private func write(into out: inout String, level: Int, indent: Int) {
        let pad = String(repeating: " ", count: (level + 1) * indent)
        let closePad = String(repeating: " ", count: level * indent)
        switch self {
        case .object(let members):
            guard !members.isEmpty else { out += "{}"; return }
            out += "{\n"
            for (index, member) in members.enumerated() {
                out += pad + ResultExport.quoted(member.key) + ": "
                member.value.write(into: &out, level: level + 1, indent: indent)
                out += index == members.count - 1 ? "\n" : ",\n"
            }
            out += closePad + "}"
        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "[\n"
            for (index, item) in items.enumerated() {
                out += pad
                item.write(into: &out, level: level + 1, indent: indent)
                out += index == items.count - 1 ? "\n" : ",\n"
            }
            out += closePad + "]"
        default:
            out += compact
        }
    }

    /// What a table cell shows: a string as itself, a number as written,
    /// nothing for `null`, and a container as compact JSON.
    var cellText: String {
        switch self {
        case .string(let text): return text
        case .number(let text): return text
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return ""
        case .object, .array: return compact
        }
    }

    var isScalar: Bool {
        switch self {
        case .object, .array: return false
        default: return true
        }
    }

    // MARK: Looking

    subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    var arrayItems: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }
}

// MARK: Records as tables

/// Finding the list of records in a JSON document and laying it out as a table
/// — what a person means by "the data" in an API response.
enum JSONTabulator {
    static let maxRows = 5_000
    static let maxColumns = 60

    /// Every array of objects, as a table named by where it was found. The root
    /// array first if it is one; otherwise arrays one or two levels down (the
    /// `{"data": […]}` and `{"result": {"items": […]}}` shapes), largest first.
    static func tables(in root: JSONValue) -> [(path: String, table: ResultTable)] {
        var found: [(path: String, items: [JSONValue])] = []
        func visit(_ value: JSONValue, path: String, depth: Int) {
            switch value {
            case .array(let items):
                let objects = items.filter { if case .object = $0 { return true } else { return false } }
                if objects.count >= 1, objects.count * 2 >= items.count { found.append((path, items)) }
            case .object(let members) where depth < 3:
                for member in members { visit(member.value, path: path + "." + member.key, depth: depth + 1) }
            default:
                break
            }
        }
        visit(root, path: "$", depth: 0)
        // The root, then by size; stable otherwise.
        let ordered = found.enumerated().sorted { lhs, rhs in
            if (lhs.element.path == "$") != (rhs.element.path == "$") { return lhs.element.path == "$" }
            if lhs.element.items.count != rhs.element.items.count { return lhs.element.items.count > rhs.element.items.count }
            return lhs.offset < rhs.offset
        }.map(\.element)
        return ordered.prefix(8).map { entry in (entry.path, table(from: entry.items)) }
    }

    /// Objects as rows, their keys as columns in order of first appearance;
    /// nested objects are flattened one level into `parent.child` columns.
    static func table(from items: [JSONValue]) -> ResultTable {
        var columns: [String] = []
        var seen = Set<String>()
        var records: [[String: String]] = []
        for item in items.prefix(maxRows) {
            var record: [String: String] = [:]
            if case .object(let members) = item {
                for member in members {
                    if case .object(let inner) = member.value, !inner.isEmpty {
                        for sub in inner { put("\(member.key).\(sub.key)", sub.value, into: &record, columns: &columns, seen: &seen) }
                    } else {
                        put(member.key, member.value, into: &record, columns: &columns, seen: &seen)
                    }
                }
            } else {
                put("value", item, into: &record, columns: &columns, seen: &seen)
            }
            records.append(record)
        }
        var table = ResultTable(columns: columns, truncated: items.count > maxRows)
        for record in records {
            let cells = columns.map { record[$0] ?? "" }
            // A cell that is an address is one a person can open or save.
            let url = cells.first { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
            table.append(cells, url: url, canDownload: url != nil && AssetNaming.kind(ofURL: url ?? "") != .other)
        }
        return table
    }

    private static func put(
        _ column: String, _ value: JSONValue,
        into record: inout [String: String], columns: inout [String], seen: inout Set<String>
    ) {
        if !seen.contains(column) {
            guard columns.count < maxColumns else { return }
            seen.insert(column)
            columns.append(column)
        }
        record[column] = value.cellText
    }
}
