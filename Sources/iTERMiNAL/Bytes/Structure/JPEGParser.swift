import Foundation

/// A JPEG file taken apart: a run of segments, each a marker (0xFF and a code) and, for most,
/// a two-byte length and that much data; and after each start-of-scan segment, the compressed
/// image itself, which has no length and runs until the next marker.
///
/// The tables and headers are small and are decoded when a segment is opened. The compressed
/// data is only read to find where it ends: inside it a 0xFF that is data is followed by 0x00,
/// and restart markers (RST0 to RST7) are part of it.
enum JPEGParser: FormatParser {
    static let identity = FormatIdentity(id: "jpeg", name: "a JPEG image", detail: "JPEG, from its start-of-image marker", hasParser: true)

    /// The most compressed data read, in all, to find where scans end.
    static let scanBudget: Int64 = 512 * 1024 * 1024

    static func matches(head: [UInt8], length: Int64) -> Bool {
        head.count >= 3 && head[0] == 0xFF && head[1] == 0xD8 && head[2] == 0xFF
    }

    // MARK: Markers

    /// A marker's short name and what it is.
    static func marker(_ code: UInt8) -> (name: String, title: String) {
        switch code {
        case 0xD8: return ("SOI", "Start of image")
        case 0xD9: return ("EOI", "End of image")
        case 0xDA: return ("SOS", "Start of scan")
        case 0xDB: return ("DQT", "Quantization tables")
        case 0xC4: return ("DHT", "Huffman tables")
        case 0xDD: return ("DRI", "Restart interval")
        case 0xFE: return ("COM", "Comment")
        case 0xC0: return ("SOF0", "Frame header, baseline")
        case 0xC1: return ("SOF1", "Frame header, extended sequential")
        case 0xC2: return ("SOF2", "Frame header, progressive")
        case 0xC3: return ("SOF3", "Frame header, lossless")
        case 0xC8: return ("JPG", "Reserved")
        case 0xCC: return ("DAC", "Arithmetic coding conditioning")
        case 0xC5...0xCF: return ("SOF\(code - 0xC0)", "Frame header")
        case 0xD0...0xD7: return ("RST\(code - 0xD0)", "Restart")
        case 0xDC: return ("DNL", "Number of lines")
        case 0xDE: return ("DHP", "Hierarchical progression")
        case 0xDF: return ("EXP", "Expand reference components")
        case 0xE0...0xEF: return ("APP\(code - 0xE0)", "Application data")
        case 0xF0...0xFD: return ("JPG\(code - 0xF0)", "Reserved")
        case 0x01: return ("TEM", "Temporary")
        default: return ("0x" + ByteRadix.hex.cell(code), "Reserved")
        }
    }

    /// Markers that are two bytes and nothing more.
    static func standsAlone(_ code: UInt8) -> Bool {
        code == 0xD8 || code == 0xD9 || code == 0x01 || (0xD0...0xD7).contains(code)
    }

    static func isFrameHeader(_ code: UInt8) -> Bool {
        (0xC0...0xCF).contains(code) && code != 0xC4 && code != 0xC8 && code != 0xCC
    }

    // MARK: The walk

