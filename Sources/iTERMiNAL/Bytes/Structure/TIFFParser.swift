import Foundation

/// A TIFF file taken apart: a header that says the byte order and where the first directory (IFD) is, then
/// directories of tags, each a number, a type, a count and either the value or where it is; directories
/// point to more (the next page, the Exif and GPS directories, sub-images), and the pixels sit in strips or
/// tiles the tags give the places of.
///
/// This is also how Exif is written, so cameras' RAW files (DNG, NEF, CR2, ARW and others) read here as well.
enum TIFFParser: FormatParser {
    static let identity = FormatIdentity(id: "tiff", name: "a TIFF image", detail: "Tagged Image File Format", hasParser: true)

    /// The most directories followed, and entries read in one directory.
    static let maxDirectories = 256
    static let maxEntries = 4096
    static let maxStrips = 512

    static func matches(head: [UInt8], length: Int64) -> Bool {
        guard head.count >= 8 else { return false }
        return (head[0] == 0x49 && head[1] == 0x49 && head[2] == 0x2A && head[3] == 0x00)
            || (head[0] == 0x4D && head[1] == 0x4D && head[2] == 0x00 && head[3] == 0x2A)
    }

    static func parse(_ source: ByteSource, context: ParseContext) -> ParseOutcome {
        var outcome = ParseOutcome()
        let total = source.count
        let head = ByteWindow(source: source, at: 0, count: 8)
        guard let order = head.slice(0, 2) else { return outcome }
        let endianness: Endianness = order.first == 0x49 ? .little : .big
        var list = FieldList(idPrefix: "tiff", window: head, endianness: endianness)
        var first: UInt64 = 0
        list.group("Header", at: 0, length: 8, kind: .magic, note: "The byte order of every number in the file, the number 42, and where the first directory is.") { f in
            f.text("Byte order", at: 0, length: 2, note: endianness == .little ? "II: little-endian, the low byte first, as Intel wrote it." : "MM: big-endian, the high byte first, as Motorola wrote it.")
            f.uint("Magic", at: 2, size: 2, kind: .magic, value: { $0 == 42 ? "42" : "\($0)" }, note: { _ in "Always 42." })
            first = f.uint("First directory offset", at: 4, size: 4, value: { FieldText.hexNumber($0, size: 4) }) ?? 0
            f.groupValue = endianness == .little ? "little-endian" : "big-endian"
        }
        var roots = list.nodes
        guard !list.truncated else {
            outcome.roots = roots
            outcome.problems = ["The file ends inside its header."]
            return outcome
        }

        let walker = Walker(source: source, endianness: endianness, total: total)
        var problems: [String] = []
        var pending: [(offset: Int64, title: String, kind: TIFFTags.Directory)] = [(Int64(first), "IFD 0", .image)]
        var visited: Set<Int64> = []
        var found: [FieldNode] = []
        var directories = 0
        var pages = 0
        var summaryFacts: Facts?
        var stopped = false
        while !pending.isEmpty {
            let next = pending.removeFirst()
            if context.isCancelled() { problems.append("Stopped before the end of the file."); stopped = true; break }
            if directories >= maxDirectories || found.count >= context.maxRecords {
                outcome.listingLimit = "The first \(directories) directories are listed; the rest of the file is in the dump."
                stopped = true
                break
            }
            guard next.offset >= 8, next.offset + 2 <= total else {
                problems.append("\(next.title) is said to be at \(FieldText.hexNumber(UInt64(max(next.offset, 0)), size: 1)), which is not inside the file after the header.")
                continue
            }
            guard visited.insert(next.offset).inserted else {
                problems.append("\(next.title) points back to a directory already listed, at \(FieldText.hexNumber(UInt64(next.offset), size: 1)).")
                continue
            }
            directories += 1
            let result = walker.directory(at: next.offset, title: next.title, kind: next.kind, id: "tiff/ifd\(directories)", maxEntries: maxEntries)
            found.append(result.node)
            found.append(contentsOf: result.extras)
            problems.append(contentsOf: result.problems)
            if next.kind == .image, next.title.hasPrefix("IFD ") { pages += 1 }
            if summaryFacts == nil, next.kind == .image { summaryFacts = result.facts }
            pending.append(contentsOf: result.subdirectories)
            if let following = result.next, following != 0 {
                pending.append((following, "IFD \(pages)", .image))
            }
        }
        roots.append(contentsOf: found.sorted { $0.offset < $1.offset })
        if !stopped, directories == 0 { problems.append("There is no directory to read.") }
        outcome.roots = roots
        outcome.problems = Array(problems.prefix(20))
        var summary = "TIFF, \(endianness == .little ? "little" : "big")-endian, \(pages) \(pages == 1 ? "image" : "images")"
        if let facts = summaryFacts {
            if let w = facts.width, let h = facts.height { summary += ", first \(w) × \(h)" }
            if let compression = facts.compression { summary += ", " + compression }
        }
        outcome.summary = summary
        return outcome
    }

