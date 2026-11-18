import Foundation

/// A table of delimited values taken apart into rows and fields: which character separates the fields (comma,
/// tab, semicolon or bar), which row is the header, and every field as the run of the file it is, quotes and all.
///
/// A CSV has no signature. It is taken for one when its name says so (.csv, .tsv), or when its first rows all
/// have the same number of fields, two or more, split by the same character. Fields are read as Python's `csv`
/// module reads them, which is what this is checked against: a field may be in double quotes, a quote inside
/// one is two quotes, and a quoted field may hold the delimiter and line ends.
enum TableParser: FormatParser {
    static let identity = FormatIdentity(id: "csv", name: "a CSV table", detail: "delimited values", hasParser: true)

    static let delimiters: [UInt8] = [0x2C, 0x09, 0x3B, 0x7C]
    static let quote: UInt8 = 0x22
    static let groupSize = 1000

    static func delimiterName(_ byte: UInt8) -> String {
        switch byte {
        case 0x2C: return "comma"
        case 0x09: return "tab"
        case 0x3B: return "semicolon"
        case 0x7C: return "bar"
        default: return FieldText.hexNumber(UInt64(byte), size: 1)
        }
    }

    // MARK: Rows

    /// One field: the bytes it takes in the file, its quotes included.
    struct Span: Equatable {
        var start: Int64
        var end: Int64
        var quoted: Bool
    }

    struct Row: Equatable {
        var start: Int64
        var contentEnd: Int64
        var end: Int64
        var ending: TextParser.LineEnd
        var fieldCount = 0
        /// Kept only when asked for.
        var fields: [Span] = []
        /// A quoted field the file ended inside.
        var unterminated = false
        /// Quotes inside a field that did not start with one; they are part of its text.
        var strayQuotes = 0
        /// Characters after a closing quote and before the delimiter; they are part of the field's text.
        var afterQuote = 0

        /// A line with nothing on it, which Python's reader gives as a row of no fields.
        var isBlank: Bool { fieldCount == 0 }
    }

    /// Reads rows from `from` to `end`, giving each to `body` until it returns false. Gives back where it stopped.
    @discardableResult
    static func rows(_ source: ByteSource, delimiter: UInt8, from: Int64, end: Int64, keepsFields: Bool, body: (Row) -> Bool) -> Int64 {
        enum State { case startField, inField, inQuoted, quoteInQuoted }
        var state = State.startField
        var row = Row(start: from, contentEnd: from, end: from, ending: .none)
        var fieldStart = from
        var fieldQuoted = false
        var hasContent = false
        var pendingCR: Int64?
        var position = from

        func endField(_ at: Int64) {
            row.fieldCount += 1
            if keepsFields, row.fields.count < 10_000 { row.fields.append(Span(start: fieldStart, end: at, quoted: fieldQuoted)) }
            fieldQuoted = false
        }
        func finish(contentEnd: Int64, end: Int64, ending: TextParser.LineEnd) -> Bool {
            row.contentEnd = contentEnd
            row.end = end
            row.ending = ending
            let done = row
            row = Row(start: end, contentEnd: end, end: end, ending: .none)
            fieldStart = end
            hasContent = false
            state = .startField
            return body(done)
        }
        /// A line end outside quotes: the field ends, and the row.
        func lineEnd(_ at: Int64, _ byte: UInt8) -> Bool {
            if hasContent { endField(at) }
            if byte == 0x0D {
                pendingCR = at
                return true
            }
            return finish(contentEnd: at, end: at + 1, ending: .lf)
        }

        while position < end {
            let bytes = source.read(position..<min(end, position + 65_536))
            if bytes.isEmpty { break }
            for (index, byte) in bytes.enumerated() {
                let at = position + Int64(index)
                if let cr = pendingCR {
                    pendingCR = nil
                    if byte == 0x0A {
                        if !finish(contentEnd: cr, end: at + 1, ending: .crlf) { return at + 1 }
                        continue
                    }
                    if !finish(contentEnd: cr, end: cr + 1, ending: .cr) { return cr + 1 }
                }
                switch state {
                case .startField:
                    if byte == quote {
                        hasContent = true
                        fieldQuoted = true
                        state = .inQuoted
                    } else if byte == delimiter {
                        hasContent = true
                        endField(at)
                        fieldStart = at + 1
                    } else if byte == 0x0A || byte == 0x0D {
                        if !lineEnd(at, byte) { return at + 1 }
                    } else {
                        hasContent = true
                        state = .inField
                    }
                case .inField:
                    if byte == delimiter {
                        endField(at)
                        fieldStart = at + 1
                        state = .startField
                    } else if byte == 0x0A || byte == 0x0D {
                        if !lineEnd(at, byte) { return at + 1 }
                    } else if byte == quote {
                        row.strayQuotes += 1
                    }
                case .inQuoted:
                    if byte == quote { state = .quoteInQuoted }
                case .quoteInQuoted:
                    if byte == quote {
                        state = .inQuoted
                    } else if byte == delimiter {
                        endField(at)
                        fieldStart = at + 1
                        state = .startField
                    } else if byte == 0x0A || byte == 0x0D {
                        if !lineEnd(at, byte) { return at + 1 }
                    } else {
                        row.afterQuote += 1
                        state = .inField
                    }
                }
            }
            position += Int64(bytes.count)
        }
        if let cr = pendingCR {
            _ = finish(contentEnd: cr, end: cr + 1, ending: .cr)
        } else if hasContent {
            if state == .inQuoted { row.unterminated = true }
            endField(position)
            _ = finish(contentEnd: position, end: position, ending: .none)
        }
        return position
    }

