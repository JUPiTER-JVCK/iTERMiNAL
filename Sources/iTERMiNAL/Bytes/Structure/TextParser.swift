import Foundation

/// A text file taken apart into lines: which encoding it is in (from a byte order mark, or from what its bytes
/// are), how its lines end, and every line as a run of the file, with the bytes that are not valid characters
/// pointed out.
///
/// It reads the file once, a piece at a time, to count and check, and keeps only where every thousandth line
/// starts; the lines of a thousand are found again when that group is opened. Scripts, XML, HTML, RTF and
/// PostScript are text too, and are taken apart the same way.
enum TextParser: FormatParser {
    static let identity = FormatIdentity(id: "text", name: "text", detail: "lines of characters", hasParser: true)
    static var alsoParses: [String] { ["script", "xml", "html", "rtf", "ps"] }

    /// Lines in a group of the tree.
    static let groupSize = 1000
    /// The most of a file read to count its lines and check its characters.
    static let scanLimit: Int64 = 1 << 30

    enum Encoding: String, Equatable {
        case utf8
        case utf16LittleEndian
        case utf16BigEndian
        case utf32LittleEndian
        case utf32BigEndian

        /// Bytes in one code unit.
        var unit: Int {
            switch self {
            case .utf8: return 1
            case .utf16LittleEndian, .utf16BigEndian: return 2
            case .utf32LittleEndian, .utf32BigEndian: return 4
            }
        }

        var title: String {
            switch self {
            case .utf8: return "UTF-8"
            case .utf16LittleEndian: return "UTF-16 little-endian"
            case .utf16BigEndian: return "UTF-16 big-endian"
            case .utf32LittleEndian: return "UTF-32 little-endian"
            case .utf32BigEndian: return "UTF-32 big-endian"
            }
        }