    struct Facts {
        var width: UInt64?
        var height: UInt64?
        var compression: String?
    }

    struct DirectoryResult {
        var node: FieldNode
        var extras: [FieldNode] = []
        var subdirectories: [(offset: Int64, title: String, kind: TIFFTags.Directory)] = []
        var next: Int64?
        var problems: [String] = []
        var facts = Facts()
    }

    /// Reads directories out of a source, for a TIFF file or for the TIFF held in a JPEG's Exif segment.
    struct Walker {
        let source: ByteSource
        let endianness: Endianness
        let total: Int64
        /// Offsets in the file are counted from here: 0 for a TIFF file, the start of the byte order mark inside Exif.
        var base: Int64 = 0

        func read(_ at: Int64, _ count: Int) -> ByteWindow { ByteWindow(source: source, at: at, count: count) }

        func directory(at offset: Int64, title: String, kind: TIFFTags.Directory, id: String, maxEntries: Int) -> DirectoryResult {
            let start = base + offset
            let countWindow = read(start, 2)
            let declared = Int64(countWindow.u16(start, endianness) ?? 0)
            let shown = min(declared, Int64(maxEntries), max(0, (total - start - 2) / 12))
            let length = min(2 + shown * 12 + 4, max(0, total - start))
            let window = read(start, Int(min(2 + shown * 12 + 4, 2 + 12 * Int64(maxEntries) + 4)))
            var result = DirectoryResult(node: FieldNode(id: id, name: title, offset: start, length: length))
            var problems: [String] = []
            var children: [FieldNode] = []
            var strips: (offsets: [UInt64], counts: [UInt64])?
            var stripOffsets: [UInt64] = []
            var stripCounts: [UInt64] = []
            var tileMode = false
            var thumbnail: (offset: UInt64?, length: UInt64?) = (nil, nil)
            var previousTag: UInt64 = 0
            var outOfOrder = false

            var numberList = FieldList(idPrefix: id, window: window, endianness: endianness)
            numberList.uint("Number of entries", at: start, size: 2, value: { "\($0) \($0 == 1 ? "tag" : "tags")" })
            children.append(contentsOf: numberList.nodes)

            for index in 0..<shown {
                let e = start + 2 + index * 12
                guard let tag = window.u16(e, endianness).map({ UInt64($0) }), let typeRaw = window.u16(e + 2, endianness).map({ UInt64($0) }),
                      let count = window.u32(e + 4, endianness).map({ UInt64($0) }), let rawValue = window.u32(e + 8, endianness).map({ UInt64($0) }) else { break }
                if tag < previousTag { outOfOrder = true }
                previousTag = tag
                let name = TIFFTags.name(tag, in: kind) ?? "Tag " + FieldText.hexNumber(tag, size: 2)
                let typeInfo = TIFFTags.types[typeRaw]
                let unit = typeInfo?.size ?? 1
                let byteLength = count > UInt64(Int64.max / 16) ? Int64.max / 16 : Int64(count) * unit
                let inline = byteLength <= 4
                let valueAt = inline ? e + 8 : base + Int64(rawValue)
                let inFile = valueAt >= 0 && valueAt + byteLength <= total && (inline || Int64(rawValue) >= 8)
                var valueText: String?
                if typeInfo == nil {
                    valueText = "unknown type \(typeRaw)"
                } else if inFile {
                    valueText = describe(type: typeRaw, count: count, at: valueAt, tag: tag, kind: kind)
                } else {
                    valueText = "outside the file"
                    problems.append("\(name) in \(title) has its value at \(FieldText.hexNumber(UInt64(max(0, valueAt)), size: 1)) for \(FieldText.bytes(byteLength)), which is not inside the file.")
                }
                let entryID = id + "/e\(index + 1)-" + FieldList.slug(name)
                let entryOffset = e
                children.append(FieldNode(
                    id: entryID, name: name, offset: e, length: 12, kind: inFile || typeInfo != nil && inline ? .container : .problem, value: valueText,
                    note: inFile ? nil : "The value does not fit in the file.",
                    children: .deferred(DeferredChildren {
                        entryChildren(id: entryID, at: entryOffset, tag: tag, typeRaw: typeRaw, count: count, rawValue: rawValue, kind: kind, inline: inline, name: name, inFile: inFile)
                    })))
                // The value, if it is stored away from the entry.
                if !inline, inFile, byteLength > 0 {
                    result.extras.append(FieldNode(id: entryID + "/data", name: "Value of \(name)", offset: valueAt, length: byteLength,
                                                   kind: typeRaw == 2 ? .text : .bytes, value: valueText,
                                                   note: "Too big for the four bytes an entry has, so it is kept here and the entry says where."))
                }
                // Facts for the summary, the strips, and the directories this one points to.
                if kind == .image {
                    let first = inFile && count >= 1 ? readNumber(type: typeRaw, at: valueAt) : nil
                    switch tag {
                    case 0x100: result.facts.width = first
                    case 0x101: result.facts.height = first
                    case 0x103: result.facts.compression = first.map { TIFFTags.meaning(of: $0, tag: 0x103, in: .image) ?? "compression \($0)" }
                    case 0x111, 0x144:
                        tileMode = tag == 0x144
                        stripOffsets = numbers(type: typeRaw, count: count, at: valueAt, inFile: inFile)
                    case 0x117, 0x145:
                        stripCounts = numbers(type: typeRaw, count: count, at: valueAt, inFile: inFile)
                    case 0x201: thumbnail.offset = first
                    case 0x202: thumbnail.length = first
                    default: break
                    }
                }
                if let sub = TIFFTags.subdirectory(tag, in: kind), inFile {
                    for (n, pointer) in numbers(type: typeRaw, count: min(count, 16), at: valueAt, inFile: inFile).enumerated() {
                        result.subdirectories.append((Int64(pointer), count > 1 ? "\(sub.title) \(n + 1)" : sub.title, sub.kind))
                    }
                }
            }
            if !stripOffsets.isEmpty, stripOffsets.count == stripCounts.count {
                strips = (stripOffsets, stripCounts)
            }
            if let strips {
                for (n, pair) in zip(strips.offsets, strips.counts).enumerated() where n < TIFFParser.maxStrips {
                    let at = Int64(clamping: pair.0)
                    guard at >= 8, at < total else { problems.append("\(tileMode ? "Tile" : "Strip") \(n + 1) of \(title) is at \(FieldText.hexNumber(pair.0, size: 1)), outside the file."); continue }
                    let length = min(Int64(clamping: pair.1), total - at)
                    result.extras.append(FieldNode(id: id + "/strip\(n + 1)", name: "\(tileMode ? "Tile" : "Strip") \(n + 1) of \(title)", offset: at, length: length,
                                                   kind: Int64(clamping: pair.1) > total - at ? .problem : .bytes, value: FieldText.bytes(length),
                                                   note: "Pixels, compressed as the Compression tag says."))
                }
                if strips.offsets.count > TIFFParser.maxStrips {
                    problems.append("\(title) has \(strips.offsets.count) \(tileMode ? "tiles" : "strips"); the first \(TIFFParser.maxStrips) are listed.")
                }
            }
            if let offset = thumbnail.offset, let size = thumbnail.length, Int64(clamping: offset) >= 8, Int64(clamping: offset) < total {
                result.extras.append(FieldNode(id: id + "/jpeg", name: "Embedded JPEG of \(title)", offset: Int64(clamping: offset), length: min(Int64(clamping: size), total - Int64(clamping: offset)),
                                               kind: .bytes, value: FieldText.bytes(Int64(clamping: size)), note: "A whole JPEG file, usually a thumbnail."))
            }
            if outOfOrder { problems.append("The tags of \(title) are not in order, which the specification asks for.") }
            if declared > shown {
                problems.append("\(title) says it has \(declared) tags and \(shown) \(shown == 1 ? "fits" : "fit") in the file or in what is read.")
            }
            // What comes after the entries.
            let afterEntries = start + 2 + shown * 12
            var nextList = FieldList(idPrefix: id, window: window, endianness: endianness)
            if let next = nextList.uint("Next directory offset", at: afterEntries, size: 4, value: { $0 == 0 ? "0 · none" : FieldText.hexNumber($0, size: 4) },
                                        note: { $0 == 0 ? nil : "The next directory in the chain: usually the next page, or a thumbnail." }) {
                result.next = Int64(next)
            }
            children.append(contentsOf: nextList.nodes)
            result.node = FieldNode(id: id, name: title, offset: start, length: length, kind: problems.isEmpty ? .container : .container,
                                    value: "\(declared) \(declared == 1 ? "tag" : "tags")" + (result.facts.width.map { w in result.facts.height.map { h in " · \(w) × \(h)" } ?? "" } ?? ""),
                                    note: directoryNote(kind), children: .list(children))
            result.problems = problems
            return result
        }