    static func parse(_ source: ByteSource, context: ParseContext) -> ParseOutcome {
        var outcome = ParseOutcome()
        let total = source.count
        let scanner = SourceScanner(source: source, budget: scanBudget, isCancelled: context.isCancelled)
        var problems: [String] = []
        var position: Int64 = 0
        var index = 0
        var frame: String?
        var sawEOI = false
        var stopped = false

        func stop(_ name: String, _ note: String, _ problem: String) {
            stopped = true
            outcome.roots.append(FieldNode(id: "jpeg/stop", name: name, offset: position, length: total - position,
                                           kind: .problem, value: FieldText.bytes(total - position), note: note))
            problems.append(problem)
        }

        while position < total {
            if index >= context.maxRecords {
                stopped = true
                outcome.listingLimit = "The first \(context.maxRecords) segments are listed; the rest of the file is in the dump."
                outcome.roots.append(FieldNode(id: "jpeg/more", name: "More segments", offset: position, length: total - position,
                                               kind: .bytes, value: "not listed", note: "Listing stops after \(context.maxRecords) segments."))
                break
            }
            if context.isCancelled() {
                stopped = true
                problems.append("Stopped before the end of the file.")
                break
            }
            let at = FieldText.hexNumber(UInt64(position), size: 1)
            let head = ByteWindow(source: source, at: position, count: 4)
            guard head.u8(position) == 0xFF, let code = head.u8(position + 1) else {
                stop("Not a marker", "A segment starts with 0xFF and a marker code, and these bytes do not.",
                     "At \(at) there should be a marker and there is not: the file is damaged or cut.")
                break
            }
            if code == 0xFF {
                // Fill: any number of 0xFF may come before a marker.
                guard let found = scanner.first(from: position + 1, end: total, where: { $0 != 0xFF }) ?? (scanner.isExhausted ? nil : total) else {
                    stopped = true
                    problems.append("Stopped before the end of the file.")
                    break
                }
                let end = found
                outcome.roots.append(FieldNode(id: "jpeg/fill\(index + 1)", name: "Fill bytes", offset: position, length: end - 1 - position,
                                               kind: .padding, value: FieldText.bytes(end - 1 - position),
                                               note: "Any number of 0xFF bytes may come before a marker."))
                index += 1
                position = end - 1
                continue
            }
            if code == 0x00 {
                stop("Not a marker", "0xFF 0x00 is how a 0xFF byte of compressed data is written; it is not a marker, and no scan is open here.",
                     "At \(at) there is compressed data where a marker should be.")
                break
            }
            let names = marker(code)
            let id = "jpeg/seg\(index + 1)-\(names.name)"
            index += 1
            let start = position

            if standsAlone(code) {
                outcome.roots.append(FieldNode(id: id, name: names.name, offset: start, length: 2, kind: .magic,
                                               value: "FF \(ByteRadix.hex.cell(code)) · \(names.title)", note: standaloneNote(code)))
                position += 2
                if code == 0xD9 {
                    sawEOI = true
                    break
                }
                continue
            }

            guard let declared = head.u16(position + 2, .big).map({ Int64($0) }) else {
                stop("Cut off", "The marker \(names.name) is followed by a two-byte length, and the file ends before it.",
                     "The file ends inside the header of \(names.name), at \(at).")
                break
            }
            guard declared >= 2 else {
                stop(names.name, "The length of a segment counts its own two bytes, so it is at least 2; this one says \(declared).",
                     "\(names.name) at \(at) has an impossible length of \(declared).")
                break
            }
            let size = 2 + declared
            guard size <= total - position else {
                let held = total - position
                stopped = true
                let note = "The segment says it is \(FieldText.bytes(declared)) long after its marker, but the file ends after \(FieldText.bytes(held - 2))."
                outcome.roots.append(FieldNode(id: id, name: names.name, offset: start, length: held, kind: .problem, value: "cut off", note: note))
                problems.append("\(names.name) at \(at) is cut off: \(note)")
                break
            }

            let window = ByteWindow(source: source, at: start, count: Int(size))
            let short = segmentSummary(code, window: window, start: start, size: size)
            if isFrameHeader(code), frame == nil { frame = short }
            outcome.roots.append(FieldNode(
                id: id, name: names.name, offset: start, length: size, kind: .container,
                value: [names.title, short, FieldText.bytes(size)].compactMap { $0 }.joined(separator: " · "),
                note: segmentNote(code),
                children: .deferred(DeferredChildren {
                    segmentChildren(id: id, source: source, code: code, start: start, size: size)
                })))
            position += size

            if code == 0xDA {
                // The compressed image: to the next marker that is not a restart.
                let scan = scanData(scanner, from: position, total: total)
                let dataEnd = scan.end
                if dataEnd > position {
                    var words = FieldText.bytes(dataEnd - position)
                    if scan.restarts > 0 { words += " · \(scan.restarts) restart \(scan.restarts == 1 ? "marker" : "markers")" }
                    var note = "The compressed image for this scan. It has no length: it runs to the next marker. A 0xFF that is data is written 0xFF 0x00, and restart markers are part of it."
                    if !scan.complete { note += " It was not read to its end, so what follows it is not listed." }
                    outcome.roots.append(FieldNode(id: "jpeg/scan\(index + 1)", name: "Scan data", offset: position, length: dataEnd - position,
                                                   kind: .bytes, value: words, note: note))
                    index += 1
                }
                position = dataEnd
                if !scan.complete {
                    stopped = true
                    if position < total {
                        outcome.listingLimit = "The compressed image was read as far as \(FieldText.hexNumber(UInt64(position), size: 1)); the rest of the file is in the dump."
                    }
                    break
                }
            }
        }

        if sawEOI, position < total {
            let rest = total - position
            let preview = ByteWindow(source: source, at: position, count: 16)
            outcome.roots.append(FieldNode(
                id: "jpeg/trailer", name: "Data after EOI", offset: position, length: rest, kind: .bytes,
                value: FieldText.hex(preview.bytes[...]),
                note: "Readers stop at the end-of-image marker. Some files carry more here: a second image, a thumbnail, a depth map, an appended archive."))
        } else if !sawEOI, !stopped {
            problems.append("There is no end-of-image marker, so the file may be cut short.")
        }

        outcome.problems = Array(problems.prefix(20))
        let segments = outcome.roots.filter { $0.id.hasPrefix("jpeg/seg") }.count
        outcome.summary = "JPEG image" + (frame.map { ", " + $0 } ?? "") + ", \(segments) \(segments == 1 ? "segment" : "segments")"
        return outcome
    }

