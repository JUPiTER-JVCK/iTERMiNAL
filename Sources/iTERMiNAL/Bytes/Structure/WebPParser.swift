import Foundation

/// A WebP image: a RIFF file of chunks. A simple file is one `VP8 ` (lossy) or `VP8L` (lossless) chunk; an
/// extended one starts with `VP8X` and may add colour profiles, alpha, metadata, and animation, where each frame is
/// an `ANMF` chunk holding chunks of its own.
enum WebPParser: FormatParser {
    static let identity = FormatIdentity(id: "webp", name: "a WebP image", detail: "RIFF container", hasParser: true)

    static func matches(head: [UInt8], length: Int64) -> Bool {
        head.count >= 12 && Array(head[0..<4]) == Array("RIFF".utf8) && Array(head[8..<12]) == Array("WEBP".utf8)
    }

    static let titles: [String: String] = [
        "VP8X": "Extended format header", "VP8 ": "Lossy image data", "VP8L": "Lossless image data", "ALPH": "Alpha channel",
        "ANIM": "Animation settings", "ANMF": "Animation frame", "ICCP": "Colour profile", "EXIF": "Exif metadata", "XMP ": "XMP metadata"
    ]

    static func parse(_ source: ByteSource, context: ParseContext) -> ParseOutcome {
        var outcome = ParseOutcome()
        let total = source.count
        var problems: [String] = []
        let head = ByteWindow(source: source, at: 0, count: 12)
        var list = FieldList(idPrefix: "webp", window: head, endianness: .little)
        var declared: UInt64 = 0
        list.group("RIFF header", at: 0, length: 12, note: "RIFF, how long the rest is, and the kind of file: WEBP.") { f in
            f.text("Signature", at: 0, length: 4)
            declared = f.uint("Size", at: 4, size: 4, value: { FieldText.bytes(Int64($0)) + " after this field" }) ?? 0
            f.text("Form type", at: 8, length: 4)
            f.groupValue = "RIFF WEBP"
        }
        outcome.roots.append(contentsOf: list.nodes)
        guard !list.truncated else {
            outcome.problems = ["The file ends inside the RIFF header."]
            return outcome
        }
        if Int64(declared) + 8 != total {
            problems.append("The RIFF header says the file is \(FieldText.bytes(Int64(declared) + 8)) and it is \(FieldText.bytes(total)).")
        }
        var info = Info()
        let end = min(total, Int64(declared) + 8 > 12 ? Int64(declared) + 8 : total)
        let chunks = walk(source: source, idPrefix: "webp", from: 12, end: end, context: context, problems: &problems, info: &info, listingLimit: &outcome.listingLimit, top: true)
        outcome.roots.append(contentsOf: chunks)
        if end < total {
            outcome.roots.append(FieldNode(id: "webp/after", name: "Data after the RIFF", offset: end, length: total - end, kind: .bytes, value: FieldText.bytes(total - end),
                                           note: "The RIFF header says the file ends before this."))
        }
        outcome.problems = Array(problems.prefix(20))
        var summary = "WebP"
        if info.animated { summary += " animation" } else if let kind = info.kind { summary += " " + kind }
        if let w = info.width, let h = info.height { summary += ", \(w) × \(h)" }
        if info.frames > 0 { summary += ", \(info.frames) \(info.frames == 1 ? "frame" : "frames")" }
        if info.alpha { summary += ", with alpha" }
        outcome.summary = summary
        return outcome
    }

    struct Info {
        var width: UInt64?
        var height: UInt64?
        var kind: String?
        var animated = false
        var alpha = false
        var frames = 0
    }

