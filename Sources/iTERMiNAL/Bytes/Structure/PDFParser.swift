import Foundation

/// A PDF file read from the front: the header, then a run of objects (`12 0 obj … endobj`), cross-reference
/// tables that say where each object is, trailers, and `startxref` and `%%EOF` to end each revision.
///
/// A PDF is meant to be read from the end, through `startxref`; read from the front it needs no index,
/// shows every revision a file was saved as, and shows objects an update replaced. Each object is a
/// dictionary, array or value, sometimes followed by a stream of bytes; the stream is skipped by its
/// `/Length` and is never decoded here (most are compressed). What is inside an object is made when it is opened.
enum PDFParser: FormatParser {
    static let identity = FormatIdentity(id: "pdf", name: "a PDF document", detail: "Portable Document Format", hasParser: true)

    /// The most of a file read in all, to find where objects end.
    static let scanBudget: Int64 = 1024 * 1024 * 1024
    /// The most cross-reference entries checked against the objects they point at.
    static let verifyLimit = 2000

    static func matches(head: [UInt8], length: Int64) -> Bool {
        head.count >= 5 && Array(head[0..<5]) == Array("%PDF-".utf8)
    }

    // MARK: Characters

    static func isWhite(_ byte: UInt8) -> Bool {
        byte == 0 || byte == 9 || byte == 10 || byte == 12 || byte == 13 || byte == 32
    }