        func value(_ bytes: ArraySlice<UInt8>) -> UInt32 {
            let b = bytes.map { UInt32($0) }
            switch self {
            case .utf8: return b[0]
            case .utf16LittleEndian: return b[0] | b[1] << 8
            case .utf16BigEndian: return b[0] << 8 | b[1]
            case .utf32LittleEndian: return b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24
            case .utf32BigEndian: return b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]
            }
        }
    }

    /// How a line ends.
    enum LineEnd: String, Equatable {
        case lf = "LF"
        case crlf = "CRLF"
        case cr = "CR"
        /// The last line, with nothing after it.
        case none = "none"
    }

    // MARK: Recognising text

    /// The encoding a byte order mark at the start says, and the mark's length.
    static func byteOrderMark(_ head: [UInt8]) -> (encoding: Encoding, length: Int)? {
        func starts(_ bytes: [UInt8]) -> Bool { head.count >= bytes.count && Array(head.prefix(bytes.count)) == bytes }
        if starts([0xFF, 0xFE, 0x00, 0x00]) { return (.utf32LittleEndian, 4) }
        if starts([0x00, 0x00, 0xFE, 0xFF]) { return (.utf32BigEndian, 4) }
        if starts([0xEF, 0xBB, 0xBF]) { return (.utf8, 3) }
        if starts([0xFF, 0xFE]) { return (.utf16LittleEndian, 2) }
        if starts([0xFE, 0xFF]) { return (.utf16BigEndian, 2) }
        return nil
    }

    /// UTF-16 with no mark: text whose characters are almost all below 256 has a zero in every other byte.
    static func unmarkedUTF16(_ head: [UInt8]) -> Encoding? {
        let sample = Array(head.prefix(4096))
        let pairs = sample.count / 2
        guard pairs >= 4 else { return nil }
        var evenZeros = 0
        var oddZeros = 0
        for index in 0..<pairs {
            if sample[2 * index] == 0 { evenZeros += 1 }
            if sample[2 * index + 1] == 0 { oddZeros += 1 }
        }
        // The other byte of each pair must read as text.
        func readable(_ lane: Int) -> Bool {
            (0..<pairs).allSatisfy { index in
                let byte = sample[2 * index + lane]
                return byte >= 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
            }
        }
        if oddZeros * 10 >= pairs * 9, evenZeros == 0, readable(0) { return .utf16LittleEndian }
        if evenZeros * 10 >= pairs * 9, oddZeros == 0, readable(1) { return .utf16BigEndian }
        return nil
    }

    /// Text if it reads as text: no NULs, and almost nothing but printable characters, tabs and line ends.
    static func looksLikeText(_ head: [UInt8]) -> Bool {
        let sample = head.prefix(2048)
        guard !sample.isEmpty, !sample.contains(0) else { return false }
        let odd = sample.filter { ($0 < 0x20 && ![0x09, 0x0A, 0x0C, 0x0D, 0x1B].contains($0)) || $0 == 0x7F }.count
        return odd * 50 <= sample.count
    }

    /// The encoding `head` is in, and where its text begins; nil if it is not text.
    static func encoding(of head: [UInt8]) -> (encoding: Encoding, start: Int, marked: Bool)? {
        if let mark = byteOrderMark(head) { return (mark.encoding, mark.length, true) }
        if let utf16 = unmarkedUTF16(head) { return (utf16, 0, false) }
        return looksLikeText(head) ? (.utf8, 0, false) : nil
    }

    static func matches(head: [UInt8], length: Int64) -> Bool {
        guard encoding(of: head) != nil else { return false }
        // Not a format with a signature of its own that happens to be printable.
        if let named = FormatDetector.identify(head: head, length: length), named.id != "text", !alsoParses.contains(named.id) { return false }
        return true
    }

    // MARK: Walking lines

    struct Line: Equatable {
        var start: Int64
        /// Where the line's end (its LF, CR or CRLF) begins.
        var contentEnd: Int64
        /// One past the line's end.
        var end: Int64
        var ending: LineEnd
        /// Characters before the line's end.
        var characters: Int64
    }

    /// Goes through the units of `encoding` from `from` to `end`, calling `unit` for each and `line` for each line;
    /// either can say stop by returning false. Gives back where it stopped, and the bytes of a last unit cut short.
    @discardableResult
    static func walk(_ source: ByteSource, encoding: Encoding, from: Int64, end: Int64, unit: (Int64, UInt32) -> Bool = { _, _ in true },
                     line: (Line) -> Bool) -> (stoppedAt: Int64, leftover: Int64) {
        let size = Int64(encoding.unit)
        var position = from
        var lineStart = from
        var characters: Int64 = 0
        var pendingCR: Int64?
        var stopped = false
        func isCharacter(_ value: UInt32) -> Bool {
            switch encoding {
            case .utf8: return value & 0xC0 != 0x80
            case .utf16LittleEndian, .utf16BigEndian: return !(0xDC00...0xDFFF).contains(value)
            default: return true
            }
        }
        reading: while position + size <= end {
            let chunkEnd = min(end, position + 65_536 - 65_536 % size)
            let bytes = source.read(position..<max(chunkEnd, position + size))
            guard bytes.count >= Int(size) else { break }
            var index = 0
            while index + Int(size) <= bytes.count {
                let offset = position + Int64(index)
                let value = size == 1 ? UInt32(bytes[index]) : encoding.value(bytes[index..<(index + Int(size))])
                index += Int(size)
                if let cr = pendingCR {
                    pendingCR = nil
                    if value == 0x0A {
                        let done = Line(start: lineStart, contentEnd: cr, end: offset + size, ending: .crlf, characters: characters)
                        lineStart = offset + size
                        characters = 0
                        if !unit(offset, value) || !line(done) { stopped = true; position = offset + size; break reading }
                        continue
                    }
                    let done = Line(start: lineStart, contentEnd: cr, end: cr + size, ending: .cr, characters: characters)
                    lineStart = cr + size
                    characters = 0
                    if !line(done) { stopped = true; position = cr + size; break reading }
                }
                if !unit(offset, value) { stopped = true; position = offset; break reading }
                if value == 0x0A {
                    let done = Line(start: lineStart, contentEnd: offset, end: offset + size, ending: .lf, characters: characters)
                    lineStart = offset + size
                    characters = 0
                    if !line(done) { stopped = true; position = offset + size; break reading }
                } else if value == 0x0D {
                    pendingCR = offset
                } else if isCharacter(value) {
                    characters += 1
                }
            }
            position += Int64(index)
        }
        if stopped { return (position, 0) }
        if let cr = pendingCR {
            if !line(Line(start: lineStart, contentEnd: cr, end: cr + size, ending: .cr, characters: characters)) { return (cr + size, 0) }
            lineStart = cr + size
            characters = 0
        }
        let leftover = max(0, end - position)
        if lineStart < position {
            _ = line(Line(start: lineStart, contentEnd: position, end: position, ending: .none, characters: characters))
        }
        return (position, leftover)
    }

    // MARK: Checking characters

    /// Finds the bytes that are not characters of the encoding, a unit at a time.
    struct Validator {
        let encoding: Encoding
        /// Where the bad runs start, and how long each is.
        private(set) var bad: [(offset: Int64, length: Int64)] = []
        private(set) var badCount = 0
        /// Characters of more than one byte (or unit) that were valid.
        private(set) var multiUnit = 0
        private(set) var nonASCII = 0
        private var need = 0
        private var lower: UInt32 = 0x80
        private var upper: UInt32 = 0xBF
        private var sequenceStart: Int64 = 0
        private var highSurrogate: Int64?

        init(encoding: Encoding) {
            self.encoding = encoding
        }

        private mutating func flag(_ offset: Int64, _ length: Int64) {
            badCount += 1
            if bad.count < 1000 { bad.append((offset, length)) }
        }

        mutating func add(_ offset: Int64, _ value: UInt32) {
            switch encoding {
            case .utf8: utf8(offset, value)
            case .utf16LittleEndian, .utf16BigEndian:
                if (0xD800...0xDBFF).contains(value) {
                    if let high = highSurrogate { flag(high, 2) }
                    highSurrogate = offset
                } else if (0xDC00...0xDFFF).contains(value) {
                    if highSurrogate != nil { multiUnit += 1; nonASCII += 1 } else { flag(offset, 2) }
                    highSurrogate = nil
                } else {
                    if let high = highSurrogate { flag(high, 2) }
                    highSurrogate = nil
                    if value >= 0x80 { nonASCII += 1 }
                }
            case .utf32LittleEndian, .utf32BigEndian:
                if value > 0x10FFFF || (0xD800...0xDFFF).contains(value) { flag(offset, 4) } else if value >= 0x80 { nonASCII += 1 }
            }
        }

        private mutating func utf8(_ offset: Int64, _ value: UInt32) {
            if need > 0 {
                if value >= lower && value <= upper {
                    need -= 1
                    lower = 0x80
                    upper = 0xBF
                    if need == 0 { multiUnit += 1 }
                    return
                }
                flag(sequenceStart, offset - sequenceStart)
                need = 0
                lower = 0x80
                upper = 0xBF
            }
            sequenceStart = offset
            switch value {
            case 0x00...0x7F: return
            case 0xC2...0xDF: need = 1
            case 0xE0: need = 2; lower = 0xA0
            case 0xE1...0xEC, 0xEE...0xEF: need = 2
            case 0xED: need = 2; upper = 0x9F
            case 0xF0: need = 3; lower = 0x90
            case 0xF1...0xF3: need = 3
            case 0xF4: need = 3; upper = 0x8F
            default: flag(offset, 1); nonASCII += 1; return
            }
            nonASCII += 1
        }

        /// The end of the text: a character still waiting for its last bytes is cut.
        mutating func finish(at end: Int64) {
            if need > 0 { flag(sequenceStart, end - sequenceStart); need = 0 }
            if let high = highSurrogate { flag(high, 2); highSurrogate = nil }
        }

        /// UTF-8 that is not: bytes above 127 and none of them in a valid sequence, as in Latin-1 or Windows-1252.
        var isEightBit: Bool { encoding == .utf8 && badCount > 0 && multiUnit == 0 }
    }

    // MARK: Words

    /// What a line says, for its row in the tree: control characters drawn as their symbols, cut at `limit`.
    static func preview(_ source: ByteSource, from: Int64, to: Int64, encoding: Encoding, eightBit: Bool, limit: Int = 80) -> String {
        let wanted = min(to - from, Int64(limit * 4 + 4))
        guard wanted > 0 else { return "" }
        let bytes = source.read(from..<(from + wanted))
        var text: String
        switch encoding {
        case .utf8:
            text = eightBit ? windows1252(bytes) : String(decoding: bytes, as: UTF8.self)
        case .utf16LittleEndian, .utf16BigEndian:
            let units = stride(from: 0, to: bytes.count - 1, by: 2).map { UInt16(encoding.value(bytes[$0..<($0 + 2)])) }
            text = String(decoding: units, as: UTF16.self)
        case .utf32LittleEndian, .utf32BigEndian:
            let scalars = stride(from: 0, to: bytes.count - 3, by: 4).map { Unicode.Scalar(encoding.value(bytes[$0..<($0 + 4)])) ?? "\u{FFFD}" }
            text = String(String.UnicodeScalarView(scalars))
        }
        var out = String.UnicodeScalarView()
        var count = 0
        for scalar in text.unicodeScalars {
            if count >= limit { return String(out) + "…" }
            switch scalar.value {
            case 0..<0x20: out.append(Unicode.Scalar(0x2400 + scalar.value)!)
            case 0x7F: out.append("\u{2421}")
            default: out.append(scalar)
            }
            count += 1
        }
        return String(out) + (to - from > wanted ? "…" : "")
    }

    /// Bytes as Windows-1252, which is Latin-1 but for 0x80 to 0x9F: the encoding of most 8-bit text that is not UTF-8.
    /// Written out rather than asked of Foundation, which does not have it everywhere.
    static func windows1252(_ bytes: [UInt8]) -> String {
        var out = String.UnicodeScalarView()
        for byte in bytes {
            let value = byte >= 0x80 && byte < 0xA0 ? windows1252High[Int(byte - 0x80)] : UInt32(byte)
            out.append(Unicode.Scalar(value) ?? "\u{FFFD}")
        }
        return String(out)
    }

    /// 0x80 to 0x9F in Windows-1252. The five it leaves undefined are kept as the control characters Latin-1 has there.
    static let windows1252High: [UInt32] = [0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F, 0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178]

    static func count(_ number: Int, _ one: String, _ many: String) -> String {
        "\(number) \(number == 1 ? one : many)"
    }

    // MARK: Parsing

    static func parse(_ source: ByteSource, context: ParseContext) -> ParseOutcome {
        var outcome = ParseOutcome()
        let total = source.count
        let head = source.read(0..<min(total, 4096))
        guard let found = encoding(of: head) else {
            outcome.problems = ["This does not read as text."]
            outcome.roots = [FieldNode(id: "text/bytes", name: "Bytes", offset: 0, length: total, kind: .bytes, value: FieldText.bytes(total))]
            outcome.summary = "Not text"
            return outcome
        }
        let encoding = found.encoding
        let start = Int64(found.start)
        if found.marked {
            outcome.roots.append(FieldNode(id: "text/bom", name: "Byte order mark", offset: 0, length: start, kind: .magic,
                                           value: encoding.title,
                                           note: "U+FEFF at the start says which encoding, and for UTF-16 and UTF-32 which byte comes first. It is not part of the text."))
        }
        let scanEnd = min(total, start + scanLimit)
        var validator = Validator(encoding: encoding)
        var lines = 0
        var ends: [LineEnd: Int] = [:]
        var longest: Int64 = 0
        var nuls = 0
        var controls = 0
        var groupStarts: [Int64] = []
        var listedEnd = start
        let listLimit = max(1, context.maxRecords)
        var checks = 0
        var cancelled = false
        let walked = walk(source, encoding: encoding, from: start, end: scanEnd, unit: { offset, value in
            validator.add(offset, value)
            if value == 0 { nuls += 1 } else if value < 0x20 && value != 0x09 && value != 0x0A && value != 0x0D && value != 0x0C { controls += 1 }
            checks += 1
            if checks & 0xFFFFF == 0, context.isCancelled() { cancelled = true; return false }
            return true
        }, line: { line in
            if lines < listLimit {
                if lines % groupSize == 0 { groupStarts.append(line.start) }
                listedEnd = line.end
            }
            lines += 1
            ends[line.ending, default: 0] += 1
            longest = max(longest, line.characters)
            return true
        })
        validator.finish(at: walked.stoppedAt)
        if cancelled { outcome.problems.append("Stopped before the end of the file.") }
        let eightBit = validator.isEightBit

        // The lines, in groups of a thousand when there are more.
        let listed = min(lines, listLimit)
        func lineNodes(from groupStart: Int64, firstNumber: Int, count: Int) -> [FieldNode] {
            var nodes: [FieldNode] = []
            var number = firstNumber
            walk(source, encoding: encoding, from: groupStart, end: scanEnd) { line in
                nodes.append(lineNode(source, line: line, number: number, encoding: encoding, eightBit: eightBit))
                number += 1
                return nodes.count < count
            }
            return nodes
        }
        if listed <= groupSize {
            outcome.roots += lineNodes(from: start, firstNumber: 1, count: listed)
        } else {
            for (index, groupStart) in groupStarts.enumerated() {
                let first = index * groupSize + 1
                let last = min(listed, first + groupSize - 1)
                let groupEnd = index + 1 < groupStarts.count ? groupStarts[index + 1] : listedEnd
                outcome.roots.append(FieldNode(id: "text/lines-\(first)", name: "Lines \(first)–\(last)", offset: groupStart, length: groupEnd - groupStart,
                                               kind: .container, value: FieldText.bytes(groupEnd - groupStart),
                                               children: .deferred(DeferredChildren { lineNodes(from: groupStart, firstNumber: first, count: last - first + 1) })))
            }
        }
        if lines > listed, listedEnd < scanEnd {
            outcome.listingLimit = "The first \(listed) lines are listed; the rest of the file is in the dump."
            outcome.roots.append(FieldNode(id: "text/more", name: "More lines", offset: listedEnd, length: scanEnd - listedEnd, kind: .bytes,
                                           value: "\(lines - listed) not listed"))
        }
        if walked.leftover > 0, walked.leftover < Int64(encoding.unit), !cancelled {
            let at = scanEnd - walked.leftover
            outcome.roots.append(FieldNode(id: "text/leftover", name: "Part of a character", offset: at, length: walked.leftover, kind: .problem,
                                           value: FieldText.bytes(walked.leftover), note: "\(encoding.title) is in units of \(encoding.unit) bytes, and the file ends partway through one."))
            outcome.problems.append("The file ends partway through a \(encoding.unit)-byte unit of \(encoding.title).")
        }
        if scanEnd < total {
            outcome.listingLimit = "The first \(FieldText.bytes(scanLimit)) are read; the rest of the file is in the dump."
            outcome.roots.append(FieldNode(id: "text/unread", name: "Not read", offset: scanEnd, length: total - scanEnd, kind: .bytes, value: FieldText.bytes(total - scanEnd)))
        }

        // What is wrong.
        if validator.badCount > 0, !eightBit {
            let first = validator.bad.first.map { FieldText.hexNumber(UInt64($0.offset), size: 4) } ?? ""
            outcome.problems.append("\(count(validator.badCount, "run of bytes is", "runs of bytes are")) not valid \(encoding.title), the first at \(first).")
        }
        if nuls > 0, encoding == .utf8 { outcome.problems.append("\(count(nuls, "NUL byte", "NUL bytes")) in the text.") }
        let kinds = ends.filter { $0.key != .none }
        if kinds.count > 1 {
            let words = [LineEnd.lf, .crlf, .cr].compactMap { kind in kinds[kind].map { "\($0) \(kind.rawValue)" } }
            outcome.problems.append("Lines end in more than one way: " + words.joined(separator: ", ") + ".")
        }

        // One line about it.
        var title: String
        if eightBit {
            title = "8-bit, not UTF-8 (Latin-1 or Windows-1252)"
        } else if encoding == .utf8 && validator.nonASCII == 0 && validator.badCount == 0 {
            title = "ASCII"
        } else {
            title = encoding.title
        }
        if found.marked { title += " with a byte order mark" } else if encoding != .utf8 { title += ", no byte order mark" }
        var summary = "Text, \(title), \(count(lines, "line", "lines"))"
        if let kind = kinds.max(by: { $0.value < $1.value })?.key { summary += ", \(kinds.count > 1 ? "mostly " : "")\(kind.rawValue) line ends" }
        if ends[.none] != nil && lines > 1 { summary += ", no line end at the end" }
        summary += ", longest \(longest) \(longest == 1 ? "character" : "characters")"
        if controls > 0 { summary += ", \(count(controls, "control character", "control characters"))" }
        outcome.summary = summary
        outcome.problems = Array(outcome.problems.prefix(20))
        return outcome
    }

    /// One line: its characters, then its line end, with any bytes that are not characters pointed out.
    static func lineNode(_ source: ByteSource, line: Line, number: Int, encoding: Encoding, eightBit: Bool) -> FieldNode {
        let id = "text/line-\(number)"
        let text = preview(source, from: line.start, to: line.contentEnd, encoding: encoding, eightBit: eightBit)
        // Bytes that are not characters, found again in this line alone.
        var validator = Validator(encoding: encoding)
        if !eightBit {
            walk(source, encoding: encoding, from: line.start, end: line.contentEnd, unit: { offset, value in
                validator.add(offset, value)
                return validator.bad.count < 20
            }, line: { _ in true })
            validator.finish(at: line.contentEnd)
        }
        let bad = eightBit ? [] : validator.bad
        return FieldNode(id: id, name: "Line \(number)", offset: line.start, length: line.end - line.start, kind: bad.isEmpty ? .text : .problem,
                         value: line.start == line.contentEnd ? "empty" : "\"\(text)\"",
                         note: bad.isEmpty ? nil : "\(count(bad.count, "run of bytes", "runs of bytes")) here \(bad.count == 1 ? "is" : "are") not valid \(encoding.title).",
                         children: .deferred(DeferredChildren {
            var nodes: [FieldNode] = []
            var cursor = line.start
            for (index, run) in bad.enumerated() where run.offset >= cursor {
                if run.offset > cursor {
                    nodes.append(FieldNode(id: id + "/text-\(index)", name: "Text", offset: cursor, length: run.offset - cursor, kind: .text,
                                           value: "\"\(preview(source, from: cursor, to: run.offset, encoding: encoding, eightBit: false))\""))
                }
                let length = min(run.length, line.contentEnd - run.offset)
                nodes.append(FieldNode(id: id + "/bad-\(index)", name: "Not \(encoding.title)", offset: run.offset, length: max(1, length), kind: .problem,
                                       value: FieldText.hex(ArraySlice(source.read(run.offset..<(run.offset + max(1, length))))),
                                       note: encoding == .utf8 ? "These bytes do not start, or do not finish, a UTF-8 character." : "A surrogate with no partner, or a value beyond U+10FFFF."))
                cursor = run.offset + max(1, length)
            }
            if cursor < line.contentEnd {
                nodes.append(FieldNode(id: id + "/text", name: "Text", offset: cursor, length: line.contentEnd - cursor, kind: .text,
                                       value: bad.isEmpty ? "\(line.characters) \(line.characters == 1 ? "character" : "characters")"
                                           : "\"\(preview(source, from: cursor, to: line.contentEnd, encoding: encoding, eightBit: false))\""))
            }
            if line.ending != .none {
                nodes.append(FieldNode(id: id + "/end", name: "Line end", offset: line.contentEnd, length: line.end - line.contentEnd, kind: .padding,
                                       value: line.ending.rawValue,
                                       note: line.ending == .crlf ? "Carriage return and line feed, as Windows ends lines." : line.ending == .lf ? "Line feed, as Unix and macOS end lines." : "Carriage return alone, as the classic Mac OS ended lines."))
            }
            return nodes
        }))
    }
}