    /// Where the compressed data starting at `from` ends: at the next 0xFF that is followed by
    /// neither 0x00, a restart code nor another 0xFF. `complete` is false if the budget ran out.
    private static func scanData(_ scanner: SourceScanner, from: Int64, total: Int64) -> (end: Int64, restarts: Int, complete: Bool) {
        var at = from
        var restarts = 0
        while at < total {
            guard let value = scanner.byte(at: at) else { return (at, restarts, false) }
            guard value == 0xFF else {
                at += 1
                continue
            }
            guard at + 1 < total else { return (total, restarts, true) }
            guard let next = scanner.byte(at: at + 1) else { return (at, restarts, false) }
            switch next {
            case 0x00:
                at += 2
            case 0xD0...0xD7:
                restarts += 1
                at += 2
            case 0xFF:
                at += 1
            default:
                return (at, restarts, true)
            }
        }
        return (total, restarts, true)
    }

    // MARK: Words for a segment

    private static func standaloneNote(_ code: UInt8) -> String {
        switch code {
        case 0xD8: return "Every JPEG begins with these two bytes."
        case 0xD9: return "The image ends here. Readers ignore anything after it."
        case 0xD0...0xD7: return "A restart marker outside compressed data, where it does not belong."
        default: return "A marker with no data of its own."
        }
    }

    private static func segmentNote(_ code: UInt8) -> String? {
        switch code {
        case 0xDB: return "The numbers each block of the image was divided by before it was stored: bigger numbers, smaller file, less detail."
        case 0xC4: return "The codes the compressed data is written in: which bit patterns stand for which values."
        case 0xDA: return "Says which colour components the compressed data that follows holds, and which tables it uses."
        case 0xDD: return "How many blocks come between restart markers, which let a reader pick up again after damaged data."
        case 0xFE: return "Text for people; readers ignore it."
        case 0xE0...0xEF: return "Data for one program or standard, named by the text it begins with. A reader that does not know it skips it."
        default:
            return isFrameHeader(code) ? "The size of the image, how many bits a sample has, and its colour components." : nil
        }
    }