    /// The chunks from `from` to `end`: each a four-letter name, a little-endian size, that many bytes, and a pad byte if the size is odd.
    private static func walk(source: ByteSource, idPrefix: String, from: Int64, end: Int64, context: ParseContext, problems: inout [String],
                             info: inout Info, listingLimit: inout String?, top: Bool) -> [FieldNode] {
        var nodes: [FieldNode] = []
        var position = from
        var index = 0
        while position < end {
            if index >= context.maxRecords {
                if top {
                    listingLimit = "The first \(context.maxRecords) chunks are listed; the rest of the file is in the dump."
                    nodes.append(FieldNode(id: idPrefix + "/more", name: "More chunks", offset: position, length: end - position, kind: .bytes, value: "not listed"))
                }
                break
            }
            if context.isCancelled() { if top { problems.append("Stopped before the end of the file.") }; break }
            let window = ByteWindow(source: source, at: position, count: 8)
            let at = FieldText.hexNumber(UInt64(position), size: 1)
            guard end - position >= 8, let typeBytes = window.slice(position, 4), let size = window.u32(position + 4, .little) else {
                nodes.append(FieldNode(id: idPrefix + "/cut", name: "Cut off", offset: position, length: end - position, kind: .problem, value: "\(FieldText.bytes(end - position)) left",
                                       note: "A chunk starts with eight bytes (name and size) and there are not that many here."))
                if top { problems.append("The file ends in the middle of a chunk header, at \(at).") }
                break
            }
            index += 1
            let type = String(decoding: typeBytes.map(HexGeometry.textByte), as: UTF8.self)
            let declared = Int64(size)
            let padded = declared + declared % 2
            let id = idPrefix + "/chunk\(index)-" + FieldList.slug(type)
            let start = position
            let fits = 8 + declared <= end - position
            let held = fits ? 8 + declared : end - position
            let dataLength = fits ? declared : held - 8
            // What the chunk says about the picture, for the summary.
            switch type {
            case "VP8X":
                let w = ByteWindow(source: source, at: position + 8, count: 10)
                if let flags = w.u8(position + 8), let cw = w.uint(position + 12, size: 3, .little), let ch = w.uint(position + 15, size: 3, .little) {
                    info.width = cw + 1; info.height = ch + 1
                    info.animated = flags & 0x02 != 0
                    info.alpha = flags & 0x10 != 0
                    info.kind = "extended"
                }
            case "VP8 ":
                let w = ByteWindow(source: source, at: position + 8, count: 10)
                if info.kind == nil || info.kind == "extended", !info.animated, let signature = w.slice(position + 11, 3), Array(signature) == [0x9D, 0x01, 0x2A],
                   let cw = w.u16(position + 14, .little), let ch = w.u16(position + 16, .little) {
                    if info.width == nil { info.width = UInt64(cw & 0x3FFF); info.height = UInt64(ch & 0x3FFF) }
                    if info.kind == nil { info.kind = "lossy" }
                }
                if top { info.frames += 1 }
            case "VP8L":
                let w = ByteWindow(source: source, at: position + 8, count: 5)
                if info.kind == nil || info.kind == "extended", w.u8(position + 8) == 0x2F, let bits = w.u32(position + 9, .little) {
                    if info.width == nil { info.width = UInt64(bits & 0x3FFF) + 1; info.height = UInt64((bits >> 14) & 0x3FFF) + 1 }
                    if info.kind == nil { info.kind = "lossless" }
                }
                if top { info.frames += 1 }
            case "ANMF":
                info.frames += 1
            default:
                break
            }
            var note = titles[type]
            if !fits {
                note = "The chunk says it has \(FieldText.bytes(declared)) of data and the file ends after \(FieldText.bytes(dataLength)) of it."
                if top { problems.append("\(type) at \(at) is cut off: \(note ?? "")") }
            }
            nodes.append(FieldNode(
                id: id, name: type, offset: start, length: held, kind: fits ? .container : .problem,
                value: [titles[type], chunkSummary(type, source: source, at: start, length: dataLength), FieldText.bytes(declared)].compactMap { $0 }.joined(separator: " · "),
                note: fits ? chunkNote(type) : note,
                children: .deferred(DeferredChildren {
                    chunkChildren(id: id, source: source, start: start, type: type, declared: declared, dataLength: dataLength, fits: fits, context: context)
                })))
            if !fits { break }
            position += 8 + padded
        }
        return nodes
    }

