import Foundation

/// A GIF file taken apart: a header, a screen descriptor, an optional colour table, and then blocks until a
/// trailer: images (each with its own descriptor, optional colour table and LZW-compressed data in
/// sub-blocks of at most 255 bytes) and extensions (timing and transparency, comments, loop counts).
enum GIFParser: FormatParser {
    static let identity = FormatIdentity(id: "gif", name: "a GIF image", detail: "Graphics Interchange Format", hasParser: true)

    static func matches(head: [UInt8], length: Int64) -> Bool {
        head.count >= 6 && Array(head[0..<4]) == Array("GIF8".utf8) && (head[4] == 0x37 || head[4] == 0x39) && head[5] == 0x61
    }

    private static func tableSize(_ packed: UInt64, shift: Int) -> Int64 {
        3 * (Int64(1) << (Int64((packed >> UInt64(shift)) & 7) + 1))
    }

    static func parse(_ source: ByteSource, context: ParseContext) -> ParseOutcome {
        var outcome = ParseOutcome()
        let total = source.count
        let scanner = SourceScanner(source: source, budget: 1 << 30, isCancelled: context.isCancelled)
        var problems: [String] = []
        let head = ByteWindow(source: source, at: 0, count: 13)
        var list = FieldList(idPrefix: "gif", window: head, endianness: .little)
        var version = ""
        list.group("Header", at: 0, length: 6, kind: .magic) { f in
            if let text = f.text("Signature and version", at: 0, length: 6, note: "GIF87a or GIF89a. 89a adds the extensions below.") {
                version = String(decoding: text.suffix(3), as: UTF8.self)
                f.groupValue = "GIF" + version
            }
        }
        var width: UInt64 = 0
        var height: UInt64 = 0
        var tableLength: Int64 = 0
        list.group("Logical screen descriptor", at: 6, length: 7, value: nil,
                   note: "The size of the canvas the images are drawn on, and whether there is a table of colours for all of them.") { f in
            width = f.uint("Width", at: 6, size: 2, value: { "\($0) pixels" }) ?? 0
            height = f.uint("Height", at: 8, size: 2, value: { "\($0) pixels" }) ?? 0
            let packed = window8(head, 10)
            f.bits("Global colour table", at: 10, size: 1, shift: 7, width: 1, value: { $0 == 1 ? "1 · present" : "0 · none" })
            f.bits("Colour resolution", at: 10, size: 1, shift: 4, width: 3, value: { "\($0 + 1) bits" })
            f.bits("Sorted", at: 10, size: 1, shift: 3, width: 1)
            f.bits("Table size", at: 10, size: 1, shift: 0, width: 3, value: { "\($0) · \(1 << ($0 + 1)) colours" })
            f.uint("Background colour index", at: 11, size: 1)
            f.uint("Pixel aspect ratio", at: 12, size: 1, value: { $0 == 0 ? "0 · square" : "\($0)" })
            if packed & 0x80 != 0 { tableLength = tableSize(UInt64(packed), shift: 0) }
            f.groupValue = "\(width) × \(height)"
        }
        outcome.roots.append(contentsOf: list.nodes)
        guard !list.truncated else {
            outcome.problems = ["The file ends inside the header."]
            outcome.summary = "GIF image, cut off in its header"
            return outcome
        }
        var position: Int64 = 13
        if tableLength > 0 {
            let length = min(tableLength, total - position)
            outcome.roots.append(FieldNode(id: "gif/colours", name: "Global colour table", offset: position, length: length, kind: .bytes,
                                           value: "\(tableLength / 3) colours",
                                           note: "Three bytes for each colour: red, green, blue. Images that have no table of their own use this one."))
            position += length
        }

        var index = 0
        var images = 0
        var frameDelays = 0
        var loops: String?
        var sawTrailer = false
        var stopped = false
        func stop(_ id: String, _ name: String, at: Int64, _ note: String, _ problem: String) {
            stopped = true
            outcome.roots.append(FieldNode(id: id, name: name, offset: at, length: total - at, kind: .problem, value: FieldText.bytes(total - at), note: note))
            problems.append(problem)
        }

        while position < total {
            if index >= context.maxRecords {
                stopped = true
                outcome.listingLimit = "The first \(context.maxRecords) blocks are listed; the rest of the file is in the dump."
                outcome.roots.append(FieldNode(id: "gif/more", name: "More blocks", offset: position, length: total - position, kind: .bytes, value: "not listed"))
                break
            }
            if context.isCancelled() { stopped = true; problems.append("Stopped before the end of the file."); break }
            index += 1
            let start = position
            let at = FieldText.hexNumber(UInt64(start), size: 1)
            guard let introducer = scanner.byte(at: position) else { break }
            let id = "gif/block\(index)"

            switch introducer {
            case 0x3B:
                outcome.roots.append(FieldNode(id: id, name: "Trailer", offset: start, length: 1, kind: .magic, value: "3B", note: "The last byte of a GIF."))
                position += 1
                sawTrailer = true
            case 0x21:
                guard let label = scanner.byte(at: position + 1) else {
                    stop(id, "Cut off", at: start, "An extension is 0x21 and a label, and the file ends after the 0x21.", "The file ends inside an extension at \(at).")
                    break
                }
                let sub = subBlocks(scanner, from: position + 2, total: total)
                let end = sub.end
                let name: String
                var value: String?
                var note: String?
                switch label {
                case 0xF9:
                    name = "Graphic control extension"
                    note = "How the next image is shown: how long, whether a colour is transparent, and what to do with it afterwards."
                    if sub.sizes.first == 4, let delay = scanner.bytes(at: position + 4, count: 4).count == 4 ? scanner.bytes(at: position + 4, count: 4) : nil {
                        let centis = Int(delay[0]) | Int(delay[1]) << 8
                        value = "\(centis * 10) ms"
                        frameDelays += 1
                    }
                case 0xFE:
                    name = "Comment extension"
                    value = FieldText.ascii(ArraySlice(scanner.bytes(at: position + 3, count: Int(min(sub.sizes.first ?? 0, 40)))), limit: 40)
                    note = "Text for people; readers ignore it."
                case 0x01:
                    name = "Plain text extension"
                    note = "Text to draw on the canvas. Almost nothing supports it."
                case 0xFF:
                    name = "Application extension"
                    let ident = String(decoding: scanner.bytes(at: position + 3, count: Int(min(sub.sizes.first ?? 0, 11))).map(HexGeometry.textByte), as: UTF8.self)
                    value = ident
                    if ident.hasPrefix("NETSCAPE2.0"), sub.sizes.count >= 2 {
                        let data = scanner.bytes(at: position + 3 + 12, count: 3)
                        if data.count == 3, data[0] == 1 {
                            let count = Int(data[1]) | Int(data[2]) << 8
                            loops = count == 0 ? "loops forever" : "loops \(count) times"
                            value = "NETSCAPE2.0 · " + loops!
                        }
                    }
                    note = "Data for one program, named by its first sub-block. NETSCAPE2.0 holds how many times an animation repeats."
                default:
                    name = "Extension \(ByteRadix.hex.cell(label))"
                }
                outcome.roots.append(FieldNode(id: id, name: name, offset: start, length: end - start, kind: .container, value: value, note: note,
                                               children: .deferred(DeferredChildren {
                    extensionChildren(id: id, source: source, start: start, label: label, end: end, sizes: sub.sizes)
                })))
                position = end
                if !sub.complete { stopped = true; problems.append("The extension at \(at) does not end before the file does."); break }
            case 0x2C:
                guard position + 10 <= total else {
                    stop(id, "Cut off", at: start, "An image descriptor is ten bytes and the file ends before them.", "The file ends inside an image descriptor at \(at).")
                    break
                }
                let descriptor = ByteWindow(source: source, at: position, count: 10)
                let packed = descriptor.u8(position + 9) ?? 0
                var cursor = position + 10
                var local: Int64 = 0
                if packed & 0x80 != 0 { local = min(tableSize(UInt64(packed), shift: 0), max(0, total - cursor)); cursor += local }
                guard let minCode = scanner.byte(at: cursor) else {
                    stop(id, "Cut off", at: start, "The image's data begins with a code size byte, and the file ends first.", "The file ends in the middle of image \(images + 1) at \(at).")
                    break
                }
                let data = subBlocks(scanner, from: cursor + 1, total: total)
                images += 1
                let imageNumber = images
                let w = UInt64(descriptor.u16(position + 5, .little) ?? 0)
                let h = UInt64(descriptor.u16(position + 7, .little) ?? 0)
                let x = descriptor.u16(position + 1, .little) ?? 0
                let y = descriptor.u16(position + 3, .little) ?? 0
                let end = data.end
                outcome.roots.append(FieldNode(
                    id: id, name: "Image \(imageNumber)", offset: start, length: end - start, kind: data.complete ? .container : .problem,
                    value: "\(w) × \(h) at (\(x), \(y)) · \(FieldText.bytes(data.bytes)) compressed",
                    note: "One picture: where it goes on the canvas, its own colours if it has them, and its pixels compressed with LZW.",
                    children: .deferred(DeferredChildren {
                        imageChildren(id: id, source: source, start: start, localTable: local, minCodeOffset: cursor, end: end, data: data)
                    })))
                position = end
                if !data.complete { stopped = true; problems.append("The data of image \(imageNumber) does not end before the file does."); break }
            default:
                stop(id, "Not a block", at: start, "A block begins with 0x21 (an extension), 0x2C (an image) or 0x3B (the end), and this byte is none of them.",
                     "At \(at) there should be a block and there is not: the file is damaged or cut.")
            }
            if sawTrailer || stopped { break }
        }

        if sawTrailer, position < total {
            outcome.roots.append(FieldNode(id: "gif/after", name: "Data after the trailer", offset: position, length: total - position, kind: .bytes,
                                           value: FieldText.bytes(total - position), note: "Readers stop at the trailer."))
        } else if !sawTrailer, !stopped {
            problems.append("There is no trailer, so the file may be cut short.")
        }
        outcome.problems = Array(problems.prefix(20))
        var summary = "GIF\(version), \(width) × \(height), \(images) \(images == 1 ? "image" : "images")"
        if let loops { summary += ", " + loops }
        outcome.summary = summary
        return outcome
    }