    /// The text an application segment begins with, up to its NUL.
    private static func identifier(_ window: ByteWindow, start: Int64, size: Int64) -> (text: String, length: Int64)? {
        let data = start + 4
        let limit = min(size - 4, 40)
        guard limit > 0 else { return nil }
        var length: Int64 = 0
        while length < limit, let byte = window.u8(data + length), byte != 0 {
            guard byte >= 0x20, byte < 0x7F else { return nil }
            length += 1
        }
        guard length > 0, length < limit, let slice = window.slice(data, Int(length)) else { return nil }
        return (String(decoding: slice, as: UTF8.self), length)
    }

    /// A few words about a segment for its line in the tree.
    private static func segmentSummary(_ code: UInt8, window: ByteWindow, start: Int64, size: Int64) -> String? {
        let data = start + 4
        switch code {
        case 0xE0...0xEF:
            guard let name = identifier(window, start: start, size: size) else { return nil }
            if name.text.hasPrefix("http://ns.adobe.com/xap/") { return "XMP" }
            return name.text
        case 0xDD:
            return window.u16(data, .big).map { "every \($0) blocks" }
        case 0xDB, 0xC4:
            return nil
        case 0xDA:
            return window.u8(data).map { "\($0) \($0 == 1 ? "component" : "components")" }
        case 0xFE:
            return window.slice(data, Int(min(size - 4, 40))).map { FieldText.ascii($0, limit: 40) }
        default:
            guard isFrameHeader(code), let precision = window.u8(data), let height = window.u16(data + 1, .big),
                  let width = window.u16(data + 3, .big), let components = window.u8(data + 5) else { return nil }
            let kind: String
            switch code {
            case 0xC0: kind = "baseline"
            case 0xC1: kind = "extended sequential"
            case 0xC2: kind = "progressive"
            case 0xC3: kind = "lossless"
            default: kind = marker(code).name
            }
            let colour = components == 1 ? "greyscale" : (components == 3 ? "3 components" : "\(components) components")
            return "\(width) × \(height), \(precision)-bit \(kind), \(colour)"
        }
    }

    // MARK: Inside a segment

    private static func segmentChildren(id: String, source: ByteSource, code: UInt8, start: Int64, size: Int64) -> [FieldNode] {
        let window = ByteWindow(source: source, at: start, count: Int(size))
        var list = FieldList(idPrefix: id, window: window, endianness: .big)
        let names = marker(code)
        list.uint("Marker", at: start, size: 2, kind: .magic, value: { _ in "FF \(ByteRadix.hex.cell(code)) · \(names.name)" },
                  note: { _ in names.title + "." })
        list.uint("Length", at: start + 2, size: 2, value: { FieldText.bytes(Int64($0)) },
                  note: { _ in "Counts these two bytes and the data, but not the marker." })
        let data = start + 4
        let end = start + size
        let length = end - data
        guard length > 0 else { return list.nodes }

        switch code {
        case 0xE0...0xEF:
            application(&list, code: code, window: window, start: start, size: size)
        case 0xDB:
            quantization(&list, window: window, from: data, end: end)
        case 0xC4:
            huffman(&list, window: window, from: data, end: end)
        case 0xDA:
            scanHeader(&list, window: window, from: data, end: end)
        case 0xDD:
            list.uint("Restart interval", at: data, size: 2, value: { $0 == 0 ? "0 · no restarts" : "\($0) blocks" })
            rest(&list, from: data + 2, end: end)
        case 0xFE:
            list.text("Comment", at: data, length: length)
        default:
            if isFrameHeader(code) {
                frameHeader(&list, window: window, from: data, end: end)
            } else {
                list.bytes("Data", at: data, length: length)
            }
        }
        return list.nodes
    }

