import Foundation

/// An MP4, M4A, MOV or other ISO base media file taken apart: a tree of boxes (QuickTime
/// calls them atoms), each a size, a four-letter type and its contents, which for many boxes
/// are more boxes.
///
/// The top level is listed when the file is opened; what is inside a box is made when it is
/// opened. The movie data (`mdat`) is a size and nothing more, however many gigabytes it is.
enum MP4Parser: FormatParser {
    static let identity = FormatIdentity(id: "mp4", name: "an MP4 or QuickTime video", detail: "ISO base media file format", hasParser: true)
    /// The same boxes hold HEIC and AVIF images, JPEG 2000 images and the JPEG XL container.
    static let alsoParses = ["heic", "avif", "jp2", "jxl"]

    /// Boxes whose contents are more boxes.
    static let containers: Set<String> = [
        "moov", "trak", "mdia", "minf", "dinf", "stbl", "edts", "udta", "moof", "traf", "mvex",
        "tref", "sinf", "schi", "ipro", "mfra", "iprp", "ipco", "grpl", "jp2h", "strk", "strd", "meco", "trgr", "ilst",
        "\u{A9}nam", "\u{A9}ART", "\u{A9}alb", "\u{A9}day", "\u{A9}too", "\u{A9}gen", "\u{A9}cmt", "\u{A9}wrt", "\u{A9}grp",
        "aART", "trkn", "disk", "covr", "cpil", "tmpo", "desc", "ldes"
    ]

    /// Boxes whose contents are a version, flags, and then more boxes.
    static let fullContainers: Set<String> = ["meta"]

    /// What a box is, in words.
    static let titles: [String: String] = [
        "ftyp": "File type and compatible brands", "moov": "Movie: all of the metadata", "mvhd": "Movie header",
        "trak": "Track", "tkhd": "Track header", "edts": "Edit list container", "elst": "Edit list",
        "mdia": "Media", "mdhd": "Media header", "hdlr": "Handler: what kind of track", "minf": "Media information",
        "vmhd": "Video media header", "smhd": "Sound media header", "hmhd": "Hint media header", "nmhd": "Null media header",
        "dinf": "Data information", "dref": "Data references", "stbl": "Sample table", "stsd": "Sample descriptions: the codec",
        "stts": "Decoding times", "ctts": "Composition time offsets", "stss": "Sync samples (key frames)",
        "stsc": "Samples to chunks", "stsz": "Sample sizes", "stz2": "Compact sample sizes", "stco": "Chunk offsets, 32-bit",
        "co64": "Chunk offsets, 64-bit", "mdat": "Media data: the audio and video itself, or an image's coded data", "free": "Free space",
        "skip": "Free space", "wide": "Room for a 64-bit size", "udta": "User data", "meta": "Metadata",
        "ilst": "iTunes-style tags", "uuid": "Extension box", "moof": "Movie fragment", "mfhd": "Movie fragment header",
        "traf": "Track fragment", "tfhd": "Track fragment header", "tfdt": "Track fragment decode time", "trun": "Track run",
        "mvex": "Movie extends: the file is fragmented", "trex": "Track extends", "mehd": "Movie extends header",
        "sidx": "Segment index", "styp": "Segment type", "mfra": "Fragment random access", "tfra": "Track fragment random access",
        "mfro": "Fragment random access offset", "iods": "Object descriptor", "esds": "Elementary stream descriptor",
        "avcC": "H.264 configuration", "hvcC": "H.265 configuration", "av1C": "AV1 configuration", "btrt": "Bit rate",
        "pasp": "Pixel aspect ratio", "colr": "Colour information", "sgpd": "Sample group description", "sbgp": "Sample to group",
        "saiz": "Auxiliary sample sizes", "saio": "Auxiliary sample offsets", "pssh": "Protection system header",
        "sinf": "Protection scheme information", "tref": "Track references", "chpl": "Chapter list", "name": "Name",
        "gmhd": "Base media header", "sdtp": "Sample dependency", "ipro": "Item protection", "pitm": "Primary item",
        "iinf": "Item information", "iloc": "Item location", "iref": "Item references", "iprp": "Item properties",
        "idat": "Item data", "xml ": "XML", "bxml": "Binary XML", "clap": "Clean aperture", "ssix": "Subsegment index",
        "prft": "Producer reference time", "emsg": "Event message", "cslg": "Composition to decode", "stsh": "Shadow sync",
        "stdp": "Degradation priority", "padb": "Padding bits", "subs": "Sub-sample information", "url ": "Data entry URL",
        "urn ": "Data entry URN", "mp4a": "AAC audio sample entry", "avc1": "H.264 video sample entry",
        "hvc1": "H.265 video sample entry", "hev1": "H.265 video sample entry", "mp4v": "MPEG-4 video sample entry",
        "av01": "AV1 video sample entry", "vp09": "VP9 video sample entry",
        "ispe": "Image size", "pixi": "Bits per channel", "irot": "Rotation", "imir": "Mirroring", "ipma": "Property associations",
        "ipco": "Item properties", "grpl": "Entity groups", "auxC": "Auxiliary image type", "clli": "Content light level", "mdcv": "Mastering display",
        "infe": "Item information entry", "thmb": "Thumbnail of", "dimg": "Derived from",
        "cdsc": "Describes", "auxl": "Auxiliary of",
        "jP  ": "JPEG 2000 signature", "jp2h": "JP2 header", "ihdr": "Image header", "jp2c": "JPEG 2000 codestream", "bpcc": "Bits per component", "pclr": "Palette",
        "cmap": "Component mapping", "cdef": "Channel definition", "res ": "Resolution", "resc": "Capture resolution", "resd": "Display resolution",
        "jp2 ": "JPEG 2000 file", "JXL ": "JPEG XL signature", "jxlc": "JPEG XL codestream", "jxlp": "JPEG XL codestream part", "jxll": "JPEG XL level",
        "jbrd": "JPEG reconstruction data", "Exif": "Exif metadata", "brob": "Brotli-compressed box"
    ]

    static func matches(head: [UInt8], length: Int64) -> Bool {
        guard head.count >= 8 else { return false }
        let type = String(decoding: head[4..<8], as: UTF8.self)
        if head.count >= 12, head[0..<4] == [0, 0, 0, 12], type == "jP  " || type == "JXL " { return true }
        return ["ftyp", "moov", "mdat", "wide", "free", "skip", "styp", "sidx", "moof"].contains(type) && boxSize(head: head) != nil
    }