    private static func window8(_ window: ByteWindow, _ at: Int64) -> UInt8 { window.u8(at) ?? 0 }

    /// A run of sub-blocks (a length byte and that many bytes, until a length of 0): where it ends, the length of each, the data total.
    private struct SubBlocks {
        var end: Int64
        var sizes: [Int64]
        var bytes: Int64
        var complete: Bool
    }

    private static func subBlocks(_ scanner: SourceScanner, from: Int64, total: Int64) -> SubBlocks {
        var position = from
        var sizes: [Int64] = []
        var bytes: Int64 = 0
        while true {
            guard let size = scanner.byte(at: position) else { return SubBlocks(end: min(position, total), sizes: sizes, bytes: bytes, complete: false) }
            position += 1
            if size == 0 { return SubBlocks(end: position, sizes: sizes, bytes: bytes, complete: true) }
            if sizes.count < 4096 { sizes.append(Int64(size)) }
            bytes += Int64(size)
            position += Int64(size)
            if position > total { return SubBlocks(end: total, sizes: sizes, bytes: bytes, complete: false) }
        }
    }

    private static func extensionChildren(id: String, source: ByteSource, start: Int64, label: UInt8, end: Int64, sizes: [Int64]) -> [FieldNode] {
        let window = ByteWindow(source: source, at: start, count: Int(min(end - start, 4096)))
        var list = FieldList(idPrefix: id, window: window, endianness: .little)
        list.bytes("Introducer", at: start, length: 1, kind: .magic, value: "21")
        list.uint("Label", at: start + 1, size: 1, value: { FieldText.hexNumber($0, size: 1) })
        var at = start + 2
        for (number, size) in sizes.enumerated() where at + 1 + size <= end {
            let blockStart = at
            list.group("Sub-block \(number + 1)", at: blockStart, length: 1 + size, value: FieldText.bytes(size)) { f in
                f.uint("Length", at: blockStart, size: 1)
                if label == 0xF9, number == 0, size == 4 {
                    f.bits("Disposal method", at: blockStart + 1, size: 1, shift: 2, width: 3, value: { raw in
                        let names = ["0 · unspecified", "1 · leave in place", "2 · restore to background", "3 · restore to previous"]
                        return raw < 4 ? names[Int(raw)] : "\(raw)"
                    })
                    f.bits("User input expected", at: blockStart + 1, size: 1, shift: 1, width: 1)
                    f.bits("Transparent colour", at: blockStart + 1, size: 1, shift: 0, width: 1, value: { $0 == 1 ? "1 · yes" : "0 · no" })
                    f.uint("Delay", at: blockStart + 2, size: 2, value: { "\($0) hundredths of a second · \($0 * 10) ms" })
                    f.uint("Transparent colour index", at: blockStart + 4, size: 1)
                } else if label == 0xFE {
                    f.text("Text", at: blockStart + 1, length: size)
                } else {
                    f.bytes("Data", at: blockStart + 1, length: size)
                }
            }
            at += 1 + size
        }
        if at < end { list.bytes("Terminator", at: end - 1, length: 1, kind: .padding, value: "00") }
        return list.nodes
    }