    /// What is left of a segment after the fields that were expected.
    private static func rest(_ list: inout FieldList, from: Int64, end: Int64, name: String = "Extra bytes") {
        guard from < end else { return }
        list.bytes(name, at: from, length: end - from, kind: name == "Extra bytes" ? .padding : .bytes,
                   note: name == "Extra bytes" ? "More than this kind of segment has a use for." : nil)
    }

    private static func frameHeader(_ list: inout FieldList, window: ByteWindow, from data: Int64, end: Int64) {
        list.uint("Sample precision", at: data, size: 1, value: { "\($0) bits" })
        list.uint("Height", at: data + 1, size: 2, value: { $0 == 0 ? "0 · given later, by a DNL segment" : "\($0) pixels" })
        list.uint("Width", at: data + 3, size: 2, value: { "\($0) pixels" })
        let count = Int64(list.uint("Components", at: data + 5, size: 1, value: { raw in
            switch raw {
            case 1: return "1 · greyscale"
            case 3: return "3 · usually Y, Cb, Cr"
            case 4: return "4 · usually CMYK"
            default: return "\(raw)"
            }
        }) ?? 0)
        var at = data + 6
        for number in 0..<count where at + 3 <= end {
            list.group("Component \(number + 1)", at: at, length: 3) { f in
                let component = f.uint("Identifier", at: at, size: 1) ?? 0
                let h = f.bits("Horizontal sampling", at: at + 1, size: 1, shift: 4, width: 4) ?? 0
                let v = f.bits("Vertical sampling", at: at + 1, size: 1, shift: 0, width: 4) ?? 0
                let table = f.uint("Quantization table", at: at + 2, size: 1) ?? 0
                f.groupValue = "id \(component), sampling \(h)×\(v), table \(table)"
                f.groupNote = "Sampling says how many samples this component has for each block of the image: colour is often stored at half the detail of brightness."
            }
            at += 3
        }
        rest(&list, from: at, end: end)
    }

    private static func quantization(_ list: inout FieldList, window: ByteWindow, from data: Int64, end: Int64) {
        var at = data
        var number = 0
        while at < end, number < 16, let info = window.u8(at) {
            let wide = info >> 4 != 0
            let size: Int64 = 1 + (wide ? 128 : 64)
            guard at + size <= end else { break }
            let start = at
            list.group("Table \(info & 0x0F)", at: start, length: size) { f in
                f.bits("Precision", at: start, size: 1, shift: 4, width: 4, value: { $0 == 0 ? "0 · 8-bit values" : "\($0) · 16-bit values" })
                f.bits("Table number", at: start, size: 1, shift: 0, width: 4)
                f.bytes("Values", at: start + 1, length: size - 1,
                        note: "64 divisors, in zig-zag order from the coarsest detail of a block to the finest.")
                f.groupValue = "64 \(wide ? "16-bit" : "8-bit") values"
            }
            at += size
            number += 1
        }
        rest(&list, from: at, end: end)
    }

    private static func huffman(_ list: inout FieldList, window: ByteWindow, from data: Int64, end: Int64) {
        var at = data
        var number = 0
        while at + 17 <= end, number < 32, let info = window.u8(at), let counts = window.slice(at + 1, 16) {
            let symbols = counts.reduce(Int64(0)) { $0 + Int64($1) }
            let size = 17 + symbols
            guard at + size <= end else { break }
            let start = at
            let kind = info >> 4 == 0 ? "DC" : "AC"
            list.group("\(kind) table \(info & 0x0F)", at: start, length: size) { f in
                f.bits("Class", at: start, size: 1, shift: 4, width: 4,
                       value: { $0 == 0 ? "0 · DC (a block's average)" : "\($0) · AC (a block's detail)" })
                f.bits("Table number", at: start, size: 1, shift: 0, width: 4)
                f.bytes("Codes of each length", at: start + 1, length: 16, note: "How many codes are 1 bit long, 2 bits long, and so on to 16.")
                if symbols > 0 {
                    f.bytes("Symbols", at: start + 17, length: symbols, note: "The values the codes stand for, shortest code first.")
                }
                f.groupValue = "\(symbols) \(symbols == 1 ? "code" : "codes")"
            }
            at += size
            number += 1
        }
        rest(&list, from: at, end: end)
    }