    static func isDelimiter(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25: return true
        default: return false
        }
    }

    static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

    // MARK: Reading objects

    /// A reader over a file for the little a PDF needs: whitespace, numbers, and the end of an object.
    struct Lexer {
        let scanner: SourceScanner
        let total: Int64

        func byte(_ at: Int64) -> UInt8? { at < total ? scanner.byte(at: at) : nil }

        /// The first offset at or after `at` that is not whitespace; comments are not skipped.
        func skipWhite(_ at: Int64) -> Int64 {
            var position = at
            while position < total, let value = scanner.byte(at: position), isWhite(value) { position += 1 }
            return position
        }

        /// Whitespace and comments.
        func skipSpace(_ at: Int64) -> Int64 {
            var position = skipWhite(at)
            while byte(position) == 0x25 {
                position = endOfLine(position)
                position = skipWhite(position)
            }
            return position
        }

        /// The offset just past the line that `at` is on, including its end-of-line.
        func endOfLine(_ at: Int64) -> Int64 {
            var position = at
            while position < total, let value = scanner.byte(at: position) {
                position += 1
                if value == 10 { break }
                if value == 13 {
                    if byte(position) == 10 { position += 1 }
                    break
                }
            }
            return position
        }

        /// An unsigned decimal at `at`: its value and where it ends.
        func integer(_ at: Int64) -> (value: Int64, end: Int64)? {
            var position = at
            var value: Int64 = 0
            var digits = 0
            while let next = byte(position), isDigit(next), digits < 18 {
                value = value * 10 + Int64(next - 0x30)
                position += 1
                digits += 1
            }
            guard digits > 0 else { return nil }
            if let next = byte(position), isDigit(next) { return nil }
            return (value, position)
        }

        func keyword(_ word: String, at: Int64) -> Bool {
            let bytes = Array(word.utf8)
            guard scanner.matches(bytes, at: at) else { return false }
            let after = at + Int64(bytes.count)
            guard let next = byte(after) else { return true }
            return isWhite(next) || isDelimiter(next)
        }

        /// `12 0 obj`: the number, the generation, and where the object's contents begin.
        func objectHeader(_ at: Int64) -> (number: Int64, generation: Int64, body: Int64)? {
            guard let number = integer(at) else { return nil }
            let gap = skipWhite(number.end)
            guard gap > number.end, let generation = integer(gap) else { return nil }
            let gap2 = skipWhite(generation.end)
            guard gap2 > generation.end, keyword("obj", at: gap2) else { return nil }
            return (number.value, generation.value, gap2 + 3)
        }

        /// Where one object (a dictionary, array, string, name, number or keyword) ends, or nil if it
        /// does not, or is too deep. An indirect reference `5 0 R` is three objects here.
        func skipValue(_ at: Int64, depth: Int = 0) -> Int64? {
            guard depth < 64 else { return nil }
            let start = skipSpace(at)
            guard let first = byte(start) else { return nil }
            switch first {
            case 0x3C where byte(start + 1) == 0x3C:
                var position = start + 2
                while true {
                    position = skipSpace(position)
                    if byte(position) == 0x3E, byte(position + 1) == 0x3E { return position + 2 }
                    guard byte(position) != nil else { return nil }
                    guard let key = skipValue(position, depth: depth + 1) else { return nil }
                    position = key
                    if scanner.isExhausted { return nil }
                }
            case 0x3C:
                var position = start + 1
                while let next = byte(position) {
                    position += 1
                    if next == 0x3E { return position }
                }
                return nil
            case 0x28:
                var position = start + 1
                var level = 1
                while let next = byte(position) {
                    position += 1
                    switch next {
                    case 0x5C: position += 1
                    case 0x28: level += 1
                    case 0x29:
                        level -= 1
                        if level == 0 { return position }
                    default: break
                    }
                }
                return nil
            case 0x5B:
                var position = start + 1
                while true {
                    position = skipSpace(position)
                    if byte(position) == 0x5D { return position + 1 }
                    guard byte(position) != nil, let next = skipValue(position, depth: depth + 1) else { return nil }
                    position = next
                    if scanner.isExhausted { return nil }
                }
            case 0x2F:
                var position = start + 1
                while let next = byte(position), !isWhite(next), !isDelimiter(next) { position += 1 }
                return position
            case 0x29, 0x3E, 0x5D, 0x7D:
                return nil
            default:
                var position = start
                while let next = byte(position), !isWhite(next), !isDelimiter(next) { position += 1 }
                return position > start ? position : nil
            }
        }

        /// One value of a dictionary, taking `12 0 R` as one.
        func skipEntryValue(_ at: Int64) -> Int64? {
            let start = skipSpace(at)
            if let number = integer(start) {
                let gap = skipWhite(number.end)
                if gap > number.end, let generation = integer(gap) {
                    let gap2 = skipWhite(generation.end)
                    if gap2 > generation.end, keyword("R", at: gap2) { return gap2 + 1 }
                }
            }
            return skipValue(start)
        }

        /// The entries of the dictionary that begins at `at`, as key and value ranges: no more than `limit`.
        func entries(_ at: Int64, limit: Int = 300) -> (list: [Entry], end: Int64)? {
            let start = skipSpace(at)
            guard byte(start) == 0x3C, byte(start + 1) == 0x3C else { return nil }
            var position = start + 2
            var list: [Entry] = []
            while true {
                position = skipSpace(position)
                if byte(position) == 0x3E, byte(position + 1) == 0x3E { return (list, position + 2) }
                guard byte(position) == 0x2F, let keyEnd = skipValue(position) else { return nil }
                let valueStart = skipSpace(keyEnd)
                guard let valueEnd = skipEntryValue(valueStart) else { return nil }
                if list.count < limit {
                    let key = String(decoding: scanner.bytes(at: position + 1, count: Int(min(keyEnd - position - 1, 60))).map(HexGeometry.textByte), as: UTF8.self)
                    list.append(Entry(key: key, keyStart: position, valueStart: valueStart, valueEnd: valueEnd))
                } else if scanner.isExhausted {
                    return nil
                }
                position = valueEnd
                if scanner.isExhausted { return nil }
            }
        }

        /// The text of a range, cut at `limit` bytes, with a dot for what is not printable.
        func text(_ from: Int64, _ to: Int64, limit: Int = 100) -> String {
            let count = Int(max(0, min(to - from, Int64(limit))))
            var text = String(decoding: scanner.bytes(at: from, count: count).map { isWhite($0) ? 0x20 : HexGeometry.textByte($0) }, as: UTF8.self)
            if to - from > Int64(limit) { text += "…" }
            return text
        }

        /// The value of `/Length` if it is a plain number.
        func length(in entries: [Entry]) -> Int64? {
            guard let entry = entries.first(where: { $0.key == "Length" }) else { return nil }
            guard let number = integer(entry.valueStart), number.end == entry.valueEnd else { return nil }
            return number.value
        }
    }

    struct Entry {
        let key: String
        let keyStart: Int64
        let valueStart: Int64
        let valueEnd: Int64
    }

    // MARK: The walk

    /// What was learned about one object while the file was walked.
    private struct ObjectFacts {
        var type: String?
        var summary: String
        var problem: String?
    }

    static func parse(_ source: ByteSource, context: ParseContext) -> ParseOutcome {
        var outcome = ParseOutcome()
        let total = source.count
        let scanner = SourceScanner(source: source, budget: scanBudget, isCancelled: context.isCancelled)
        let lexer = Lexer(scanner: scanner, total: total)
        var problems: [String] = []
        var position: Int64 = 0
        var index = 0
        var version = ""
        var objects = 0
        var pages: Int64?
        var revisions = 0
        var encrypted = false
        var linearized = false
        var streamXrefs = 0
        var objectStreams = 0
        var tableMismatches: [String] = []
        var stoppedEarly = false
        var unrecognised = 0

        func note(_ node: FieldNode) { outcome.roots.append(node) }

        while position < total {
            position = lexer.skipWhite(position)
            if position >= total { break }
            if index >= context.maxRecords {
                stoppedEarly = true
                outcome.listingLimit = "The first \(context.maxRecords) items are listed; the rest of the file is in the dump."
                note(FieldNode(id: "pdf/more", name: "More items", offset: position, length: total - position, kind: .bytes,
                               value: "not listed", note: "Listing stops after \(context.maxRecords) items."))
                break
            }
            if context.isCancelled() || scanner.isExhausted {
                stoppedEarly = true
                problems.append(context.isCancelled() ? "Stopped before the end of the file." : "The file is too big to read all of; it is listed as far as \(FieldText.hexNumber(UInt64(position), size: 1)).")
                break
            }
            index += 1
            let start = position
            let at = FieldText.hexNumber(UInt64(start), size: 1)
            guard let first = lexer.byte(position) else { break }

            if first == 0x25 {
                let end = lexer.endOfLine(position)
                var lineEnd = end
                while lineEnd > start, let last = lexer.byte(lineEnd - 1), last == 10 || last == 13 { lineEnd -= 1 }
                let line = lexer.text(start, lineEnd, limit: 60)
                let id = "pdf/comment\(index)"
                if start == 0, line.hasPrefix("%PDF-") {
                    version = String(line.dropFirst(5).prefix { !$0.isWhitespace })
                    note(FieldNode(id: "pdf/header", name: "Header", offset: start, length: end - start, kind: .magic,
                                   value: "PDF \(version)", note: "Every PDF begins with %PDF- and the version of the specification it follows."))
                } else if line.hasPrefix("%%EOF") {
                    revisions += 1
                    note(FieldNode(id: id, name: "End of file marker", offset: start, length: end - start, kind: .magic, value: "%%EOF",
                                   note: "Ends a revision of the file. A file saved again by appending (an incremental update) has more than one."))
                } else if index <= 2, (lexer.scanner.bytes(at: start + 1, count: 4)).contains(where: { $0 >= 0x80 }) {
                    note(FieldNode(id: id, name: "Binary marker", offset: start, length: end - start, kind: .padding, value: lexer.text(start, lineEnd, limit: 20),
                                   note: "A comment of bytes above 127, so that tools that guess whether a file is text decide it is not."))
                } else {
                    note(FieldNode(id: id, name: "Comment", offset: start, length: end - start, kind: .text, value: line))
                }
                position = end
                continue
            }

            if lexer.keyword("xref", at: position) {
                let table = xrefTable(lexer: lexer, at: position, total: total, index: index, mismatches: &tableMismatches, source: source)
                note(table.node)
                position = table.end
                continue
            }
            if lexer.keyword("trailer", at: position) {
                let dictionaryStart = lexer.skipSpace(position + 7)
                guard let dictionary = lexer.entries(dictionaryStart) else {
                    stoppedEarly = true
                    note(FieldNode(id: "pdf/trailer\(index)", name: "Trailer", offset: start, length: total - start, kind: .problem, value: "damaged",
                                   note: "The word trailer is followed by a dictionary, and this one does not end properly."))
                    problems.append("The trailer at \(at) is damaged.")
                    break
                }
                if dictionary.list.contains(where: { $0.key == "Encrypt" }) { encrypted = true }
                let id = "pdf/trailer\(index)"
                let entries = dictionary.list
                let dictStart = dictionaryStart
                let end = dictionary.end
                note(FieldNode(id: id, name: "Trailer", offset: start, length: end - start, kind: .container,
                               value: entryWords(lexer, entries, keys: ["Size", "Root", "Prev", "Encrypt"]),
                               note: "Says where the document's root object is and how many objects there are. In a file read from the end this is where reading begins.",
                               children: .deferred(DeferredChildren {
                    var list = FieldList(idPrefix: id, window: ByteWindow(source: source, at: start, count: 16), endianness: .big)
                    list.bytes("Keyword", at: start, length: 7, kind: .magic, value: "trailer")
                    var nodes = list.nodes
                    nodes.append(dictionaryNode(id: id + "/dictionary", lexer: lexer, start: dictStart, end: end, name: "Dictionary", depth: 0))
                    return nodes
                })))
                position = end
                continue
            }
            if lexer.keyword("startxref", at: position) {
                let numberStart = lexer.skipSpace(position + 9)
                guard let number = lexer.integer(numberStart) else {
                    note(FieldNode(id: "pdf/startxref\(index)", name: "startxref", offset: start, length: 9, kind: .problem, value: "no offset",
                                   note: "startxref is followed by the offset of the last cross-reference section, and no number follows."))
                    problems.append("startxref at \(at) has no offset after it.")
                    position += 9
                    continue
                }
                let target = number.value
                var pointsAt = "nothing recognisable"
                var good = false
                if target >= 0, target < total {
                    if lexer.keyword("xref", at: target) {
                        pointsAt = "a cross-reference table"; good = true
                    } else if let header = lexer.objectHeader(target) {
                        pointsAt = "object \(header.number) (a cross-reference stream)"; good = true
                    }
                }
                if !good { problems.append("startxref at \(at) says the last cross-reference section is at \(target), where there is \(pointsAt).") }
                let id = "pdf/startxref\(index)"
                let numberEnd = number.end
                note(FieldNode(id: id, name: "startxref", offset: start, length: numberEnd - start, kind: good ? .container : .problem,
                               value: "\(target) · \(pointsAt)",
                               note: "Where, counted from the start of the file, the last cross-reference section begins: the first thing a reader looks for, working back from the end.",
                               children: .deferred(DeferredChildren {
                    var list = FieldList(idPrefix: id, window: ByteWindow(source: source, at: start, count: Int(min(numberEnd - start, 64))), endianness: .big)
                    list.bytes("Keyword", at: start, length: 9, kind: .magic, value: "startxref")
                    var nodes = list.nodes
                    nodes.append(FieldNode(id: id + "/offset", name: "Offset", offset: numberStart, length: numberEnd - numberStart, kind: good ? .integer : .problem,
                                           value: "\(target) · \(pointsAt)"))
                    return nodes
                })))
                position = numberEnd
                continue
            }

            if let header = lexer.objectHeader(position) {
                let object = walkObject(lexer: lexer, source: source, start: start, header: header, total: total, index: index)
                objects += 1
                note(object.node)
                if let facts = object.facts {
                    if facts.type == "Pages", pages == nil, !object.hasParent, let count = object.count { pages = count }
                    if facts.type == "XRef" { streamXrefs += 1 }
                    if facts.type == "ObjStm" { objectStreams += 1 }
                    if object.isLinearized, objects == 1 { linearized = true }
                    if let problem = facts.problem { problems.append(problem) }
                }
                if object.end <= position {
                    stoppedEarly = true
                    break
                }
                position = object.end
                if object.fatal { stoppedEarly = true; break }
                continue
            }

            // Something that is none of these: skip to the next line that starts something that is.
            unrecognised += 1
            var resume = lexer.endOfLine(position)
            while resume < total, let next = lexer.byte(resume), !(isDigit(next) || next == 0x25 || next == 0x78 || next == 0x74 || next == 0x73) {
                resume = lexer.endOfLine(resume)
                if scanner.isExhausted { break }
            }
            let held = min(resume, total) - start
            note(FieldNode(id: "pdf/unknown\(index)", name: "Unrecognised data", offset: start, length: held, kind: .problem,
                           value: lexer.text(start, start + held, limit: 40),
                           note: "At the top level a PDF holds objects, cross-reference tables, trailers and startxref; these bytes are none of them."))
            if unrecognised <= 3 { problems.append("Unrecognised data at \(at), where an object, table or trailer should begin.") }
            position = min(resume, total)
            if unrecognised > 200 {
                stoppedEarly = true
                problems.append("Too much of the file is unrecognised to go on listing it.")
                break
            }
        }

        if version.isEmpty, outcome.roots.first?.id != "pdf/header" {
            problems.append("The file does not begin with %PDF-.")
        }
        if revisions == 0, !stoppedEarly {
            problems.append("There is no %%EOF marker, so the file may be cut short.")
        }
        if !tableMismatches.isEmpty {
            problems.append("\(tableMismatches.count) cross-reference \(tableMismatches.count == 1 ? "entry does" : "entries do") not point at the object they name; the first: \(tableMismatches[0]).")
        }
        if encrypted { problems.append("The file is encrypted: the strings and streams in it are scrambled, and are not decoded here.") }
        outcome.problems = Array(problems.prefix(20))
        var summary = "PDF" + (version.isEmpty ? "" : " \(version)")
        summary += ", \(objects) \(objects == 1 ? "object" : "objects")"
        if let pages { summary += ", \(pages) \(pages == 1 ? "page" : "pages")" }
        if revisions > 1 { summary += ", \(revisions) revisions" }
        if linearized { summary += ", linearized" }
        if streamXrefs > 0 { summary += ", compressed cross-references" }
        if objectStreams > 0 { summary += " and object streams" }
        outcome.summary = summary
        return outcome
    }

    /// "Size 5 · Root 1 0 R": a few entries of a dictionary as words.
    private static func entryWords(_ lexer: Lexer, _ entries: [Entry], keys: [String]) -> String {
        keys.compactMap { key in
            entries.first { $0.key == key }.map { "\(key) \(lexer.text($0.valueStart, $0.valueEnd, limit: 24))" }
        }.joined(separator: " · ")
    }

    // MARK: One object

    private struct ObjectResult {
        var node: FieldNode
        var end: Int64
        var facts: ObjectFacts?
        var hasParent = false
        var count: Int64?
        var isLinearized = false
        /// Nothing after this can be read.
        var fatal = false
    }

    private static func walkObject(lexer: Lexer, source: ByteSource, start: Int64, header: (number: Int64, generation: Int64, body: Int64),
                                   total: Int64, index: Int) -> ObjectResult {
        let name = "\(header.number) \(header.generation) obj"
        let id = "pdf/obj\(index)-\(header.number)-\(header.generation)"
        let at = FieldText.hexNumber(UInt64(start), size: 1)
        let bodyStart = lexer.skipSpace(header.body)
        var entries: [Entry] = []
        var valueEnd: Int64?
        var isDictionary = false
        if let dictionary = lexer.entries(bodyStart) {
            entries = dictionary.list
            valueEnd = dictionary.end
            isDictionary = true
        } else {
            valueEnd = lexer.skipValue(bodyStart)
        }
        guard let contentEnd = valueEnd else {
            // The object does not end: nothing after it can be told from its contents.
            let held = total - start
            return ObjectResult(node: FieldNode(id: id, name: name, offset: start, length: held, kind: .problem, value: "damaged",
                                                note: "The contents of this object do not end properly, so where it ends, and where the next object starts, is lost."),
                                end: total, facts: ObjectFacts(type: nil, summary: "", problem: "Object \(header.number) at \(at) does not end properly."), fatal: true)
        }

        var type: String?
        var summary: [String] = []
        if let entry = entries.first(where: { $0.key == "Type" }) {
            type = lexer.text(entry.valueStart, entry.valueEnd, limit: 30).trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            summary.append(type ?? "")
        } else if !isDictionary {
            summary.append(lexer.text(bodyStart, contentEnd, limit: 40))
        }
        for key in ["Subtype", "BaseFont", "Filter", "Type"] where key != "Type" {
            if let entry = entries.first(where: { $0.key == key }) {
                summary.append(lexer.text(entry.valueStart, entry.valueEnd, limit: 30))
            }
        }
        let hasParent = entries.contains { $0.key == "Parent" }
        var count: Int64?
        if let entry = entries.first(where: { $0.key == "Count" }), let number = lexer.integer(entry.valueStart) { count = number.value }
        let isLinearized = entries.contains { $0.key == "Linearized" }

        // A stream follows a dictionary.
        var streamStart: Int64?
        var streamEnd: Int64?
        var streamNote: String?
        var end = contentEnd
        var problem: String?
        let afterValue = lexer.skipSpace(contentEnd)
        if isDictionary, lexer.keyword("stream", at: afterValue) {
            var dataStart = afterValue + 6
            if lexer.byte(dataStart) == 13 { dataStart += 1 }
            if lexer.byte(dataStart) == 10 { dataStart += 1 }
            streamStart = dataStart
            var declared = lexer.length(in: entries)
            if declared == nil, entries.contains(where: { $0.key == "Length" }) { streamNote = "The length is given by another object, so the end of the stream was found by searching for endstream." }
            if let length = declared, length >= 0, dataStart + length <= total {
                let after = lexer.skipWhite(dataStart + length)
                if lexer.keyword("endstream", at: after) {
                    streamEnd = dataStart + length
                    end = after + 9
                } else {
                    declared = nil
                    streamNote = "The stream is not \(FieldText.bytes(length)) long, as its dictionary says: endstream does not follow it. Its end was found by searching."
                }
            } else if declared != nil {
                declared = nil
                streamNote = "The length its dictionary gives runs past the end of the file. The end of the stream was found by searching for endstream."
            }
            if streamEnd == nil {
                if let found = lexer.scanner.find(Array("endstream".utf8), from: dataStart, end: total) {
                    var dataEnd = found
                    if let last = lexer.byte(dataEnd - 1), last == 10 { dataEnd -= 1 }
                    if dataEnd > dataStart, let last = lexer.byte(dataEnd - 1), last == 13 { dataEnd -= 1 }
                    streamEnd = max(dataEnd, dataStart)
                    end = found + 9
                    if streamNote == nil { streamNote = "The length is not a plain number, so the end of the stream was found by searching for endstream." }
                } else {
                    let held = total - start
                    return ObjectResult(node: FieldNode(id: id, name: name, offset: start, length: held, kind: .problem, value: "stream does not end",
                                                        note: "A stream begins and there is no endstream after it."),
                                        end: total, facts: ObjectFacts(type: type, summary: "", problem: "The stream in object \(header.number) at \(at) has no endstream."), fatal: true)
                }
            }
        }
        // endobj
        let afterAll = lexer.skipSpace(end)
        var hasEnd = false
        if lexer.keyword("endobj", at: afterAll) {
            end = afterAll + 6
            hasEnd = true
        } else if problem == nil {
            problem = "Object \(header.number) at \(at) has no endobj after it."
        }
        end = min(end, total)

        if let streamStart, let streamEnd {
            summary.append("stream \(FieldText.bytes(streamEnd - streamStart))")
            _ = streamStart
        }
        let capturedEntries = entries
        let capturedStream = streamStart.flatMap { s in streamEnd.map { (s, $0) } }
        let capturedNote = streamNote
        let capturedBody = bodyStart
        let capturedContentEnd = contentEnd
        let capturedHasEnd = hasEnd
        let capturedEnd = end
        let node = FieldNode(
            id: id, name: name, offset: start, length: end - start, kind: hasEnd ? .container : .problem,
            value: (summary.filter { !$0.isEmpty }.joined(separator: " · ")).isEmpty ? nil : summary.filter { !$0.isEmpty }.joined(separator: " · "),
            note: objectNote(type: type, isStream: streamStart != nil),
            children: .deferred(DeferredChildren {
                objectChildren(id: id, lexer: lexer, source: source, start: start, header: header, bodyStart: capturedBody, contentEnd: capturedContentEnd,
                               isDictionary: !capturedEntries.isEmpty || isDictionary, stream: capturedStream, streamNote: capturedNote,
                               end: capturedEnd, hasEnd: capturedHasEnd)
            }))
        var result = ObjectResult(node: node, end: end, facts: ObjectFacts(type: type, summary: summary.joined(separator: " · "), problem: problem))
        result.hasParent = hasParent
        result.count = count
        result.isLinearized = isLinearized
        return result
    }

    private static func objectNote(type: String?, isStream: Bool) -> String? {
        switch type {
        case "Catalog": return "The root of the document: it points at the page tree and the other top-level structures."
        case "Pages": return "A node of the page tree: its Kids are pages or more nodes, and Count is how many pages are below it."
        case "Page": return "One page: its size (MediaBox), its resources and its content stream."
        case "Font": return "A font the pages use."
        case "XRef": return "A cross-reference stream: the index of objects, as a compressed table, in place of a cross-reference table. Not decoded here."
        case "ObjStm": return "An object stream: several objects stored compressed inside one stream. Not decoded here, so these objects are not listed."
        case "Metadata": return "Document metadata as XMP, an XML packet."
        default: return isStream ? "An object with a stream of bytes: page content, an image, a font file. The bytes are usually compressed." : nil
        }
    }

    private static func objectChildren(id: String, lexer: Lexer, source: ByteSource, start: Int64, header: (number: Int64, generation: Int64, body: Int64),
                                       bodyStart: Int64, contentEnd: Int64, isDictionary: Bool, stream: (Int64, Int64)?, streamNote: String?,
                                       end: Int64, hasEnd: Bool) -> [FieldNode] {
        var nodes: [FieldNode] = []
        let numberEnd = lexer.integer(start)?.end ?? start
        nodes.append(FieldNode(id: id + "/number", name: "Object number", offset: start, length: numberEnd - start, kind: .integer, value: "\(header.number)",
                               note: "What other objects call this one: 12 0 R is a reference to object 12."))
        let genStart = lexer.skipWhite(numberEnd)
        let genEnd = lexer.integer(genStart)?.end ?? genStart
        nodes.append(FieldNode(id: id + "/generation", name: "Generation", offset: genStart, length: genEnd - genStart, kind: .integer, value: "\(header.generation)",
                               note: "0 unless the object was deleted and its number used again."))
        let keywordStart = lexer.skipWhite(genEnd)
        nodes.append(FieldNode(id: id + "/keyword", name: "obj", offset: keywordStart, length: 3, kind: .magic, value: "obj"))
        if isDictionary, lexer.entries(bodyStart) != nil {
            nodes.append(dictionaryNode(id: id + "/dictionary", lexer: lexer, start: bodyStart, end: contentEnd, name: "Dictionary", depth: 0))
        } else {
            nodes.append(FieldNode(id: id + "/value", name: "Value", offset: bodyStart, length: contentEnd - bodyStart, kind: .text,
                                   value: lexer.text(bodyStart, contentEnd, limit: 200)))
        }
        if let (dataStart, dataEnd) = stream {
            let keyword = lexer.skipSpace(contentEnd)
            nodes.append(FieldNode(id: id + "/stream-keyword", name: "stream", offset: keyword, length: 6, kind: .magic, value: "stream"))
            nodes.append(FieldNode(id: id + "/stream-data", name: "Stream data", offset: dataStart, length: dataEnd - dataStart, kind: .bytes,
                                   value: FieldText.bytes(dataEnd - dataStart),
                                   note: streamNote ?? "The bytes of the stream, as stored: usually compressed, as its Filter says. Not decoded here."))
            let after = lexer.skipWhite(dataEnd)
            if lexer.keyword("endstream", at: after) {
                nodes.append(FieldNode(id: id + "/endstream", name: "endstream", offset: after, length: 9, kind: .magic, value: "endstream"))
            } else if let found = lexer.scanner.find(Array("endstream".utf8), from: dataEnd, end: min(dataEnd + 4, lexer.total)) {
                nodes.append(FieldNode(id: id + "/endstream", name: "endstream", offset: found, length: 9, kind: .magic, value: "endstream"))
            }
        }
        if hasEnd {
            let word = max(start, end - 6)
            nodes.append(FieldNode(id: id + "/endobj", name: "endobj", offset: word, length: 6, kind: .magic, value: "endobj"))
        }
        return nodes
    }

    // MARK: Dictionaries

    /// A dictionary as a node whose children are its entries; a value that is itself a dictionary opens in turn.
    private static func dictionaryNode(id: String, lexer: Lexer, start: Int64, end: Int64, name: String, depth: Int) -> FieldNode {
        let first = lexer.skipSpace(start)
        let entries = lexer.entries(first)?.list ?? []
        return FieldNode(id: id, name: name, offset: first, length: max(0, end - first), kind: .container,
                         value: "\(entries.count)\(entries.count >= 300 ? "+" : "") \(entries.count == 1 ? "entry" : "entries")",
                         note: depth == 0 ? "Pairs of a name and a value, between << and >>." : nil,
                         children: .deferred(DeferredChildren {
            var nodes: [FieldNode] = []
            for (number, entry) in entries.enumerated() {
                let entryID = id + "/e\(number + 1)-" + FieldList.slug(entry.key)
                let isDictionary = lexer.byte(entry.valueStart) == 0x3C && lexer.byte(entry.valueStart + 1) == 0x3C
                if isDictionary, depth < 8 {
                    var child = dictionaryNode(id: entryID, lexer: lexer, start: entry.valueStart, end: entry.valueEnd, name: "/" + entry.key, depth: depth + 1)
                    child.offset = entry.keyStart
                    child.length = entry.valueEnd - entry.keyStart
                    nodes.append(child)
                } else {
                    nodes.append(FieldNode(id: entryID, name: "/" + entry.key, offset: entry.keyStart, length: entry.valueEnd - entry.keyStart,
                                           kind: lexer.byte(entry.valueStart) == 0x28 || lexer.byte(entry.valueStart) == 0x3C ? .text : .integer,
                                           value: lexer.text(entry.valueStart, entry.valueEnd, limit: 120), note: keyNote(entry.key)))
                }
            }
            return nodes
        }))
    }

    private static func keyNote(_ key: String) -> String? {
        switch key {
        case "Length": return "How many bytes the stream is, so a reader can skip it without looking inside."
        case "Filter": return "How the stream was compressed or encoded; FlateDecode is zlib."
        case "Root": return "The document's catalog object."
        case "Size": return "One more than the highest object number."
        case "Prev": return "The offset of the cross-reference section of the revision before this one."
        case "Parent": return "The node above this one in the page tree."
        case "Kids": return "The children of this node."
        case "Contents": return "The stream that draws the page."
        case "MediaBox": return "The page's size: left, bottom, right, top, in points (1/72 inch)."
        case "Encrypt": return "The file is encrypted: strings and streams are scrambled."
        case "ID": return "Two strings that identify the document and this version of it."
        case "W": return "How many bytes each field of a cross-reference stream entry has."
        case "Index": return "Which object numbers the entries are for: pairs of a first number and a count."
        default: return nil
        }
    }

    // MARK: Cross-reference tables

    private static func xrefTable(lexer: Lexer, at start: Int64, total: Int64, index: Int, mismatches: inout [String], source: ByteSource) -> (node: FieldNode, end: Int64) {
        let id = "pdf/xref\(index)"
        struct Section { var first: Int64; var count: Int64; var entries: Int64 }
        var sections: [Section] = []
        var position = lexer.skipSpace(start + 4)
        var checked = 0
        var damaged = false
        while let first = lexer.integer(position) {
            let gap = lexer.skipWhite(first.end)
            guard gap > first.end, let count = lexer.integer(gap) else { break }
            let entriesStart = lexer.skipWhite(count.end)
            var section = Section(first: first.value, count: count.value, entries: entriesStart)
            // Each entry is 20 bytes: 10 digits, a space, 5 digits, a space, n or f, and two bytes of end of line.
            var offset = entriesStart
            var seen: Int64 = 0
            while seen < count.value, offset + 18 <= total {
                guard let object = lexer.integer(offset), object.end - offset == 10, lexer.byte(object.end) == 0x20,
                      let generation = lexer.integer(object.end + 1), generation.end - (object.end + 1) == 5, lexer.byte(generation.end) == 0x20,
                      let flag = lexer.byte(generation.end + 1), flag == 0x6E || flag == 0x66 else {
                    damaged = true
                    break
                }
                if flag == 0x6E, checked < verifyLimit, object.value > 0 {
                    checked += 1
                    let number = first.value + seen
                    let head = ByteWindow(source: source, at: object.value, count: 40)
                    let text = String(decoding: head.bytes.map(HexGeometry.textByte), as: UTF8.self)
                    let words = text.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                    if !(words.count >= 3 && words[0] == Substring("\(number)") && words[1] == Substring("\(Int64(generation.value))") && words[2].hasPrefix("obj")), mismatches.count < 100 {
                        mismatches.append("object \(number) says offset \(object.value)")
                    }
                }
                offset += 20
                seen += 1
            }
            section.entries = entriesStart
            sections.append(section)
            position = lexer.skipSpace(offset)
            if damaged || sections.count > 500 { break }
        }
        // The entries a section declares are part of it, even if the file ends in them or they are damaged.
        let declaredEnd = sections.map { min($0.entries + max(0, $0.count) * 20, total) }.max() ?? position
        let end = min(max(position, declaredEnd), total)
        let total2 = sections.reduce(Int64(0)) { $0 + $1.count }
        let captured = sections
        let node = FieldNode(
            id: id, name: "Cross-reference table", offset: start, length: min(max(4, end - start), total - start), kind: damaged ? .problem : .container,
            value: "\(total2) \(total2 == 1 ? "entry" : "entries") in \(sections.count) \(sections.count == 1 ? "section" : "sections")",
            note: "Where each object is, as 20-byte lines: its offset, its generation, and n (in use) or f (free). A reader finds objects through this without reading the file.",
            children: .deferred(DeferredChildren {
                var nodes = [FieldNode(id: id + "/keyword", name: "xref", offset: start, length: 4, kind: .magic, value: "xref")]
                for (number, section) in captured.enumerated() {
                    let sid = id + "/section\(number + 1)"
                    let shown = min(section.count, 32)
                    var rows: [FieldNode] = []
                    for row in 0..<shown {
                        let rowStart = section.entries + row * 20
                        guard rowStart + 18 <= total, let offset = lexer.integer(rowStart) else { break }
                        let flag = lexer.byte(rowStart + 17).map { $0 == 0x6E ? "in use" : "free" } ?? "?"
                        let objectNumber = section.first + row
                        var words = "offset \(offset.value) · \(flag)"
                        if flag == "in use", offset.value < total, let header = lexer.objectHeader(offset.value) {
                            words += header.number == objectNumber ? " · points at \(header.number) \(header.generation) obj" : " · points at object \(header.number), not \(objectNumber)"
                        }
                        rows.append(FieldNode(id: sid + "/row\(row + 1)", name: "Object \(objectNumber)", offset: rowStart, length: min(20, total - rowStart), kind: flag == "in use" ? .integer : .padding, value: words))
                    }
                    if section.count > shown {
                        let more = section.count - shown
                        let from = min(section.entries + shown * 20, total)
                        rows.append(FieldNode(id: sid + "/more", name: "More entries", offset: from, length: max(0, min(more * 20, total - from)), kind: .bytes, value: "\(more) more"))
                    }
                    let length = max(0, min(section.count * 20, total - section.entries))
                    nodes.append(FieldNode(id: sid, name: "Objects \(section.first) to \(section.first + section.count - 1)", offset: section.entries, length: length, kind: .container,
                                           value: "\(section.count) \(section.count == 1 ? "entry" : "entries")", children: .list(rows)))
                }
                return nodes
            }))
        return (node, min(max(end, start + 4), total))
    }
}