    /// A four-character code as text; 0xA9, which iTunes tags begin with, is a copyright sign.
    static func fourCC<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        String(bytes.map { $0 == 0xA9 ? Character("\u{A9}") : Character(UnicodeScalar(HexGeometry.textByte($0))) })
    }

    private static func boxSize(head: [UInt8]) -> Int64? {
        let window = ByteWindow(base: 0, bytes: head)
        guard let size = window.u32(0, .big) else { return nil }
        return size == 1 || size == 0 || size >= 8 ? Int64(size) : nil
    }

    static func parse(_ source: ByteSource, context: ParseContext) -> ParseOutcome {
        var outcome = ParseOutcome()
        let total = source.count
        var problems: [String] = []
        var brand: String?
        var movie: String?
        var count = 0

        let roots = boxes(source: source, idPrefix: "mp4", from: 0, end: total, depth: 0, context: context,
                          problems: &problems, listingLimit: &outcome.listingLimit, count: &count)
        outcome.roots = roots
        for root in roots {
            if root.name == "ftyp", brand == nil {
                let window = ByteWindow(source: source, at: root.offset, count: 16)
                if let text = window.slice(root.offset + 8, 4) { brand = fourCC(text) }
            }
            if root.name == "moov", movie == nil { movie = movieSummary(source: source, moov: root) }
        }
        let imageKind = Self.imageKind(roots: roots, brand: brand)
        if imageKind == nil, !roots.contains(where: { $0.name == "moov" }), outcome.listingLimit == nil, !context.isCancelled() {
            problems.append("There is no moov box, so a player has no index to the media: the file is cut short, or its moov is still being written.")
        }
        outcome.problems = Array(problems.prefix(20))
        if let imageKind {
            var summary = imageKind.name
            if let size = Self.imageSize(roots: roots) { summary += ", " + size }
            if let brand, imageKind.id != "jxl" { summary += ", brand \"\(brand)\"" }
            summary += ", \(count) \(count == 1 ? "box" : "boxes") listed"
            outcome.summary = summary
            return outcome
        }
        var summary = "MP4 / QuickTime"
        if let brand { summary += ", brand \"\(brand)\"" }
        if let movie { summary += ", " + movie }
        summary += ", \(count) \(count == 1 ? "box" : "boxes") listed"
        outcome.summary = summary
        return outcome
    }

    // MARK: Walking boxes

    /// The boxes from `from` to `end`, each with its contents made when it is opened.
    private static func boxes(source: ByteSource, idPrefix: String, from: Int64, end: Int64, depth: Int, context: ParseContext,
                              problems: inout [String], listingLimit: inout String?, count: inout Int) -> [FieldNode] {
        var nodes: [FieldNode] = []
        var position = from
        var index = 0
        while position < end {
            if count >= context.maxRecords {
                if depth == 0 {
                    listingLimit = "The first \(context.maxRecords) boxes are listed; the rest of the file is in the dump."
                    nodes.append(FieldNode(id: idPrefix + "/more", name: "More boxes", offset: position, length: end - position,
                                           kind: .bytes, value: "not listed", note: "Listing stops after \(context.maxRecords) boxes."))
                }
                break
            }
            if context.isCancelled() {
                if depth == 0 { problems.append("Stopped before the end of the file.") }
                break
            }
            let remaining = end - position
            let head = ByteWindow(source: source, at: position, count: 16)
            let at = FieldText.hexNumber(UInt64(position), size: 1)
            guard remaining >= 8, let size32 = head.u32(position, .big), let typeBytes = head.slice(position + 4, 4) else {
                nodes.append(FieldNode(id: idPrefix + "/cut", name: "Cut off", offset: position, length: remaining, kind: .problem,
                                       value: "\(FieldText.bytes(remaining)) left",
                                       note: "A box starts with eight bytes (size and type) and there are not that many here."))
                if depth == 0 { problems.append("The file ends in the middle of a box header, at \(at).") }
                break
            }
            let type = fourCC(typeBytes)
            var headerSize: Int64 = 8
            var size: Int64
            var sizeWords: String
            switch size32 {
            case 0:
                size = remaining
                sizeWords = "0 · to the end of the file"
            case 1:
                guard let large = head.u64(position + 8, .big) else {
                    nodes.append(FieldNode(id: idPrefix + "/cut", name: type, offset: position, length: remaining, kind: .problem,
                                           value: "cut off", note: "The box says its size is in the eight bytes after its type, and the file ends before them."))
                    if depth == 0 { problems.append("\(type) at \(at) is cut off in its header.") }
                    position = end
                    continue
                }
                headerSize = 16
                size = large > UInt64(Int64.max) ? Int64.max : Int64(large)
                sizeWords = "1 · 64-bit size follows: \(FieldText.bytes(size))"
            default:
                size = Int64(size32)
                sizeWords = FieldText.bytes(size)
            }
            index += 1
            count += 1
            let id = idPrefix + "/box\(index)-" + FieldList.slug(type)
            let start = position
            let title = titles[type]

            guard size >= headerSize else {
                nodes.append(FieldNode(id: id, name: type, offset: start, length: remaining, kind: .problem,
                                       value: "size \(size)", note: "A box is at least its \(headerSize)-byte header, so a size of \(size) is impossible. Nothing after it can be read."))
                if depth == 0 { problems.append("\(type) at \(at) has an impossible size of \(size).") }
                break
            }
            if size > remaining {
                let note = "The box says it is \(FieldText.bytes(size)) and only \(FieldText.bytes(remaining)) are left\(depth == 0 ? " in the file" : " in its parent")."
                nodes.append(FieldNode(id: id, name: type, offset: start, length: remaining, kind: .problem,
                                       value: [title, "cut off"].compactMap { $0 }.joined(separator: " · "), note: note,
                                       children: .deferred(DeferredChildren { headerOnly(id: id, source: source, start: start, headerSize: headerSize, type: type, sizeWords: sizeWords, held: remaining) })))
                if depth == 0 { problems.append("\(type) at \(at) is cut off: \(note)") }
                break
            }

            let short = boxSummary(type, source: source, start: start, headerSize: headerSize, size: size)
            let contents: FieldNode.Children
            let capturedHeader = headerSize
            let capturedSize = size
            let capturedWords = sizeWords
            let capturedContext = context
            let childDepth = depth + 1
            contents = .deferred(DeferredChildren {
                boxChildren(id: id, source: source, type: type, start: start, headerSize: capturedHeader, size: capturedSize,
                            sizeWords: capturedWords, depth: childDepth, context: capturedContext)
            })
            nodes.append(FieldNode(id: id, name: type, offset: start, length: size, kind: type == "mdat" ? .bytes : (["free", "skip", "wide"].contains(type) ? .padding : .container),
                                   value: [title, short, FieldText.bytes(size)].compactMap { $0 }.joined(separator: " · "),
                                   note: boxNote(type), children: contents))
            position += size
        }
        return nodes
    }

    private static func headerOnly(id: String, source: ByteSource, start: Int64, headerSize: Int64, type: String, sizeWords: String, held: Int64) -> [FieldNode] {
        let window = ByteWindow(source: source, at: start, count: Int(min(held, 64)))
        var list = FieldList(idPrefix: id, window: window, endianness: .big)
        header(&list, type: type, start: start, headerSize: headerSize, sizeWords: sizeWords)
        if held > headerSize {
            list.bytes("Contents", at: start + headerSize, length: held - headerSize, kind: .problem, note: "What there is of the box before the file ends.")
        }
        return list.nodes
    }

    private static func header(_ list: inout FieldList, type: String, start: Int64, headerSize: Int64, sizeWords: String) {
        list.uint("Size", at: start, size: 4, value: { _ in sizeWords }, note: { _ in "Counts the whole box, header and all." })
        list.bytes("Type", at: start + 4, length: 4, kind: .text, value: "\"" + type + "\"", note: titles[type])
        if headerSize == 16 {
            list.uint("Large size", at: start + 8, size: 8, value: { FieldText.bytes(Int64(truncatingIfNeeded: $0)) })
        }
    }

    private static func boxNote(_ type: String) -> String? {
        switch type {
        case "mdat": return "The samples themselves, in the order the chunk offsets in moov say. Nothing in here can be read without moov."
        case "moov": return "Every table a player needs: tracks, timings, codecs, and where each sample is in mdat. In a file written for streaming it comes before mdat."
        case "ftyp": return "Which specification the file follows, and which others it is compatible with."
        case "free", "skip": return "Space a writer left, often to have room to grow moov in place."
        case "uuid": return "A box whose type is a 16-byte UUID, for extensions outside the standard."
        default: return nil
        }
    }

    // MARK: Inside a box

    private static func boxChildren(id: String, source: ByteSource, type: String, start: Int64, headerSize: Int64, size: Int64,
                                    sizeWords: String, depth: Int, context: ParseContext) -> [FieldNode] {
        let end = start + size
        let body = start + headerSize
        var window = ByteWindow(source: source, at: start, count: Int(min(size, 65_536)))
        var list = FieldList(idPrefix: id, window: window, endianness: .big)
        header(&list, type: type, start: start, headerSize: headerSize, sizeWords: sizeWords)
        if type == "uuid" {
            list.bytes("UUID", at: body, length: 16, value: window.slice(body, 16).map { uuidText($0) })
        }
        let contentStart = type == "uuid" ? body + 16 : body
        guard contentStart < end else { return list.nodes }

        if depth < 24, type == "iinf" || type == "iref" {
            let version = fullBox(&list, at: body)
            var from = body + 4
            if type == "iinf" {
                list.uint("Entry count", at: from, size: version == 0 ? 2 : 4)
                from += version == 0 ? 2 : 4
            }
            var problems: [String] = []
            var limit: String?
            var count = 0
            let inner = boxes(source: source, idPrefix: id, from: from, end: end, depth: depth, context: context,
                              problems: &problems, listingLimit: &limit, count: &count)
            for node in inner { list.add(node) }
            return list.nodes
        }
        if depth < 24, containers.contains(type) || (type == "meta" && looksLikeFullBox(window, at: body)) {
            var problems: [String] = []
            var limit: String?
            var count = 0
            var from = contentStart
            if type == "meta" {
                list.uint("Version", at: body, size: 1)
                list.uint("Flags", at: body + 1, size: 3, kind: .flags, value: { FieldText.hexNumber($0, size: 3) })
                from = body + 4
            }
            let inner = boxes(source: source, idPrefix: id, from: from, end: end, depth: depth, context: context,
                              problems: &problems, listingLimit: &limit, count: &count)
            for node in inner { list.add(node) }
            return list.nodes
        }
        if type == "meta", !looksLikeFullBox(window, at: body) {
            // QuickTime writes meta without version and flags.
            var problems: [String] = []
            var limit: String?
            var count = 0
            let inner = boxes(source: source, idPrefix: id, from: body, end: end, depth: depth, context: context,
                              problems: &problems, listingLimit: &limit, count: &count)
            for node in inner { list.add(node) }
            return list.nodes
        }

        if type == "mdat" {
            list.bytes("Media data", at: body, length: end - body, value: FieldText.bytes(end - body),
                       note: "Not read: the audio and video samples, indexed by the tables in moov.")
            return list.nodes
        }
        window = ByteWindow(source: source, at: start, count: Int(min(size, 1 << 20)))
        list = FieldList(idPrefix: id, window: window, endianness: .big)
        header(&list, type: type, start: start, headerSize: headerSize, sizeWords: sizeWords)
        if type == "uuid" {
            list.bytes("UUID", at: body, length: 16, value: window.slice(body, 16).map { uuidText($0) })
        }
        decode(type, &list, window: window, body: contentStart, end: end, source: source, id: id, depth: depth, context: context)
        return list.nodes
    }

    private static func looksLikeFullBox(_ window: ByteWindow, at body: Int64) -> Bool {
        // A full box begins with a version (0 or 1) and 3 bytes of flags; a QuickTime meta begins
        // with a child box whose size is at least 8, so its first byte is 0 and its fourth is not small
        // only when the child is huge. Tell them apart by whether bytes 4 to 8 are a box type.
        guard let version = window.u8(body), version <= 1, let next = window.slice(body + 4, 4) else { return false }
        let typeLike = next.allSatisfy { ($0 >= 0x20 && $0 < 0x7F) }
        // In a full box, bytes 4..8 are the size of the first child box, whose high bytes are 0: not text.
        return !typeLike
    }

    private static func uuidText(_ bytes: ArraySlice<UInt8>) -> String {
        let hex = bytes.map { ByteRadix.hex.cell($0) }
        guard hex.count == 16 else { return hex.joined() }
        return hex[0..<4].joined() + "-" + hex[4..<6].joined() + "-" + hex[6..<8].joined() + "-" + hex[8..<10].joined() + "-" + hex[10..<16].joined()
    }

    // MARK: Words for a box's line

    private static func boxSummary(_ type: String, source: ByteSource, start: Int64, headerSize: Int64, size: Int64) -> String? {
        let body = start + headerSize
        let window = ByteWindow(source: source, at: body, count: Int(min(size - headerSize, 64)))
        switch type {
        case "ftyp", "styp":
            return window.slice(body, 4).map { "\"" + fourCC($0) + "\"" }
        case "hdlr":
            return window.slice(body + 8, 4).map { handlerName(fourCC($0)) }
        case "mvhd":
            guard let version = window.u8(body) else { return nil }
            let scaleAt = body + (version == 1 ? 20 : 12)
            guard let scale = window.u32(scaleAt, .big), scale > 0,
                  let duration = version == 1 ? window.u64(scaleAt + 4, .big) : window.u32(scaleAt + 4, .big).map({ UInt64($0) }) else { return nil }
            return durationText(duration, scale: UInt64(scale))
        case "tkhd":
            guard let version = window.u8(body) else { return nil }
            let idAt = body + (version == 1 ? 20 : 12)
            return window.u32(idAt, .big).map { "track \($0)" }
        case "mdhd":
            guard let version = window.u8(body) else { return nil }
            let scaleAt = body + (version == 1 ? 20 : 12)
            guard let scale = window.u32(scaleAt, .big), scale > 0,
                  let duration = version == 1 ? window.u64(scaleAt + 4, .big) : window.u32(scaleAt + 4, .big).map({ UInt64($0) }) else { return nil }
            return durationText(duration, scale: UInt64(scale))
        case "stsd":
            return window.slice(body + 12, 4).map { "\"" + fourCC($0) + "\"" }
        case "stsz":
            guard let fixed = window.u32(body + 4, .big), let count = window.u32(body + 8, .big) else { return nil }
            return fixed == 0 ? "\(count) samples" : "\(count) samples of \(fixed) bytes"
        case "trun":
            return window.u32(body + 4, .big).map { "\($0) \($0 == 1 ? "sample" : "samples")" }
        case "stts", "stss", "stsc", "stco", "co64", "ctts", "elst", "dref":
            return window.u32(body + 4, .big).map { "\($0) \($0 == 1 ? "entry" : "entries")" }
        case "mdat":
            return nil
        default:
            return nil
        }
    }

    private static func handlerName(_ code: String) -> String {
        switch code {
        case "vide": return "\"vide\" · video"
        case "soun": return "\"soun\" · sound"
        case "hint": return "\"hint\" · streaming hints"
        case "meta": return "\"meta\" · metadata"
        case "subt", "sbtl", "text": return "\"\(code)\" · subtitles or text"
        case "mdir": return "\"mdir\" · iTunes metadata"
        case "auxv": return "\"auxv\" · auxiliary video"
        case "clcp": return "\"clcp\" · closed captions"
        case "tmcd": return "\"tmcd\" · timecode"
        default: return "\"\(code)\""
        }
    }

    /// "1:02:03.456" from ticks and a time scale.
    static func durationText(_ ticks: UInt64, scale: UInt64) -> String {
        guard scale > 0 else { return "\(ticks) ticks" }
        if ticks == UInt64.max || ticks == UInt64(UInt32.max) { return "unknown length" }
        let seconds = ticks / scale
        let thousandths = (ticks % scale) * 1000 / scale
        let hours = seconds / 3600
        let minutes = seconds % 3600 / 60
        let rest = seconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d.%03d", Int(hours), Int(minutes), Int(rest), Int(thousandths)) }
        return String(format: "%d:%02d.%03d", Int(minutes), Int(rest), Int(thousandths))
    }

    /// Seconds since 1904 as a date, as the headers count time.
    static func macDate(_ seconds: UInt64) -> String {
        // 2,082,844,800 seconds from 1904-01-01 to 1970-01-01.
        guard seconds != 0 else { return "0 · not set" }
        let unix = Int64(bitPattern: seconds) - 2_082_844_800
        return "\(seconds) · " + ByteInterpreter.utcString(unixSeconds: unix)
    }

    private static func movieSummary(source: ByteSource, moov: FieldNode) -> String? {
        var tracks = 0
        var kinds: [String] = []
        var length: String?
        for child in moov.resolvedChildren() {
            if child.name == "mvhd", let value = child.value {
                // "Movie header · 0:02.000 · 108 bytes"
                let parts = value.components(separatedBy: " · ")
                if parts.count >= 3 { length = parts[1] }
            }
            if child.name == "trak" {
                tracks += 1
                for mdia in child.resolvedChildren() where mdia.name == "mdia" {
                    for hdlr in mdia.resolvedChildren() where hdlr.name == "hdlr" {
                        let parts = (hdlr.value ?? "").components(separatedBy: " · ")
                        if let quoted = parts.firstIndex(where: { $0.hasPrefix("\"") }), quoted + 1 < parts.count, !parts[quoted + 1].hasSuffix("bytes") {
                            kinds.append(parts[quoted + 1])
                        }
                    }
                }
            }
        }
        guard tracks > 0 else { return nil }
        var text = "\(tracks) \(tracks == 1 ? "track" : "tracks")"
        if !kinds.isEmpty { text += " (" + kinds.joined(separator: ", ") + ")" }
        if let length { text += ", " + length }
        return text
    }

    // MARK: Images in boxes

    /// The pictures that are kept in boxes: HEIC and AVIF (a box called meta that lists the pictures
    /// and what is known of each), JPEG 2000 (a codestream in a jp2c box) and JPEG XL's container.
    static func imageKind(roots: [FieldNode], brand: String?) -> (id: String, name: String)? {
        if roots.contains(where: { $0.name == "JXL " || $0.name == "jxlc" || $0.name == "jxlp" }) { return ("jxl", "JPEG XL") }
        if roots.contains(where: { $0.name == "jP  " || $0.name == "jp2c" }) { return ("jp2", "JPEG 2000") }
        guard !roots.contains(where: { $0.name == "moov" }), roots.contains(where: { $0.name == "meta" }) else { return nil }
        switch brand ?? "" {
        case "avif", "avis": return ("avif", "AVIF")
        case "heic", "heix", "heim", "heis", "hevc", "hevx", "hevm", "hevs": return ("heic", "HEIC")
        case "mif1", "msf1": return ("heic", "HEIF")
        default: return nil
        }
    }

    /// "4032 × 3024" from the first image size property or JPEG 2000 header found.
    private static func imageSize(roots: [FieldNode]) -> String? {
        func number(_ node: FieldNode?) -> String? {
            guard let value = node?.value else { return nil }
            return value.split(separator: " ").first.map(String.init)
        }
        func search(_ nodes: [FieldNode], depth: Int) -> String? {
            guard depth < 8 else { return nil }
            for node in nodes {
                let children = node.resolvedChildren()
                if node.name == "ipco" {
                    // One picture: the size shown is after the crop (clap) and the turn (irot) that are stated.
                    let sizes = children.filter { $0.name == "ispe" }
                    if sizes.count == 1, let size = sizes.first?.resolvedChildren(),
                       var width = number(size.first { $0.name == "Image width" }).flatMap({ Int64($0) }),
                       var height = number(size.first { $0.name == "Image height" }).flatMap({ Int64($0) }) {
                        if let clap = children.first(where: { $0.name == "clap" })?.resolvedChildren() {
                            func part(_ name: String) -> Int64? { number(clap.first { $0.name == name }).flatMap { Int64($0) } }
                            if let wn = part("Width numerator"), let wd = part("Width denominator"), wd > 0, wn / wd > 0 { width = wn / wd }
                            if let hn = part("Height numerator"), let hd = part("Height denominator"), hd > 0, hn / hd > 0 { height = hn / hd }
                        }
                        if let angle = children.first(where: { $0.name == "irot" })?.resolvedChildren().first(where: { $0.name == "Angle" }),
                           let quarter = number(angle).flatMap({ Int($0) }), quarter % 2 == 1 {
                            swap(&width, &height)
                        }
                        return "\(width) × \(height)"
                    }
                }
                if node.name == "ispe" || node.name == "ihdr" {
                    let width = number(children.first { $0.name == "Image width" || $0.name == "Width" })
                    let height = number(children.first { $0.name == "Image height" || $0.name == "Height" })
                    if let width, let height { return "\(width) × \(height)" }
                }
                if node.name == "jxlc", let size = children.first(where: { $0.name == "Codestream" })?.resolvedChildren().first(where: { $0.name == "Size header" })?.value { return size }
                if node.name == "jp2c", let size = children.first(where: { $0.name == "Codestream" })?.resolvedChildren().first(where: { $0.name == "Size marker" })?.value { return size }
                if let found = search(children, depth: depth + 1) { return found }
            }
            return nil
        }
        return search(roots, depth: 0)
    }

    // MARK: Decoding the common boxes

    @discardableResult
    private static func fullBox(_ list: inout FieldList, at body: Int64) -> UInt64 {
        let version = list.uint("Version", at: body, size: 1) ?? 0
        list.uint("Flags", at: body + 1, size: 3, kind: .flags, value: { FieldText.hexNumber($0, size: 3) })
        return version
    }

    private static func fixed16(_ raw: UInt64) -> String {
        String(format: "%.4g", Double(Int32(bitPattern: UInt32(truncatingIfNeeded: raw))) / 65536)
    }

    private static func fixed8(_ raw: UInt64) -> String {
        String(format: "%.4g", Double(Int16(bitPattern: UInt16(truncatingIfNeeded: raw))) / 256)
    }

    private static func decode(_ type: String, _ list: inout FieldList, window: ByteWindow, body: Int64, end: Int64,
                               source: ByteSource, id: String, depth: Int, context: ParseContext) {
        switch type {
        case "ftyp", "styp":
            list.text("Major brand", at: body, length: 4, note: "The specification the file follows best.")
            list.uint("Minor version", at: body + 4, size: 4)
            var at = body + 8
            var n = 0
            while at + 4 <= end, n < 64 {
                list.text("Compatible brand", at: at, length: 4)
                at += 4
                n += 1
            }
            rest(&list, from: at, end: end)
        case "mvhd", "mdhd":
            let version = fullBox(&list, at: body)
            let wide = version == 1
            let t = wide ? 8 : 4
            var at = body + 4
            list.uint("Creation time", at: at, size: t, kind: .time, value: { macDate($0) }, note: { _ in "Seconds since midnight, 1 January 1904, UTC." })
            at += Int64(t)
            list.uint("Modification time", at: at, size: t, kind: .time, value: { macDate($0) })
            at += Int64(t)
            let scale = list.uint("Time scale", at: at, size: 4, value: { "\($0) ticks per second" }) ?? 0
            at += 4
            list.uint("Duration", at: at, size: t, value: { "\($0) ticks · " + durationText($0, scale: scale) })
            at += Int64(t)
            if type == "mvhd" {
                list.uint("Preferred rate", at: at, size: 4, value: { fixed16($0) + "×" })
                list.uint("Preferred volume", at: at + 4, size: 2, value: { fixed8($0) })
                list.bytes("Reserved", at: at + 6, length: 10, kind: .padding)
                matrix(&list, at: at + 16)
                list.bytes("Pre-defined", at: at + 52, length: 24, kind: .padding)
                list.uint("Next track ID", at: at + 76, size: 4)
                rest(&list, from: at + 80, end: end)
            } else {
                list.uint("Language", at: at, size: 2, value: { languageText($0) }, note: { _ in "Three letters packed into fifteen bits, each letter as its position in the alphabet." })
                list.uint("Quality", at: at + 2, size: 2)
                rest(&list, from: at + 4, end: end)
            }
        case "tkhd":
            let version = fullBox(&list, at: body)
            let wide = version == 1
            let t = wide ? 8 : 4
            var at = body + 4
            list.uint("Creation time", at: at, size: t, kind: .time, value: { macDate($0) })
            at += Int64(t)
            list.uint("Modification time", at: at, size: t, kind: .time, value: { macDate($0) })
            at += Int64(t)
            list.uint("Track ID", at: at, size: 4)
            list.bytes("Reserved", at: at + 4, length: 4, kind: .padding)
            at += 8
            list.uint("Duration", at: at, size: t, value: { "\($0) ticks of the movie's time scale" })
            at += Int64(t)
            list.bytes("Reserved", at: at, length: 8, kind: .padding)
            list.uint("Layer", at: at + 8, size: 2)
            list.uint("Alternate group", at: at + 10, size: 2)
            list.uint("Volume", at: at + 12, size: 2, value: { fixed8($0) })
            list.bytes("Reserved", at: at + 14, length: 2, kind: .padding)
            matrix(&list, at: at + 16)
            list.uint("Width", at: at + 52, size: 4, value: { fixed16($0) + " pixels" })
            list.uint("Height", at: at + 56, size: 4, value: { fixed16($0) + " pixels" })
            rest(&list, from: at + 60, end: end)
        case "hdlr":
            fullBox(&list, at: body)
            list.bytes("Pre-defined", at: body + 4, length: 4, kind: .padding)
            list.text("Handler type", at: body + 8, length: 4, note: "What the track is: vide for video, soun for sound.")
            list.bytes("Reserved", at: body + 12, length: 12, kind: .padding)
            if end > body + 24 {
                list.text("Name", at: body + 24, length: end - body - 24)
            }
        case "elst":
            let version = fullBox(&list, at: body)
            let count = list.uint("Entry count", at: body + 4, size: 4) ?? 0
            let t: Int64 = version == 1 ? 8 : 4
            var at = body + 8
            for n in 0..<min(count, 32) where at + t * 2 + 4 <= end {
                list.group("Entry \(n + 1)", at: at, length: t * 2 + 4) { f in
                    f.uint("Segment duration", at: at, size: Int(t), value: { "\($0) ticks of the movie's time scale" })
                    f.uint("Media time", at: at + t, size: Int(t), value: { raw in
                        let signed = t == 8 ? Int64(bitPattern: raw) : Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: raw)))
                        return signed == -1 ? "-1 · empty edit" : "\(signed)"
                    })
                    f.uint("Media rate", at: at + t * 2, size: 4, value: { fixed16($0) + "×" })
                }
                at += t * 2 + 4
            }
            rest(&list, from: at, end: end, name: count > 32 ? "More entries" : "Extra bytes")
        case "stsd":
            fullBox(&list, at: body)
            let count = list.uint("Entry count", at: body + 4, size: 4) ?? 0
            var at = body + 8
            var n: UInt64 = 0
            while n < min(count, 16), at + 16 <= end, let size = window.u32(at, .big), size >= 16, at + Int64(size) <= end {
                let entrySize = Int64(size)
                let format = window.slice(at + 4, 4).map { fourCC($0) } ?? "????"
                list.group("Sample entry \"\(format)\"", at: at, length: entrySize, value: titles[format]) { f in
                    f.uint("Size", at: at, size: 4, value: { FieldText.bytes(Int64($0)) })
                    f.text("Format", at: at + 4, length: 4, note: "The codec, or the kind of sample.")
                    f.bytes("Reserved", at: at + 8, length: 6, kind: .padding)
                    f.uint("Data reference index", at: at + 14, size: 2)
                    sampleEntry(&f, format: format, at: at + 16, end: at + entrySize, source: source, id: id, depth: depth, context: context)
                }
                at += entrySize
                n += 1
            }
            rest(&list, from: at, end: end)
        case "stts", "ctts":
            fullBox(&list, at: body)
            let count = list.uint("Entry count", at: body + 4, size: 4) ?? 0
            table(&list, at: body + 8, end: end, count: count, columns: type == "stts" ? ["Sample count", "Sample delta"] : ["Sample count", "Sample offset"])
        case "stss":
            fullBox(&list, at: body)
            let count = list.uint("Entry count", at: body + 4, size: 4) ?? 0
            table(&list, at: body + 8, end: end, count: count, columns: ["Sample number"])
        case "stsc":
            fullBox(&list, at: body)
            let count = list.uint("Entry count", at: body + 4, size: 4) ?? 0
            table(&list, at: body + 8, end: end, count: count, columns: ["First chunk", "Samples per chunk", "Sample description index"])
        case "stsz":
            fullBox(&list, at: body)
            let fixed = list.uint("Sample size", at: body + 4, size: 4, value: { $0 == 0 ? "0 · each sample has its own size, below" : FieldText.bytes(Int64($0)) }) ?? 0
            let count = list.uint("Sample count", at: body + 8, size: 4) ?? 0
            if fixed == 0 {
                table(&list, at: body + 12, end: end, count: count, columns: ["Size"], unit: "bytes")
            } else {
                rest(&list, from: body + 12, end: end)
            }
        case "stco":
            fullBox(&list, at: body)
            let count = list.uint("Entry count", at: body + 4, size: 4) ?? 0
            table(&list, at: body + 8, end: end, count: count, columns: ["Chunk offset"], hex: true)
        case "co64":
            fullBox(&list, at: body)
            let count = list.uint("Entry count", at: body + 4, size: 4) ?? 0
            table(&list, at: body + 8, end: end, count: count, columns: ["Chunk offset"], width: 8, hex: true)
        case "vmhd":
            fullBox(&list, at: body)
            list.uint("Graphics mode", at: body + 4, size: 2, value: { $0 == 0 ? "0 · copy" : "\($0)" })
            list.bytes("Op colour", at: body + 6, length: 6)
            rest(&list, from: body + 12, end: end)
        case "smhd":
            fullBox(&list, at: body)
            list.uint("Balance", at: body + 4, size: 2, value: { fixed8($0) })
            list.bytes("Reserved", at: body + 6, length: 2, kind: .padding)
            rest(&list, from: body + 8, end: end)
        case "dref":
            fullBox(&list, at: body)
            let count = list.uint("Entry count", at: body + 4, size: 4) ?? 0
            var at = body + 8
            var n: UInt64 = 0
            while n < min(count, 16), let size = window.u32(at, .big), size >= 12, at + Int64(size) <= end {
                let entrySize = Int64(size)
                let kind = window.slice(at + 4, 4).map { fourCC($0) } ?? "????"
                list.group("Entry \"\(kind)\"", at: at, length: entrySize) { f in
                    f.uint("Size", at: at, size: 4, value: { FieldText.bytes(Int64($0)) })
                    f.text("Type", at: at + 4, length: 4)
                    f.uint("Version", at: at + 8, size: 1)
                    let flags = f.uint("Flags", at: at + 9, size: 3, kind: .flags, value: { $0 & 1 == 1 ? "1 · the media is in this file" : FieldText.hexNumber($0, size: 3) })
                    if entrySize > 12 {
                        f.text("Location", at: at + 12, length: entrySize - 12)
                    }
                    f.groupValue = flags.map { $0 & 1 == 1 ? "this file" : "elsewhere" }
                }
                at += entrySize
                n += 1
            }
            rest(&list, from: at, end: end)
        case "mfhd":
            fullBox(&list, at: body)
            list.uint("Sequence number", at: body + 4, size: 4)
            rest(&list, from: body + 8, end: end)
        case "tfdt":
            let version = fullBox(&list, at: body)
            list.uint("Base media decode time", at: body + 4, size: version == 1 ? 8 : 4)
            rest(&list, from: body + (version == 1 ? 12 : 8), end: end)
        case "tfhd":
            fullBox(&list, at: body)
            let flags = window.u32(body, .big).map { UInt64($0) & 0xFFFFFF } ?? 0
            list.uint("Track ID", at: body + 4, size: 4)
            var at = body + 8
            let optional: [(UInt64, String, Int)] = [(0x1, "Base data offset", 8), (0x2, "Sample description index", 4), (0x8, "Default sample duration", 4),
                                                       (0x10, "Default sample size", 4), (0x20, "Default sample flags", 4)]
            for (bit, name, size) in optional where flags & bit != 0 {
                list.uint(name, at: at, size: size)
                at += Int64(size)
            }
            rest(&list, from: at, end: end)
        case "trun":
            fullBox(&list, at: body)
            let flags = window.u32(body, .big).map { UInt64($0) & 0xFFFFFF } ?? 0
            let count = list.uint("Sample count", at: body + 4, size: 4) ?? 0
            var at = body + 8
            if flags & 0x1 != 0 {
                list.uint("Data offset", at: at, size: 4, value: { "\(Int32(bitPattern: UInt32(truncatingIfNeeded: $0)))" }, note: { _ in "Where this run's samples start, counted from the start of the moof." })
                at += 4
            }
            if flags & 0x4 != 0 {
                list.uint("First sample flags", at: at, size: 4, kind: .flags, value: { FieldText.hexNumber($0, size: 4) })
                at += 4
            }
            var columns: [String] = []
            if flags & 0x100 != 0 { columns.append("Duration") }
            if flags & 0x200 != 0 { columns.append("Size") }
            if flags & 0x400 != 0 { columns.append("Flags") }
            if flags & 0x800 != 0 { columns.append("Composition offset") }
            if columns.isEmpty { rest(&list, from: at, end: end) } else { table(&list, at: at, end: end, count: count, columns: columns) }
        case "trex":
            fullBox(&list, at: body)
            list.uint("Track ID", at: body + 4, size: 4)
            list.uint("Default sample description index", at: body + 8, size: 4)
            list.uint("Default sample duration", at: body + 12, size: 4)
            list.uint("Default sample size", at: body + 16, size: 4)
            list.uint("Default sample flags", at: body + 20, size: 4, kind: .flags, value: { FieldText.hexNumber($0, size: 4) })
            rest(&list, from: body + 24, end: end)
        case "btrt":
            list.uint("Buffer size", at: body, size: 4, value: { FieldText.bytes(Int64($0)) })
            list.uint("Maximum bit rate", at: body + 4, size: 4, value: { "\($0) bits per second" })
            list.uint("Average bit rate", at: body + 8, size: 4, value: { "\($0) bits per second" })
            rest(&list, from: body + 12, end: end)
        case "pasp":
            list.uint("Horizontal spacing", at: body, size: 4)
            list.uint("Vertical spacing", at: body + 4, size: 4)
            rest(&list, from: body + 8, end: end)
        case "colr" where (window.u8(body) ?? 0) == 1 || (window.u8(body) ?? 0) == 2:
            let method = list.uint("Method", at: body, size: 1, value: { $0 == 1 ? "1 · an enumerated colour space" : "2 · an ICC profile" }) ?? 0
            list.uint("Precedence", at: body + 1, size: 1)
            list.uint("Approximation", at: body + 2, size: 1)
            if method == 1 {
                list.uint("Colour space", at: body + 3, size: 4, value: { raw in
                    switch raw {
                    case 16: return "16 · sRGB"
                    case 17: return "17 · greyscale"
                    case 18: return "18 · sYCC"
                    default: return "\(raw)"
                    }
                })
                rest(&list, from: body + 7, end: end)
            } else {
                rest(&list, from: body + 3, end: end, name: "ICC profile")
            }
        case "colr":
            list.text("Colour type", at: body, length: 4)
            if window.slice(body, 4).map({ String(decoding: $0, as: UTF8.self) }) == "nclx" || window.slice(body, 4).map({ String(decoding: $0, as: UTF8.self) }) == "nclc" {
                list.uint("Colour primaries", at: body + 4, size: 2)
                list.uint("Transfer characteristics", at: body + 6, size: 2)
                list.uint("Matrix coefficients", at: body + 8, size: 2)
                if window.slice(body, 4).map({ String(decoding: $0, as: UTF8.self) }) == "nclx" {
                    list.bits("Full range", at: body + 10, size: 1, shift: 7, width: 1, value: { $0 == 1 ? "1 · yes, 0 to 255" : "0 · no, 16 to 235" })
                    rest(&list, from: body + 11, end: end)
                } else {
                    rest(&list, from: body + 10, end: end)
                }
            } else {
                rest(&list, from: body + 4, end: end, name: "Profile")
            }
        case "avcC":
            list.uint("Configuration version", at: body, size: 1)
            list.uint("Profile", at: body + 1, size: 1, value: { raw in
                let names: [UInt64: String] = [66: "Baseline", 77: "Main", 88: "Extended", 100: "High", 110: "High 10", 122: "High 4:2:2", 244: "High 4:4:4"]
                return names[raw].map { "\(raw) · \($0)" } ?? "\(raw)"
            })
            list.uint("Profile compatibility", at: body + 2, size: 1, kind: .flags, value: { FieldText.hexNumber($0, size: 1) })
            list.uint("Level", at: body + 3, size: 1, value: { "\($0) · level \(Double($0) / 10)" })
            list.bits("NAL length size minus one", at: body + 4, size: 1, shift: 0, width: 2, value: { "\($0) · \($0 + 1)-byte lengths" })
            rest(&list, from: body + 5, end: end, name: "Parameter sets")
        case "data":
            list.uint("Type indicator", at: body, size: 4, value: { raw in
                switch raw {
                case 1: return "1 · UTF-8 text"
                case 13: return "13 · JPEG image"
                case 14: return "14 · PNG image"
                case 21: return "21 · big-endian integer"
                case 0: return "0 · binary"
                default: return "\(raw)"
                }
            })
            list.uint("Locale", at: body + 4, size: 4)
            if end > body + 8 {
                let isText = window.u32(body, .big) == 1
                if isText { list.text("Value", at: body + 8, length: min(end - body - 8, 200)) } else { rest(&list, from: body + 8, end: end, name: "Value") }
            }
        case "pitm":
            let version = fullBox(&list, at: body)
            list.uint("Item ID", at: body + 4, size: version == 0 ? 2 : 4, note: { _ in "The item that is the picture: the others are thumbnails, metadata, or its parts." })
            rest(&list, from: body + (version == 0 ? 6 : 8), end: end)
        case "infe":
            let version = fullBox(&list, at: body)
            guard version >= 2 else { rest(&list, from: body + 4, end: end, name: "Contents"); break }
            let idSize = version == 2 ? 2 : 4
            list.uint("Item ID", at: body + 4, size: idSize)
            list.uint("Protection index", at: body + 4 + Int64(idSize), size: 2, value: { $0 == 0 ? "0 · not protected" : "\($0)" })
            list.text("Item type", at: body + 6 + Int64(idSize), length: 4, note: "hvc1 or av01 for coded pictures, grid for a picture made of tiles, Exif and mime for metadata.")
            rest(&list, from: body + 10 + Int64(idSize), end: end, name: "Name and type")
        case "iloc":
            let version = fullBox(&list, at: body)
            let sizes = window.u8(body + 4) ?? 0
            let base = window.u8(body + 5) ?? 0
            let offsetSize = Int64(sizes >> 4)
            let lengthSize = Int64(sizes & 0x0F)
            let baseSize = Int64(base >> 4)
            let indexSize = version >= 1 ? Int64(base & 0x0F) : 0
            list.group("Field sizes", at: body + 4, length: 2, kind: .flags) { f in
                f.bits("Offset size", at: body + 4, size: 1, shift: 4, width: 4, value: { "\($0) bytes" })
                f.bits("Length size", at: body + 4, size: 1, shift: 0, width: 4, value: { "\($0) bytes" })
                f.bits("Base offset size", at: body + 5, size: 1, shift: 4, width: 4, value: { "\($0) bytes" })
                f.bits("Index size", at: body + 5, size: 1, shift: 0, width: 4, value: { "\($0) bytes" })
            }
            let countSize = version < 2 ? 2 : 4
            let items = list.uint("Item count", at: body + 6, size: countSize) ?? 0
            var at = body + 6 + Int64(countSize)
            let idSize = version < 2 ? 2 : 4
            for n in 0..<min(items, 32) {
                let start = at
                var itemLength = Int64(idSize) + (version >= 1 ? 2 : 0) + 2 + baseSize + 2
                guard start + itemLength <= end else { break }
                let extents = UInt64(window.uint(start + itemLength - 2, size: 2, .big) ?? 0)
                itemLength += Int64(min(extents, 64)) * (indexSize + offsetSize + lengthSize)
                guard start + itemLength <= end else { break }
                list.group("Item \(n + 1)", at: start, length: itemLength) { f in
                    var p = start
                    let item = f.uint("Item ID", at: p, size: idSize) ?? 0
                    p += Int64(idSize)
                    var constructionMethod: UInt64 = 0
                    if version >= 1 {
                        constructionMethod = (f.uint("Construction method", at: p, size: 2, value: { $0 == 0 ? "0 · in the file" : ($0 == 1 ? "1 · in idat" : "\($0)") }) ?? 0)
                        p += 2
                    }
                    f.uint("Data reference index", at: p, size: 2); p += 2
                    var baseValue: UInt64 = 0
                    if baseSize > 0 { baseValue = f.uint("Base offset", at: p, size: Int(baseSize)) ?? 0; p += baseSize }
                    f.uint("Extent count", at: p, size: 2); p += 2
                    var words: [String] = []
                    for e in 0..<min(extents, 64) {
                        if indexSize > 0 { f.uint("Extent \(e + 1) index", at: p, size: Int(indexSize)); p += indexSize }
                        let o = offsetSize > 0 ? (f.uint("Extent \(e + 1) offset", at: p, size: Int(offsetSize)) ?? 0) : 0
                        p += offsetSize
                        let l = lengthSize > 0 ? (f.uint("Extent \(e + 1) length", at: p, size: Int(lengthSize)) ?? 0) : 0
                        p += lengthSize
                        words.append("\(l) bytes at \(o &+ (constructionMethod == 0 ? baseValue : 0))")
                    }
                    f.groupValue = "item \(item): " + words.joined(separator: ", ")
                }
                at += itemLength
            }
            rest(&list, from: at, end: end, name: items > 32 ? "More items" : "Extra bytes")
        case "ispe":
            _ = fullBox(&list, at: body)
            list.uint("Image width", at: body + 4, size: 4, value: { "\($0) pixels" })
            list.uint("Image height", at: body + 8, size: 4, value: { "\($0) pixels" })
            rest(&list, from: body + 12, end: end)
        case "pixi":
            fullBox(&list, at: body)
            let channels = Int64(list.uint("Channels", at: body + 4, size: 1) ?? 0)
            for n in 0..<min(channels, 8) { list.uint("Bits of channel \(n + 1)", at: body + 5 + n, size: 1) }
            rest(&list, from: body + 5 + min(channels, 8), end: end)
        case "irot":
            list.bits("Angle", at: body, size: 1, shift: 0, width: 2, value: { "\($0) · \($0 * 90)° anticlockwise" })
            rest(&list, from: body + 1, end: end)
        case "imir":
            list.bits("Axis", at: body, size: 1, shift: 0, width: 1, value: { $0 == 0 ? "0 · top to bottom (a vertical axis)" : "1 · left to right" })
            rest(&list, from: body + 1, end: end)
        case "clap":
            for (n, name) in ["Width numerator", "Width denominator", "Height numerator", "Height denominator", "Horizontal offset numerator", "Horizontal offset denominator", "Vertical offset numerator", "Vertical offset denominator"].enumerated() {
                if n == 4 || n == 6 {
                    list.uint(name, at: body + Int64(n) * 4, size: 4, value: { "\(Int32(bitPattern: UInt32(truncatingIfNeeded: $0)))" })
                } else {
                    list.uint(name, at: body + Int64(n) * 4, size: 4)
                }
            }
            rest(&list, from: body + 32, end: end)
        case "ipma":
            let version = fullBox(&list, at: body)
            let flags = window.u32(body, .big).map { $0 & 0xFF_FFFF } ?? 0
            let count = list.uint("Entry count", at: body + 4, size: 4) ?? 0
            var at = body + 8
            for n in 0..<min(count, 32) {
                let idSize: Int64 = version < 1 ? 2 : 4
                guard at + idSize + 1 <= end, let associations = window.u8(at + idSize).map({ Int64($0) }) else { break }
                let each: Int64 = flags & 1 == 1 ? 2 : 1
                let length = idSize + 1 + associations * each
                guard at + length <= end else { break }
                let start = at
                list.group("Item \(n + 1)", at: start, length: length) { f in
                    let item = f.uint("Item ID", at: start, size: Int(idSize)) ?? 0
                    f.uint("Association count", at: start + idSize, size: 1)
                    var numbers: [String] = []
                    for a in 0..<associations {
                        let at = start + idSize + 1 + a * each
                        let raw = f.uint("Property \(a + 1)", at: at, size: Int(each), value: { raw in
                            let index = each == 2 ? raw & 0x7FFF : raw & 0x7F
                            let essential = each == 2 ? raw & 0x8000 != 0 : raw & 0x80 != 0
                            return "box \(index) of ipco" + (essential ? " · essential" : "")
                        }) ?? 0
                        numbers.append("\(each == 2 ? raw & 0x7FFF : raw & 0x7F)")
                    }
                    f.groupValue = "item \(item): properties " + numbers.joined(separator: ", ")
                }
                at += length
            }
            rest(&list, from: at, end: end, name: count > 32 ? "More items" : "Extra bytes")
        case "av1C":
            list.bits("Marker", at: body, size: 1, shift: 7, width: 1)
            list.bits("Version", at: body, size: 1, shift: 0, width: 7)
            list.bits("Profile", at: body + 1, size: 1, shift: 5, width: 3, value: { ["0 · Main", "1 · High", "2 · Professional"].indices.contains(Int($0)) ? ["0 · Main", "1 · High", "2 · Professional"][Int($0)] : "\($0)" })
            list.bits("Level", at: body + 1, size: 1, shift: 0, width: 5)
            list.bits("Tier", at: body + 2, size: 1, shift: 7, width: 1)
            list.bits("High bit depth", at: body + 2, size: 1, shift: 6, width: 1)
            list.bits("Twelve bit", at: body + 2, size: 1, shift: 5, width: 1)
            list.bits("Monochrome", at: body + 2, size: 1, shift: 4, width: 1)
            list.bits("Chroma subsampling x", at: body + 2, size: 1, shift: 3, width: 1)
            list.bits("Chroma subsampling y", at: body + 2, size: 1, shift: 2, width: 1)
            rest(&list, from: body + 4, end: end, name: "Configuration OBUs")
        case "hvcC":
            list.uint("Configuration version", at: body, size: 1)
            list.bits("Profile space", at: body + 1, size: 1, shift: 6, width: 2)
            list.bits("Tier", at: body + 1, size: 1, shift: 5, width: 1)
            list.bits("Profile", at: body + 1, size: 1, shift: 0, width: 5, value: { [1: "1 · Main", 2: "2 · Main 10", 3: "3 · Main Still Picture"][$0] ?? "\($0)" })
            list.uint("Compatibility flags", at: body + 2, size: 4, kind: .flags, value: { FieldText.hexNumber($0, size: 4) })
            list.bytes("Constraint flags", at: body + 6, length: 6)
            list.uint("Level", at: body + 12, size: 1, value: { "\($0) · level \(Double($0) / 30)" })
            rest(&list, from: body + 13, end: end, name: "Further configuration")
        case "ihdr":
            list.uint("Height", at: body, size: 4, value: { "\($0) pixels" })
            list.uint("Width", at: body + 4, size: 4, value: { "\($0) pixels" })
            list.uint("Components", at: body + 8, size: 2)
            list.uint("Bits per component", at: body + 10, size: 1, value: { raw in raw == 255 ? "255 · varies, see bpcc" : "\((raw & 0x7F) + 1) bits, " + (raw & 0x80 != 0 ? "signed" : "unsigned") })
            list.uint("Compression type", at: body + 11, size: 1, value: { $0 == 7 ? "7 · JPEG 2000" : "\($0)" })
            list.uint("Colour space unknown", at: body + 12, size: 1)
            list.uint("Intellectual property", at: body + 13, size: 1)
            rest(&list, from: body + 14, end: end)
        case "jP  ":
            list.bytes("Signature", at: body, length: 4, kind: .magic, note: "0D 0A 87 0A: a carriage return and line feed, so that a transfer that rewrites line ends is noticed, and a byte with the top bit set.")
        case "jp2c":
            let length = end - body
            if let marker = window.slice(body, 4), Array(marker) == [0xFF, 0x4F, 0xFF, 0x51], length >= 42 {
                list.group("Codestream", at: body, length: length, kind: .bytes, value: FieldText.bytes(length),
                           note: "The compressed image. It begins with the markers FF4F (start of codestream) and FF51 (size), whose fields are decoded here.") { f in
                    f.uint("Start marker", at: body, size: 2, kind: .magic, value: { FieldText.hexNumber($0, size: 2) })
                    f.group("Size marker", at: body + 2, length: 38, note: "The picture's size on the reference grid.") { g in
                        g.uint("Marker", at: body + 2, size: 2, kind: .magic, value: { FieldText.hexNumber($0, size: 2) })
                        g.uint("Length", at: body + 4, size: 2)
                        g.uint("Capabilities", at: body + 6, size: 2)
                        let w = g.uint("Reference grid width", at: body + 8, size: 4) ?? 0
                        let h = g.uint("Reference grid height", at: body + 12, size: 4) ?? 0
                        g.uint("Image offset x", at: body + 16, size: 4)
                        g.uint("Image offset y", at: body + 20, size: 4)
                        g.uint("Tile width", at: body + 24, size: 4)
                        g.uint("Tile height", at: body + 28, size: 4)
                        g.uint("Tile offset x", at: body + 32, size: 4)
                        g.uint("Tile offset y", at: body + 36, size: 4)
                        g.groupValue = "\(w) × \(h)"
                    }
                    f.bytes("Rest of the codestream", at: body + 40, length: length - 40, value: FieldText.bytes(length - 40))
                }
            } else {
                list.bytes("Codestream", at: body, length: length, value: FieldText.bytes(length),
                           note: "The compressed image. It should begin with FF4F FF51, which it does not.")
            }
        case "jxlc":
            let length = end - body
            if let signature = window.slice(body, 2), Array(signature) == [0xFF, 0x0A] {
                list.group("Codestream", at: body, length: length, kind: .bytes, value: FieldText.bytes(length),
                           note: "The compressed image, which begins as a bare JPEG XL codestream does.") { f in
                    f.bytes("Signature", at: body, length: 2, kind: .magic, value: "FF 0A")
                    let held = window.slice(body + 2, Int(min(length - 2, 62))).map(Array.init) ?? []
                    if length > 2, let size = JXLParser.dimensions(held) {
                        let bytes = Int64((size.bits + 7) / 8)
                        f.bytes("Size header", at: body + 2, length: bytes, value: "\(size.width) × \(size.height)",
                                note: "The picture's height, then its width, packed into \(size.bits) bits.")
                        f.bytes("Rest of the codestream", at: body + 2 + bytes, length: length - 2 - bytes, value: FieldText.bytes(length - 2 - bytes))
                    } else {
                        f.bytes("Rest of the codestream", at: body + 2, length: length - 2, value: FieldText.bytes(length - 2))
                    }
                }
            } else {
                list.bytes("Codestream", at: body, length: length, value: FieldText.bytes(length))
            }
        case "esds":
            _ = fullBox(&list, at: body)
            rest(&list, from: body + 4, end: end, name: "Descriptors")
        default:
            rest(&list, from: body, end: end, name: "Contents")
        }
    }

    /// What is inside a sample entry after the common fields: the size of a video, the rate
    /// of a sound, and the boxes that configure the codec.
    private static func sampleEntry(_ f: inout FieldList, format: String, at: Int64, end: Int64, source: ByteSource, id: String, depth: Int, context: ParseContext) {
        let video: Set<String> = ["avc1", "avc3", "hvc1", "hev1", "mp4v", "av01", "vp09", "vp08", "jpeg", "apch", "apcn", "apcs", "apco", "ap4h", "s263", "encv"]
        let audio: Set<String> = ["mp4a", "ac-3", "ec-3", "alac", "Opus", "fLaC", "samr", "sawb", "twos", "sowt", "lpcm", "enca", ".mp3", "ulaw", "alaw"]
        var from = at
        if video.contains(format), at + 70 <= end {
            f.bytes("Pre-defined and reserved", at: at, length: 16, kind: .padding)
            f.uint("Width", at: at + 16, size: 2, value: { "\($0) pixels" })
            f.uint("Height", at: at + 18, size: 2, value: { "\($0) pixels" })
            f.uint("Horizontal resolution", at: at + 20, size: 4, value: { fixed16($0) + " dpi" })
            f.uint("Vertical resolution", at: at + 24, size: 4, value: { fixed16($0) + " dpi" })
            f.bytes("Reserved", at: at + 28, length: 4, kind: .padding)
            f.uint("Frame count", at: at + 32, size: 2, note: { _ in "Frames in each sample, usually 1." })
            f.bytes("Compressor name", at: at + 34, length: 32, value: f.window.slice(at + 34, 32).map { slice in
                let n = Int(slice.first ?? 0)
                return FieldText.ascii(slice.dropFirst().prefix(min(n, 31)))
            }, note: "A Pascal string: its first byte is its length.")
            f.uint("Depth", at: at + 66, size: 2, value: { "\($0) bits" })
            f.uint("Pre-defined", at: at + 68, size: 2)
            from = at + 70
        } else if audio.contains(format), at + 20 <= end {
            let version = f.uint("Version", at: at, size: 2) ?? 0
            f.uint("Revision level", at: at + 2, size: 2)
            f.uint("Vendor", at: at + 4, size: 4)
            f.uint("Channel count", at: at + 8, size: 2)
            f.uint("Sample size", at: at + 10, size: 2, value: { "\($0) bits" })
            f.uint("Pre-defined", at: at + 12, size: 2)
            f.bytes("Reserved", at: at + 14, length: 2, kind: .padding)
            f.uint("Sample rate", at: at + 16, size: 4, value: { "\($0 >> 16) Hz" }, note: { _ in "A 16.16 fixed-point number: the whole part is in the top two bytes." })
            from = at + 20
            if version == 1, at + 36 <= end {
                f.uint("Samples per packet", at: at + 20, size: 4)
                f.uint("Bytes per packet", at: at + 24, size: 4)
                f.uint("Bytes per frame", at: at + 28, size: 4)
                f.uint("Bytes per sample", at: at + 32, size: 4)
                from = at + 36
            }
        }
        if from < end, depth < 24 {
            var problems: [String] = []
            var limit: String?
            var count = 0
            let inner = boxes(source: source, idPrefix: f.claimID("extensions"), from: from, end: end, depth: depth + 1, context: context,
                              problems: &problems, listingLimit: &limit, count: &count)
            if inner.isEmpty || inner.contains(where: { $0.kind == .problem }) {
                f.bytes("Extra data", at: from, length: end - from)
            } else {
                for node in inner { f.add(node) }
            }
        }
    }

    private static func matrix(_ list: inout FieldList, at: Int64) {
        list.group("Transformation matrix", at: at, length: 36, note: "Nine 32-bit fixed-point numbers; the identity is 1, 0, 0, 0, 1, 0, 0, 0, 1, which is the usual.") { f in
            let names = ["a", "b", "u", "c", "d", "v", "x", "y", "w"]
            var values: [String] = []
            for (n, name) in names.enumerated() {
                let isScale = n == 2 || n == 5 || n == 8
                let raw = f.uint(name, at: at + Int64(n) * 4, size: 4, value: { raw in
                    isScale ? String(format: "%.4g", Double(Int32(bitPattern: UInt32(truncatingIfNeeded: raw))) / 1_073_741_824) : fixed16(raw)
                })
                if let raw { values.append(isScale ? String(format: "%.4g", Double(Int32(bitPattern: UInt32(truncatingIfNeeded: raw))) / 1_073_741_824) : fixed16(raw)) }
            }
            f.groupValue = values.joined(separator: ", ")
        }
    }

    /// A table of `count` rows of 32-bit (or `width`-byte) columns: the first rows one by one,
    /// the rest as a single run.
    private static func table(_ list: inout FieldList, at: Int64, end: Int64, count: UInt64, columns: [String], width: Int = 4, unit: String? = nil, hex: Bool = false) {
        let rowSize = Int64(width * columns.count)
        let shown = min(count, 32)
        var position = at
        for row in 0..<shown where position + rowSize <= end {
            let rowStart = position
            list.group("Row \(row + 1)", at: rowStart, length: rowSize) { f in
                var words: [String] = []
                for (n, column) in columns.enumerated() {
                    let value = f.uint(column, at: rowStart + Int64(n * width), size: width, value: { raw in
                        hex ? FieldText.hexNumber(raw, size: width) : "\(raw)" + (unit.map { " " + $0 } ?? "")
                    })
                    if let value { words.append(hex ? FieldText.hexNumber(value, size: width) : "\(value)") }
                }
                f.groupValue = words.joined(separator: ", ")
            }
            position += rowSize
        }
        if count > shown {
            let more = Int64(count - shown)
            let length = min(more * rowSize, max(0, end - position))
            list.bytes("More rows", at: position, length: length, value: "\(more) more", note: "The first 32 rows are opened one by one.")
            position += length
        }
        rest(&list, from: position, end: end)
    }

    private static func rest(_ list: inout FieldList, from: Int64, end: Int64, name: String = "Extra bytes") {
        guard from < end else { return }
        list.bytes(name, at: from, length: end - from, kind: name == "Extra bytes" ? .padding : .bytes,
                   note: name == "Extra bytes" ? "More than this kind of box has a use for." : nil)
    }

    static func languageText(_ raw: UInt64) -> String {
        guard raw != 0 else { return "0 · not set" }
        let a = (raw >> 10) & 0x1F
        let b = (raw >> 5) & 0x1F
        let c = raw & 0x1F
        guard raw != 0x7FFF else { return "\(raw) · unspecified" }
        guard (1...26).contains(a), (1...26).contains(b), (1...26).contains(c) else { return "\(raw) · QuickTime language code" }
        let letters = [a, b, c].map { Character(UnicodeScalar(UInt8($0) + 0x60)) }
        return "\"" + String(letters) + "\""
    }
}
