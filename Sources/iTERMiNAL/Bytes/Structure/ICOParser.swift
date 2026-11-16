import Foundation

/// A Windows icon (.ico) or cursor (.cur): a directory of images, each a PNG or a DIB of its own.
enum ICOParser: FormatParser {
    static let identity = FormatIdentity(id: "ico", name: "a Windows icon", detail: "ICO and CUR", hasParser: true)

    static func matches(head: [UInt8], length: Int64) -> Bool {
        guard head.count >= 6, head[0] == 0, head[1] == 0, head[2] == 1 || head[2] == 2, head[3] == 0, head[5] == 0, head[4] >= 1 else { return false }
        return length >= 6 + 16 * Int64(head[4])
    }

    static func parse(_ source: ByteSource, context: ParseContext) -> ParseOutcome {
        var outcome = ParseOutcome()
        let total = source.count
        var problems: [String] = []
        let head = ByteWindow(source: source, at: 0, count: 6 + 16 * 256)
        var list = FieldList(idPrefix: "ico", window: head, endianness: .little)
        var kind: UInt64 = 1
        var count: UInt64 = 0
        list.group("Directory", at: 0, length: 6, note: "What kind of file this is and how many images it holds.") { f in
            f.uint("Reserved", at: 0, size: 2, kind: .padding)
            kind = f.uint("Type", at: 2, size: 2, value: { $0 == 1 ? "1 · icon" : ($0 == 2 ? "2 · cursor" : "\($0)") }) ?? 1
            count = f.uint("Image count", at: 4, size: 2) ?? 0
            f.groupValue = "\(count) \(count == 1 ? "image" : "images")"
        }
        var images: [(offset: Int64, size: Int64)] = []
        let shown = min(Int64(count), 256)
        for number in 0..<shown {
            let at = 6 + number * 16
            list.group("Entry \(number + 1)", at: at, length: 16) { f in
                let w = f.uint("Width", at: at, size: 1, value: { $0 == 0 ? "0 · 256 pixels" : "\($0) pixels" }) ?? 0
                let h = f.uint("Height", at: at + 1, size: 1, value: { $0 == 0 ? "0 · 256 pixels" : "\($0) pixels" }) ?? 0
                f.uint("Colours", at: at + 2, size: 1, value: { $0 == 0 ? "0 · more than 255 or not a palette" : "\($0)" })
                f.uint("Reserved", at: at + 3, size: 1, kind: .padding)
                let planes = f.uint(kind == 2 ? "Hotspot x" : "Colour planes", at: at + 4, size: 2) ?? 0
                let bits = f.uint(kind == 2 ? "Hotspot y" : "Bits per pixel", at: at + 6, size: 2) ?? 0
                let size = f.uint("Image size", at: at + 8, size: 4, value: { FieldText.bytes(Int64($0)) }) ?? 0
                let offset = f.uint("Image offset", at: at + 12, size: 4) ?? 0
                images.append((Int64(offset), Int64(size)))
                f.groupValue = "\(w == 0 ? 256 : w) × \(h == 0 ? 256 : h), \(kind == 2 ? "hotspot \(planes), \(bits)" : "\(bits)-bit"), \(FieldText.bytes(Int64(size)))"
            }
        }
        outcome.roots.append(contentsOf: list.nodes)
        guard !list.truncated else {
            outcome.problems = ["The file ends inside its directory."]
            outcome.summary = "\(kind == 2 ? "Cursor" : "Icon"), cut off in its directory"
            return outcome
        }
        var imageNodes: [FieldNode] = []
        for (number, image) in images.enumerated() {
            let id = "ico/image\(number + 1)"
            guard image.offset >= 6 + 16 * Int64(count), image.offset < total else {
                problems.append("Image \(number + 1) is said to be at \(image.offset), which is not inside the file after the directory.")
                continue
            }
            let length = min(image.size, total - image.offset)
            let head = ByteWindow(source: source, at: image.offset, count: 8)
            let isPNG = length >= 8 && (head.slice(image.offset, 8).map { Array($0) == PNGParser.signature } ?? false)
            if length < image.size { problems.append("Image \(number + 1) is cut off: \(FieldText.bytes(image.size)) are described and \(FieldText.bytes(length)) are there.") }
            let start = image.offset
            imageNodes.append(FieldNode(
                id: id, name: "Image \(number + 1)", offset: start, length: length, kind: length < image.size ? .problem : .container,
                value: (isPNG ? "PNG" : "DIB") + " · " + FieldText.bytes(length),
                note: isPNG ? "A whole PNG file, which a reader may take apart as one." : "A bitmap without the 14-byte file header: a DIB header, the colour table, the pixels (XOR) and then a 1-bit mask (AND). Its height counts both halves.",
                children: .deferred(DeferredChildren {
                    var f = FieldList(idPrefix: id, window: ByteWindow(source: source, at: start, count: 200), endianness: .little)
                    if isPNG {
                        f.bytes("PNG signature", at: start, length: 8, kind: .magic)
                        f.bytes("PNG chunks", at: start + 8, length: length - 8, note: "Open this file in the Structure view by itself to read its chunks.")
                    } else {
                        let size = UInt64(f.window.u32(start, .little) ?? 0)
                        if BMPParser.headerSizes.contains(UInt32(truncatingIfNeeded: size)), Int64(size) <= length {
                            f.group("DIB header", at: start, length: Int64(size)) { g in
                                BMPParser.dibFields(&g, at: start, size: size)
                            }
                            if length > Int64(size) { f.bytes("Colours and pixels", at: start + Int64(size), length: length - Int64(size)) }
                        } else if length > 0 {
                            f.bytes("Data", at: start, length: length, kind: .problem, note: "This is neither a PNG nor a bitmap header of a known size.")
                        }
                    }
                    return f.nodes
                })))
        }
        outcome.roots.append(contentsOf: imageNodes.sorted { $0.offset < $1.offset })
        outcome.problems = Array(problems.prefix(20))
        outcome.summary = "\(kind == 2 ? "Cursor" : "Icon"), \(count) \(count == 1 ? "image" : "images")"
        return outcome
    }
}