    private static func imageChildren(id: String, source: ByteSource, start: Int64, localTable: Int64, minCodeOffset: Int64, end: Int64, data: SubBlocks) -> [FieldNode] {
        let window = ByteWindow(source: source, at: start, count: 16)
        var list = FieldList(idPrefix: id, window: window, endianness: .little)
        list.bytes("Separator", at: start, length: 1, kind: .magic, value: "2C")
        list.uint("Left", at: start + 1, size: 2, value: { "\($0) pixels" })
        list.uint("Top", at: start + 3, size: 2, value: { "\($0) pixels" })
        list.uint("Width", at: start + 5, size: 2, value: { "\($0) pixels" })
        list.uint("Height", at: start + 7, size: 2, value: { "\($0) pixels" })
        list.bits("Local colour table", at: start + 9, size: 1, shift: 7, width: 1, value: { $0 == 1 ? "1 · present" : "0 · none" })
        list.bits("Interlaced", at: start + 9, size: 1, shift: 6, width: 1, value: { $0 == 1 ? "1 · rows in four passes" : "0 · rows in order" })
        list.bits("Sorted", at: start + 9, size: 1, shift: 5, width: 1)
        list.bits("Table size", at: start + 9, size: 1, shift: 0, width: 3)
        var nodes = list.nodes
        if localTable > 0 {
            nodes.append(FieldNode(id: id + "/colours", name: "Local colour table", offset: start + 10, length: localTable, kind: .bytes, value: "\(localTable / 3) colours"))
        }
        nodes.append(FieldNode(id: id + "/code-size", name: "LZW minimum code size", offset: minCodeOffset, length: 1, kind: .integer,
                               value: ByteWindow(source: source, at: minCodeOffset, count: 1).u8(minCodeOffset).map { "\($0) bits" }))
        nodes.append(FieldNode(id: id + "/data", name: "Image data", offset: minCodeOffset + 1, length: max(0, end - minCodeOffset - 1), kind: .bytes,
                               value: "\(data.sizes.count)\(data.sizes.count >= 4096 ? "+" : "") sub-blocks · \(FieldText.bytes(data.bytes))",
                               note: "The pixels, compressed with LZW, in sub-blocks of up to 255 bytes each, each led by its length and the last followed by a 0."))
        return nodes
    }
}