        private func directoryNote(_ kind: TIFFTags.Directory) -> String? {
            switch kind {
            case .image: return "A list of tags about one image: its size, how its pixels are stored and compressed, and where they are."
            case .exif: return "Camera settings and capture details, as tags of their own."
            case .gps: return "Where the picture was taken."
            case .interoperability: return "Says which standard the file follows."
            }
        }

        func readNumber(type: UInt64, at: Int64) -> UInt64? {
            let w = read(at, 8)
            switch type {
            case 1, 7, 2: return w.u8(at).map { UInt64($0) }
            case 3: return w.u16(at, endianness).map { UInt64($0) }
            case 4, 13: return w.u32(at, endianness).map { UInt64($0) }
            case 16: return w.u64(at, endianness)
            default: return nil
            }
        }

        /// Up to 4,096 numbers of a SHORT, LONG or BYTE array.
        func numbers(type: UInt64, count: UInt64, at: Int64, inFile: Bool) -> [UInt64] {
            guard inFile, [1, 3, 4, 13].contains(type) else { return [] }
            let size = Int64(TIFFTags.types[type]?.size ?? 1)
            let n = Int(min(count, 4096))
            let w = read(at, n * Int(size))
            var out: [UInt64] = []
            for i in 0..<n {
                let position = at + Int64(i) * size
                guard let value = w.uint(position, size: Int(size), endianness) else { break }
                out.append(value)
            }
            return out
        }