    private static func scanHeader(_ list: inout FieldList, window: ByteWindow, from data: Int64, end: Int64) {
        let count = Int64(list.uint("Components in scan", at: data, size: 1) ?? 0)
        var at = data + 1
        for number in 0..<count where at + 2 <= end {
            list.group("Component \(number + 1)", at: at, length: 2) { f in
                let component = f.uint("Identifier", at: at, size: 1) ?? 0
                let dc = f.bits("DC table", at: at + 1, size: 1, shift: 4, width: 4) ?? 0
                let ac = f.bits("AC table", at: at + 1, size: 1, shift: 0, width: 4) ?? 0
                f.groupValue = "id \(component), DC table \(dc), AC table \(ac)"
            }
            at += 2
        }
        guard at + 3 <= end else {
            rest(&list, from: at, end: end)
            return
        }
        list.uint("Spectral selection start", at: at, size: 1, note: { _ in "The first coefficient of each block in this scan. 0 to 63 is a whole block; a progressive image sends parts in turn." })
        list.uint("Spectral selection end", at: at + 1, size: 1)
        list.bits("Successive approximation high", at: at + 2, size: 1, shift: 4, width: 4)
        list.bits("Successive approximation low", at: at + 2, size: 1, shift: 0, width: 4)
        rest(&list, from: at + 3, end: end)
    }

    // MARK: Application segments

    private static func application(_ list: inout FieldList, code: UInt8, window: ByteWindow, start: Int64, size: Int64) {
        let data = start + 4
        let end = start + size
        guard let name = identifier(window, start: start, size: size) else {
            list.bytes("Data", at: data, length: end - data)
            return
        }
        list.text("Identifier", at: data, length: name.length, note: "Says whose data this is.")
        var at = data + name.length
        if code == 0xEE, name.text == "Adobe" {
            // No terminator: the two-byte version follows the five letters, and its high byte is 0.
            list.uint("Version", at: at, size: 2)
            list.uint("Flags 0", at: at + 2, size: 2, kind: .flags, value: { FieldText.hexNumber($0, size: 2) })
            list.uint("Flags 1", at: at + 4, size: 2, kind: .flags, value: { FieldText.hexNumber($0, size: 2) })
            list.uint("Colour transform", at: at + 6, size: 1, value: { raw in
                switch raw {
                case 0: return "0 · none (RGB or CMYK as stored)"
                case 1: return "1 · YCbCr"
                case 2: return "2 · YCCK"
                default: return "\(raw)"
                }
            })
            rest(&list, from: at + 7, end: end)
            return
        }
        list.bytes("Terminator", at: at, length: 1, kind: .padding)
        at += 1

        switch (code, name.text) {
        case (0xE0, "JFIF"):
            list.uint("Version major", at: at, size: 1)
            list.uint("Version minor", at: at + 1, size: 1)
            let unit = window.u8(at + 2)
            list.uint("Density unit", at: at + 2, size: 1, value: { raw in
                switch raw {
                case 0: return "0 · none (only the shape of a pixel)"
                case 1: return "1 · dots per inch"
                case 2: return "2 · dots per centimetre"
                default: return "\(raw)"
                }
            })
            let suffix = unit == 1 ? " dpi" : (unit == 2 ? " per cm" : "")
            list.uint("Horizontal density", at: at + 3, size: 2, value: { "\($0)\(suffix)" })
            list.uint("Vertical density", at: at + 5, size: 2, value: { "\($0)\(suffix)" })
            list.uint("Thumbnail width", at: at + 7, size: 1, value: { "\($0) pixels" })
            list.uint("Thumbnail height", at: at + 8, size: 1, value: { "\($0) pixels" })
            rest(&list, from: at + 9, end: end, name: "Thumbnail")
        case (0xE1, "Exif"):
            if window.u8(at) == 0 {
                list.bytes("Padding", at: at, length: 1, kind: .padding)
                at += 1
            }
            exif(&list, window: window, tiff: at, end: end)
        case (0xE2, "ICC_PROFILE"):
            list.uint("Part", at: at, size: 1, note: { _ in "A colour profile too big for one segment is split across several, numbered from 1." })
            list.uint("Of", at: at + 1, size: 1)
            rest(&list, from: at + 2, end: end, name: "Profile data")
        default:
            if name.text.hasPrefix("http://ns.adobe.com/xap/") {
                list.text("XMP packet", at: at, length: end - at, note: "Metadata as XML text.")
            } else {
                rest(&list, from: at, end: end, name: "Data")
            }
        }
    }