    /// The text of a field, as a reader gives it: its quotes taken off and a doubled quote made one.
    static func value(of raw: [UInt8], quoted: Bool) -> [UInt8] {
        guard quoted, raw.first == quote else { return raw }
        var out: [UInt8] = []
        var index = 1
        var inQuotes = true
        while index < raw.count {
            let byte = raw[index]
            if inQuotes, byte == quote {
                if index + 1 < raw.count, raw[index + 1] == quote {
                    out.append(quote)
                    index += 2
                    continue
                }
                inQuotes = false
            } else {
                out.append(byte)
            }
            index += 1
        }
        return out
    }

    // MARK: Recognising a table

    /// What the first rows say: the delimiter, and the number of fields most rows have.
    struct Sniff: Equatable {
        var delimiter: UInt8
        var fields: Int
        /// Rows looked at, and how many of them have `fields` fields.
        var rows: Int
        var agreeing: Int
    }

    /// The delimiter that splits the first rows of `head` most evenly into two or more fields. The last row is
    /// left out when `head` is only the start of the file, as it may be cut.
    static func sniff(_ head: [UInt8], isWholeFile: Bool, prefer: UInt8? = nil) -> Sniff? {
        var best: Sniff?
        let source = DataByteSource(head)
        for delimiter in delimiters {
            var counts: [Int] = []
            var ends: [Int64] = []
            rows(source, delimiter: delimiter, from: 0, end: Int64(head.count), keepsFields: false) { row in
                if !row.isBlank { counts.append(row.fieldCount); ends.append(row.end) }
                return counts.count < 60
            }
            if !isWholeFile, counts.count > 1, ends.last == Int64(head.count) { counts.removeLast() }
            guard !counts.isEmpty else { continue }
            var tally: [Int: Int] = [:]
            for count in counts { tally[count, default: 0] += 1 }
            guard let mode = tally.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) }) else { continue }
            let candidate = Sniff(delimiter: delimiter, fields: mode.key, rows: counts.count, agreeing: mode.value)
            guard candidate.fields >= 2 else { continue }
            if delimiter == prefer { return candidate }
            if let current = best {
                let better = candidate.agreeing * current.rows > current.agreeing * candidate.rows
                    || (candidate.agreeing * current.rows == current.agreeing * candidate.rows && candidate.fields > current.fields)
                if better { best = candidate }
            } else {
                best = candidate
            }
        }
        return best
    }

    /// The extension of `name`, lower-cased, if it is one a table is saved with.
    static func tableExtension(_ name: String?) -> String? {
        guard let name, let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = name[name.index(after: dot)...].lowercased()
        return ["csv", "tsv", "tab", "psv"].contains(ext) ? ext : nil
    }

    /// Text in an 8-bit encoding (not UTF-16 or UTF-32), and nothing a signature names.
    static func isPlainText(_ head: [UInt8], length: Int64) -> Bool {
        guard let found = TextParser.encoding(of: head), found.encoding == .utf8 else { return false }
        if let named = FormatDetector.identify(head: head, length: length), named.id != "text" { return false }
        return true
    }

    static func matches(head: [UInt8], length: Int64) -> Bool {
        matches(head: head, length: length, name: nil)
    }

    static func matches(head: [UInt8], length: Int64, name: String?) -> Bool {
        guard isPlainText(head, length: length) else { return false }
        if tableExtension(name) != nil { return true }
        let body = TextParser.byteOrderMark(head).map { Array(head.dropFirst($0.length)) } ?? head
        guard let found = sniff(body, isWholeFile: Int64(head.count) >= length) else { return false }
        // Three rows that agree, and at most one that does not.
        return found.rows >= 3 && found.rows - found.agreeing <= max(1, found.rows / 10)
    }

    // MARK: Parsing

    static func parse(_ source: ByteSource, context: ParseContext) -> ParseOutcome {
        var outcome = ParseOutcome()
        let total = source.count
        let head = source.read(0..<min(total, 65_536))
        var start: Int64 = 0
        if let mark = TextParser.byteOrderMark(head), mark.encoding == .utf8 {
            start = Int64(mark.length)
            outcome.roots.append(FieldNode(id: "csv/bom", name: "Byte order mark", offset: 0, length: start, kind: .magic, value: "UTF-8",
                                           note: "EF BB BF: Excel writes it so that it reads the file back as UTF-8. It is not part of the first field."))
        }
        let ext = tableExtension(context.fileName)
        let prefer: UInt8? = ext == "tsv" || ext == "tab" ? 0x09 : ext == "psv" ? 0x7C : nil
        let body = Array(head.dropFirst(Int(start)))
        let sniffed = sniff(body, isWholeFile: Int64(head.count) >= total, prefer: prefer)
        let delimiter = sniffed?.delimiter ?? prefer ?? 0x2C
        let scanEnd = min(total, start + TextParser.scanLimit)

        // Every row, counted; where each thousandth starts, kept.
        var rowCount = 0
        var blank = 0
        var tally: [Int: Int] = [:]
        var widest = 0
        var groupStarts: [Int64] = []
        var listedEnd = start
        var unterminatedAt: Int64?
        var stray = 0
        var after = 0
        var ends: [TextParser.LineEnd: Int] = [:]
        let listLimit = max(1, context.maxRecords)
        var seen = 0
        var cancelled = false
        rows(source, delimiter: delimiter, from: start, end: scanEnd, keepsFields: false) { row in
            if rowCount < listLimit {
                if rowCount % groupSize == 0 { groupStarts.append(row.start) }
                listedEnd = row.end
            }
            rowCount += 1
            if row.isBlank { blank += 1 } else { tally[row.fieldCount, default: 0] += 1 }
            widest = max(widest, row.fieldCount)
            if row.unterminated { unterminatedAt = row.start }
            stray += row.strayQuotes
            after += row.afterQuote
            ends[row.ending, default: 0] += 1
            seen += 1
            if seen & 0x3FFF == 0, context.isCancelled() { cancelled = true; return false }
            return true
        }
        let columns = tally.max { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) }?.key ?? 0

        // The first row is a header when none of it is a number and a later row has a number in that column.
        var header: [String] = []
        var firstRows: [Row] = []
        rows(source, delimiter: delimiter, from: start, end: scanEnd, keepsFields: true) { row in
            if !row.isBlank { firstRows.append(row) }
            return firstRows.count < 20
        }
        func texts(_ row: Row) -> [String] {
            row.fields.map { span in
                String(decoding: value(of: source.read(span.start..<min(span.end, span.start + 512)), quoted: span.quoted), as: UTF8.self)
            }
        }
        func isNumber(_ text: String) -> Bool {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && Double(trimmed.replacingOccurrences(of: ",", with: ".")) != nil
        }
        if let first = firstRows.first, firstRows.count >= 2 {
            let names = texts(first)
            let numberColumns = firstRows.dropFirst().reduce(into: Set<Int>()) { set, row in
                for (index, text) in texts(row).enumerated() where isNumber(text) { set.insert(index) }
            }
            if !names.contains(where: isNumber), names.contains(where: { !$0.isEmpty }), !numberColumns.isEmpty,
               numberColumns.contains(where: { $0 < names.count }) {
                header = names
            }
        }
        let headerRowStart = firstRows.first?.start

        func rowNodes(from groupStart: Int64, firstNumber: Int, count: Int) -> [FieldNode] {
            var nodes: [FieldNode] = []
            var number = firstNumber
            rows(source, delimiter: delimiter, from: groupStart, end: scanEnd, keepsFields: true) { row in
                nodes.append(rowNode(source, row: row, number: number, columns: columns, header: header,
                                     isHeader: !header.isEmpty && row.start == headerRowStart))
                number += 1
                return nodes.count < count
            }
            return nodes
        }
        let listed = min(rowCount, listLimit)
        if listed <= groupSize {
            outcome.roots += rowNodes(from: start, firstNumber: 1, count: listed)
        } else {
            for (index, groupStart) in groupStarts.enumerated() {
                let first = index * groupSize + 1
                let last = min(listed, first + groupSize - 1)
                let groupEnd = index + 1 < groupStarts.count ? groupStarts[index + 1] : listedEnd
                outcome.roots.append(FieldNode(id: "csv/rows-\(first)", name: "Rows \(first)–\(last)", offset: groupStart, length: groupEnd - groupStart,
                                               kind: .container, value: FieldText.bytes(groupEnd - groupStart),
                                               children: .deferred(DeferredChildren { rowNodes(from: groupStart, firstNumber: first, count: last - first + 1) })))
            }
        }
        if rowCount > listed, listedEnd < scanEnd {
            outcome.listingLimit = "The first \(listed) rows are listed; the rest of the file is in the dump."
            outcome.roots.append(FieldNode(id: "csv/more", name: "More rows", offset: listedEnd, length: scanEnd - listedEnd, kind: .bytes, value: "\(rowCount - listed) not listed"))
        }
        if scanEnd < total {
            outcome.listingLimit = "The first \(FieldText.bytes(TextParser.scanLimit)) are read; the rest of the file is in the dump."
            outcome.roots.append(FieldNode(id: "csv/unread", name: "Not read", offset: scanEnd, length: total - scanEnd, kind: .bytes, value: FieldText.bytes(total - scanEnd)))
        }

        // What is wrong.
        if cancelled { outcome.problems.append("Stopped before the end of the file.") }
        if let at = unterminatedAt {
            outcome.problems.append("A quoted field that starts in the row at \(FieldText.hexNumber(UInt64(at), size: 4)) is never closed: the rest of the file is in it.")
        }
        let ragged = tally.filter { $0.key != columns }.reduce(0) { $0 + $1.value }
        if ragged > 0 {
            outcome.problems.append("\(TextParser.count(ragged, "row does not have", "rows do not have")) \(columns) fields, as most rows do.")
        }
        if stray > 0 { outcome.problems.append("\(TextParser.count(stray, "quote is", "quotes are")) inside fields that are not quoted; readers keep them as text.") }
        if after > 0 { outcome.problems.append("\(TextParser.count(after, "character follows", "characters follow")) a closing quote before the delimiter; readers keep them as text.") }

        let dataRows = rowCount - blank - (header.isEmpty ? 0 : 1)
        var summary = "CSV, \(delimiterName(delimiter))-separated, \(TextParser.count(columns, "column", "columns")), "
        summary += header.isEmpty ? "no header, " : "a header and "
        summary += TextParser.count(dataRows, "row", "rows")
        if blank > 0 { summary += ", \(TextParser.count(blank, "blank line", "blank lines"))" }
        if let kind = ends.filter({ $0.key != .none }).max(by: { $0.value < $1.value })?.key { summary += ", \(kind.rawValue) line ends" }
        outcome.summary = summary
        outcome.problems = Array(outcome.problems.prefix(20))
        return outcome
    }

    /// One row: its fields, named by the header's columns, and its line end.
    static func rowNode(_ source: ByteSource, row: Row, number: Int, columns: Int, header: [String], isHeader: Bool) -> FieldNode {
        let id = "csv/row-\(number)"
        if row.isBlank {
            return FieldNode(id: id, name: "Row \(number)", offset: row.start, length: row.end - row.start, kind: .padding, value: "blank",
                             note: "A line with nothing on it. Readers give it as a row with no fields.")
        }
        var texts: [String] = []
        for span in row.fields.prefix(8) {
            let raw = source.read(span.start..<min(span.end, span.start + 120))
            texts.append(TextParser.preview(DataByteSource(value(of: raw, quoted: span.quoted)), from: 0, to: Int64(raw.count), encoding: .utf8, eightBit: false, limit: 24))
        }
        var preview = texts.joined(separator: " · ")
        if row.fieldCount > 8 { preview += " · …" }
        let ragged = row.fieldCount != columns
        var notes: [String] = []
        if ragged { notes.append("\(TextParser.count(row.fieldCount, "field", "fields")), where most rows have \(columns).") }
        if row.unterminated { notes.append("A quoted field here is never closed.") }
        if row.strayQuotes > 0 { notes.append("\(TextParser.count(row.strayQuotes, "quote", "quotes")) inside an unquoted field.") }
        if row.afterQuote > 0 { notes.append("Text after a closing quote.") }
        let problem = ragged || row.unterminated
        return FieldNode(id: id, name: isHeader ? "Header" : "Row \(number)", offset: row.start, length: row.end - row.start,
                         kind: problem ? .problem : (isHeader ? .magic : .container),
                         value: "\(TextParser.count(row.fieldCount, "field", "fields")) · \(preview)",
                         note: notes.isEmpty ? (isHeader ? "The names of the columns." : nil) : notes.joined(separator: " "),
                         children: .deferred(DeferredChildren {
            var nodes: [FieldNode] = []
            for (index, span) in row.fields.enumerated() {
                let raw = source.read(span.start..<min(span.end, span.start + 4096))
                let text = value(of: raw, quoted: span.quoted)
                let column = index < header.count && !isHeader && !header[index].isEmpty ? " · \(header[index])" : ""
                let shown = TextParser.preview(DataByteSource(text), from: 0, to: Int64(text.count), encoding: .utf8, eightBit: false, limit: 80)
                nodes.append(FieldNode(id: id + "/field-\(index + 1)", name: "Field \(index + 1)\(column)", offset: span.start, length: span.end - span.start,
                                       kind: .text, value: span.end == span.start ? "empty" : "\"\(shown)\"",
                                       note: span.quoted ? "In quotes, so it may hold the delimiter, line ends, and a quote written as two." : nil))
            }
            if row.fieldCount > row.fields.count, let last = row.fields.last {
                nodes.append(FieldNode(id: id + "/more", name: "More fields", offset: last.end, length: row.contentEnd - last.end, kind: .bytes,
                                       value: "\(row.fieldCount - row.fields.count) not listed"))
            }
            if row.ending != .none {
                nodes.append(FieldNode(id: id + "/end", name: "Row end", offset: row.contentEnd, length: row.end - row.contentEnd, kind: .padding, value: row.ending.rawValue))
            }
            return nodes
        }))
    }
}