    private static func chunkNote(_ type: String) -> String? {
        switch type {
        case "VP8 ": return "A picture compressed the way a VP8 video key frame is: lossy, small."
        case "VP8L": return "A picture compressed without loss, with its own transforms and prefix codes."
        case "VP8X": return "Present when the file has more than a single picture: says which extras, and how big the canvas is."
        case "ANMF": return "One frame of an animation: where it goes, how long it shows, and its own image chunks."
        case "ALPH": return "The transparency of a lossy picture, compressed separately."
        case "ICCP": return "An ICC colour profile."
        case "EXIF": return "Camera and other metadata, as a TIFF."
        case "XMP ": return "Metadata as XML."
        default: return nil
        }
    }

    private static func chunkSummary(_ type: String, source: ByteSource, at: Int64, length: Int64) -> String? {
        let w = ByteWindow(source: source, at: at + 8, count: 20)
        switch type {
        case "VP8X":
            guard let cw = w.uint(at + 12, size: 3, .little), let ch = w.uint(at + 15, size: 3, .little) else { return nil }
            return "\(cw + 1) × \(ch + 1)"
        case "VP8 ":
            guard let a = w.u16(at + 14, .little), let b = w.u16(at + 16, .little) else { return nil }
            return "\(a & 0x3FFF) × \(b & 0x3FFF)"
        case "VP8L":
            guard let bits = w.u32(at + 9, .little) else { return nil }
            return "\((bits & 0x3FFF) + 1) × \(((bits >> 14) & 0x3FFF) + 1)"
        case "ANMF":
            guard let duration = w.uint(at + 20, size: 3, .little) else { return nil }
            return "\(duration) ms"
        default:
            return nil
        }
    }