        /// A value in words: a few of its numbers, or its text.
        func describe(type: UInt64, count: UInt64, at: Int64, tag: UInt64, kind: TIFFTags.Directory) -> String? {
            let unit = Int(TIFFTags.types[type]?.size ?? 1)
            let shown = Int(min(count, type == 2 ? 120 : (type == 7 || type == 1 ? 16 : 6)))
            let w = read(at, shown * unit)
            switch type {
            case 2:
                guard let slice = w.slice(at, shown) else { return nil }
                let text = slice.prefix { $0 != 0 }
                return FieldText.ascii(text, limit: 120) + (count > 120 ? " …" : "")
            case 1, 7:
                guard let slice = w.slice(at, shown) else { return nil }
                if type == 7, slice.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }), !slice.isEmpty { return FieldText.ascii(slice, limit: 16) }
                return FieldText.hex(slice, limit: 16) + (count > 16 ? " (\(count) bytes)" : "")
            case 3, 4, 8, 9, 13:
                var parts: [String] = []
                for i in 0..<shown {
                    let position = at + Int64(i) * Int64(unit)
                    guard let raw = w.uint(position, size: unit, endianness) else { break }
                    let signed = type == 8 ? Int64(Int16(truncatingIfNeeded: raw)) : (type == 9 ? Int64(Int32(truncatingIfNeeded: raw)) : Int64(raw))
                    parts.append("\(signed)")
                }
                var text = parts.joined(separator: ", ")
                if count > UInt64(shown) { text += " … (\(count) values)" }
                if count == 1, let raw = readNumber(type: type, at: at), let meaning = TIFFTags.meaning(of: raw, tag: tag, in: kind) { text += " · " + meaning }
                return text
            case 5, 10:
                var parts: [String] = []
                for i in 0..<shown {
                    let position = at + Int64(i) * 8
                    guard let top = w.u32(position, endianness), let bottom = w.u32(position + 4, endianness) else { break }
                    let t = type == 10 ? Double(Int32(bitPattern: top)) : Double(top)
                    let b = type == 10 ? Double(Int32(bitPattern: bottom)) : Double(bottom)
                    let ratio = type == 10 ? "\(Int32(bitPattern: top))/\(Int32(bitPattern: bottom))" : "\(top)/\(bottom)"
                    parts.append(bottom == 0 ? ratio : ratio + " = " + String(format: "%.6g", t / b))
                }
                return parts.joined(separator: ", ") + (count > UInt64(shown) ? " … (\(count) values)" : "")
            case 11:
                var parts: [String] = []
                for i in 0..<shown { if let raw = w.u32(at + Int64(i) * 4, endianness) { parts.append(String(format: "%.6g", Double(Float(bitPattern: raw)))) } }
                return parts.joined(separator: ", ")
            case 12:
                var parts: [String] = []
                for i in 0..<shown { if let raw = w.u64(at + Int64(i) * 8, endianness) { parts.append(String(format: "%.8g", Double(bitPattern: raw))) } }
                return parts.joined(separator: ", ")
            default:
                return nil
            }
        }

        private func entryChildren(id: String, at e: Int64, tag: UInt64, typeRaw: UInt64, count: UInt64, rawValue: UInt64, kind: TIFFTags.Directory, inline: Bool, name: String, inFile: Bool) -> [FieldNode] {
            var list = FieldList(idPrefix: id, window: read(e, 12), endianness: endianness)
            list.uint("Tag", at: e, size: 2, value: { FieldText.hexNumber($0, size: 2) + " · " + name })
            list.uint("Type", at: e + 2, size: 2, value: { raw in TIFFTags.types[raw].map { "\(raw) · \($0.name)" } ?? "\(raw) · unknown" },
                      note: { _ in "How to read the value: SHORT is a 16-bit number, LONG 32-bit, RATIONAL two LONGs as a fraction, ASCII text." })
            list.uint("Count", at: e + 4, size: 4, note: { _ in "How many values of that type." })
            if inline {
                list.bytes("Value", at: e + 8, length: 4, note: "Four bytes or fewer, so the value itself is here, at the front of these four bytes.")
            } else {
                list.uint("Value offset", at: e + 8, size: 4, value: { FieldText.hexNumber($0, size: 4) + (inFile ? "" : " · outside the file") },
                          note: { _ in "Too big for four bytes: this is where it is, counted from the start of the TIFF." })
            }
            return list.nodes
        }
    }
}