    private static let exifTags: [UInt64: String] = [
        0x0100: "ImageWidth", 0x0101: "ImageLength", 0x0102: "BitsPerSample", 0x0103: "Compression",
        0x0106: "PhotometricInterpretation", 0x010E: "ImageDescription", 0x010F: "Make", 0x0110: "Model",
        0x0111: "StripOffsets", 0x0112: "Orientation", 0x0115: "SamplesPerPixel", 0x0116: "RowsPerStrip",
        0x0117: "StripByteCounts", 0x011A: "XResolution", 0x011B: "YResolution", 0x0128: "ResolutionUnit",
        0x0131: "Software", 0x0132: "DateTime", 0x013B: "Artist", 0x0201: "JPEGInterchangeFormat",
        0x0202: "JPEGInterchangeFormatLength", 0x0213: "YCbCrPositioning", 0x8298: "Copyright",
        0x8769: "ExifIFDPointer", 0x8825: "GPSInfoIFDPointer"
    ]

    private static let exifTypes: [UInt64: (name: String, size: Int64)] = [
        1: ("BYTE", 1), 2: ("ASCII", 1), 3: ("SHORT", 2), 4: ("LONG", 4), 5: ("RATIONAL", 8),
        6: ("SBYTE", 1), 7: ("UNDEFINED", 1), 8: ("SSHORT", 2), 9: ("SLONG", 4), 10: ("SRATIONAL", 8),
        11: ("FLOAT", 4), 12: ("DOUBLE", 8)
    ]