    private static func chunkChildren(id: String, source: ByteSource, start: Int64, type: String, declared: Int64, dataLength: Int64, fits: Bool, context: ParseContext) -> [FieldNode] {
        let window = ByteWindow(source: source, at: start, count: Int(min(8 + dataLength, 4096)))
        var list = FieldList(idPrefix: id, window: window, endianness: .little)
        list.text("Type", at: start, length: 4, note: titles[type])
        list.uint("Size", at: start + 4, size: 4, value: { FieldText.bytes(Int64($0)) }, note: { _ in "Not counting this header or the pad byte after an odd size." })
        let data = start + 8
        let end = data + dataLength
        switch type {
        case "VP8X":
            let flags = window.u8(data) ?? 0
            list.group("Flags", at: data, length: 1, kind: .flags) { f in
                f.bits("ICC profile", at: data, size: 1, shift: 5, width: 1)
                f.bits("Alpha", at: data, size: 1, shift: 4, width: 1)
                f.bits("Exif", at: data, size: 1, shift: 3, width: 1)
                f.bits("XMP", at: data, size: 1, shift: 2, width: 1)
                f.bits("Animation", at: data, size: 1, shift: 1, width: 1)
                f.groupValue = FieldText.hexNumber(UInt64(flags), size: 1)
            }
            list.bytes("Reserved", at: data + 1, length: 3, kind: .padding)
            list.uint("Canvas width minus one", at: data + 4, size: 3, value: { "\($0) · \($0 + 1) pixels" })
            list.uint("Canvas height minus one", at: data + 7, size: 3, value: { "\($0) · \($0 + 1) pixels" })
            rest(&list, from: data + 10, end: end)
        case "VP8 ":
            list.group("Frame tag", at: data, length: 3) { f in
                f.bits("Not a key frame", at: data, size: 3, shift: 0, width: 1, value: { $0 == 0 ? "0 · key frame" : "1 · inter frame" })
                f.bits("Version", at: data, size: 3, shift: 1, width: 3)
                f.bits("Shown", at: data, size: 3, shift: 4, width: 1)
                f.bits("First partition size", at: data, size: 3, shift: 5, width: 19, value: { FieldText.bytes(Int64($0)) })
            }
            list.bytes("Start code", at: data + 3, length: 3, kind: .magic, note: "9D 01 2A begins every key frame.")
            list.uint("Width", at: data + 6, size: 2, value: { "\($0 & 0x3FFF) pixels" + ($0 >> 14 != 0 ? ", scale \($0 >> 14)" : "") })
            list.uint("Height", at: data + 8, size: 2, value: { "\($0 & 0x3FFF) pixels" + ($0 >> 14 != 0 ? ", scale \($0 >> 14)" : "") })
            rest(&list, from: data + 10, end: end, name: "Compressed data", note: "Not decoded.")
        case "VP8L":
            list.bytes("Signature", at: data, length: 1, kind: .magic, note: "0x2F begins every lossless image.")
            list.bits("Width minus one", at: data + 1, size: 4, shift: 0, width: 14, value: { "\($0) · \($0 + 1) pixels" })
            list.bits("Height minus one", at: data + 1, size: 4, shift: 14, width: 14, value: { "\($0) · \($0 + 1) pixels" })
            list.bits("Alpha used", at: data + 1, size: 4, shift: 28, width: 1)
            list.bits("Version", at: data + 1, size: 4, shift: 29, width: 3)
            rest(&list, from: data + 5, end: end, name: "Compressed data", note: "Not decoded.")
        case "ANIM":
            list.bytes("Background colour", at: data, length: 4, note: "Blue, green, red, alpha.")
            list.uint("Loop count", at: data + 4, size: 2, value: { $0 == 0 ? "0 · forever" : "\($0)" })
            rest(&list, from: data + 6, end: end)
        case "ANMF":
            list.uint("Frame X", at: data, size: 3, value: { "\($0 * 2) pixels" }, note: { _ in "Stored halved." })
            list.uint("Frame Y", at: data + 3, size: 3, value: { "\($0 * 2) pixels" }, note: { _ in "Stored halved." })
            list.uint("Frame width minus one", at: data + 6, size: 3, value: { "\($0 + 1) pixels" })
            list.uint("Frame height minus one", at: data + 9, size: 3, value: { "\($0 + 1) pixels" })
            list.uint("Duration", at: data + 12, size: 3, value: { "\($0) ms" })
            list.group("Flags", at: data + 15, length: 1, kind: .flags) { f in
                f.bits("Blending", at: data + 15, size: 1, shift: 1, width: 1, value: { $0 == 0 ? "0 · alpha-blend over the canvas" : "1 · overwrite" })
                f.bits("Disposal", at: data + 15, size: 1, shift: 0, width: 1, value: { $0 == 0 ? "0 · leave" : "1 · clear to background" })
            }
            var problems: [String] = []
            var info = Info()
            var limit: String?
            for node in walk(source: source, idPrefix: id + "/frame", from: data + 16, end: end, context: context, problems: &problems, info: &info, listingLimit: &limit, top: false) { list.add(node) }
        case "ALPH":
            list.group("Flags", at: data, length: 1, kind: .flags) { f in
                f.bits("Pre-processing", at: data, size: 1, shift: 4, width: 2)
                f.bits("Filtering", at: data, size: 1, shift: 2, width: 2, value: { ["0 · none", "1 · horizontal", "2 · vertical", "3 · gradient"][Int($0)] })
                f.bits("Compression", at: data, size: 1, shift: 0, width: 2, value: { $0 == 0 ? "0 · none" : "1 · lossless" })
            }
            rest(&list, from: data + 1, end: end, name: "Alpha data", note: "Not decoded.")
        default:
            rest(&list, from: data, end: end, name: "Data", note: nil)
        }
        if fits, declared % 2 == 1 {
            list.bytes("Pad byte", at: end, length: 1, kind: .padding, note: "Chunks are padded to an even length.")
        }
        return list.nodes
    }

    private static func rest(_ list: inout FieldList, from: Int64, end: Int64, name: String = "Extra bytes", note: String? = "More than this kind of chunk has a use for.") {
        guard from < end else { return }
        list.bytes(name, at: from, length: end - from, kind: name == "Extra bytes" ? .padding : .bytes, note: note)
    }
}