    /// Exif is a small TIFF file inside the segment: a byte order, the number 42, and where
    /// the first directory of tags is, counted from the start of that TIFF.
    private static func exif(_ list: inout FieldList, window: ByteWindow, tiff: Int64, end: Int64) {
        guard let order = window.slice(tiff, 2).map({ Array($0) }) else {
            rest(&list, from: tiff, end: end, name: "Data")
            return
        }
        let endianness: Endianness
        switch order {
        case [0x49, 0x49]: endianness = .little
        case [0x4D, 0x4D]: endianness = .big
        default:
            list.problem("Exif data begins with a byte order of II or MM, and this does not.", at: tiff, length: 2, name: "Byte order")
            rest(&list, from: tiff + 2, end: end, name: "Data")
            return
        }
        list.text("Byte order", at: tiff, length: 2,
                  note: endianness == .little ? "II: little-endian, as Intel wrote it. Every number after this is the low byte first."
                                              : "MM: big-endian, as Motorola wrote it. Every number after this is the high byte first.")
        list.endianness = endianness
        defer { list.endianness = .big }
        list.uint("TIFF magic", at: tiff + 2, size: 2, kind: .magic, note: { $0 == 42 ? "Always 42." : "This should be 42." })
        guard let first = list.uint("First directory offset", at: tiff + 4, size: 4,
                                    note: { _ in "Counted from the byte order mark, not from the start of the file." }) else { return }
        let directory = tiff + Int64(first)
        guard first >= 8, directory + 2 <= end, let count = window.u16(directory, endianness) else {
            list.problem("The first directory is said to be \(first) bytes in, which is not inside this segment after the header.", at: tiff + 4, length: 4)
            rest(&list, from: tiff + 8, end: end, name: "Data")
            return
        }
        if directory > tiff + 8 {
            list.bytes("Bytes before the directory", at: tiff + 8, length: directory - (tiff + 8))
        }
        let shown = min(Int64(count), 64, (end - directory - 2) / 12)
        let size = 2 + shown * 12
        list.group("Directory 0", at: directory, length: size, value: "\(count) \(count == 1 ? "tag" : "tags")",
                   note: "The tags of the main image. Directories of camera settings and of GPS are pointed to from here and are not opened.") { f in
            f.uint("Number of tags", at: directory, size: 2)
            for entry in 0..<shown {
                let at = directory + 2 + entry * 12
                let tag = window.u16(at, endianness).map { UInt64($0) } ?? 0
                let type = window.u16(at + 2, endianness).map { UInt64($0) } ?? 0
                let values = window.u32(at + 4, endianness).map { Int64($0) } ?? 0
                let name = exifTags[tag] ?? "Tag " + FieldText.hexNumber(tag, size: 2)
                let kind = exifTypes[type]
                let inline = kind.map { $0.size * values <= 4 } ?? false
                f.group(name, at: at, length: 12) { e in
                    e.uint("Tag", at: at, size: 2, value: { FieldText.hexNumber($0, size: 2) + (exifTags[$0].map { " · " + $0 } ?? "") })
                    e.uint("Type", at: at + 2, size: 2, value: { raw in exifTypes[raw].map { "\(raw) · \($0.name)" } ?? "\(raw) · unknown" })
                    e.uint("Count", at: at + 4, size: 4)
                    let raw = window.u32(at + 8, endianness).map { UInt64($0) }
                    if inline {
                        e.bytes("Value", at: at + 8, length: 4, note: "Four bytes or fewer, so the value itself is here, at the front of these four bytes.")
                    } else {
                        e.uint("Value offset", at: at + 8, size: 4,
                               note: { _ in "Too big for four bytes: this is where it is, counted from the byte order mark." })
                    }
                    e.groupValue = exifValue(window: window, tiff: tiff, end: end, entry: at, type: type, count: values,
                                             inline: inline, raw: raw, endianness: endianness)
                }
            }
        }
        var after = directory + size
        if shown == Int64(count), after + 4 <= end {
            list.uint("Next directory offset", at: after, size: 4, value: { $0 == 0 ? "0 · none" : "\($0)" },
                      note: { $0 == 0 ? nil : "Often the directory of a thumbnail." })
            after += 4
        }
        rest(&list, from: after, end: end, name: "Values and other directories")
    }

    /// A tag's value in words, where it is short enough to say.
    private static func exifValue(window: ByteWindow, tiff: Int64, end: Int64, entry: Int64, type: UInt64, count: Int64,
                                  inline: Bool, raw: UInt64?, endianness: Endianness) -> String? {
        guard let raw else { return nil }
        let at = inline ? entry + 8 : tiff + Int64(raw)
        switch type {
        case 2:
            guard count > 0, count <= 200, at >= tiff, at + count <= end, let slice = window.slice(at, Int(count)) else { return nil }
            let text = slice.last == 0 ? slice.dropLast() : slice
            return FieldText.ascii(text, limit: 60)
        case 3 where count == 1:
            return window.u16(at, endianness).map { "\($0)" }
        case 4 where count == 1:
            return "\(raw)"
        case 5 where count == 1:
            guard at >= tiff, at + 8 <= end, let top = window.u32(at, endianness), let bottom = window.u32(at + 4, endianness) else { return nil }
            return "\(top)/\(bottom)"
        default:
            return nil
        }
    }
}
