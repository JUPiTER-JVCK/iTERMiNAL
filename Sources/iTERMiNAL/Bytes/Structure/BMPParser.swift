import Foundation

/// A BMP (Windows bitmap) file taken apart: a 14-byte file header, a DIB header (of one of several sizes, which
/// say how much it can describe), optional colour masks, a colour table, and the pixels.
enum BMPParser: FormatParser {
    static let identity = FormatIdentity(id: "bmp", name: "a BMP image", detail: "Windows bitmap", hasParser: true)

    static let headerSizes: Set<UInt32> = [12, 40, 52, 56, 64, 108, 124]

    static func matches(head: [UInt8], length: Int64) -> Bool {
        guard head.count >= 18, head[0] == 0x42, head[1] == 0x4D, head[6..<10].allSatisfy({ $0 == 0 }) else { return false }
        let size = UInt32(head[14]) | UInt32(head[15]) << 8 | UInt32(head[16]) << 16 | UInt32(head[17]) << 24
        return headerSizes.contains(size)
    }

    static func compressionName(_ raw: UInt64) -> String {
        switch raw {
        case 0: return "0 · none (RGB)"
        case 1: return "1 · RLE, 8 bits"
        case 2: return "2 · RLE, 4 bits"
        case 3: return "3 · bit fields (masks follow)"
        case 4: return "4 · JPEG"
        case 5: return "5 · PNG"
        case 6: return "6 · bit fields with alpha"
        default: return "\(raw)"
        }
    }

    /// What the DIB header holds: its fields, from `at`, for a header of `size` bytes. Returns the numbers the rest of the file needs.
    @discardableResult
    static func dibFields(_ f: inout FieldList, at: Int64, size: UInt64) -> (width: Int64, height: Int64, bpp: UInt64, compression: UInt64, imageSize: UInt64, colours: UInt64)? {
        f.uint("Header size", at: at, size: 4, value: { "\($0) bytes · " + headerName($0) })
        if size == 12 {
            let w = f.uint("Width", at: at + 4, size: 2, value: { "\($0) pixels" }) ?? 0
            let h = f.uint("Height", at: at + 6, size: 2, value: { "\($0) pixels" }) ?? 0
            f.uint("Colour planes", at: at + 8, size: 2, note: { _ in "Always 1." })
            let bpp = f.uint("Bits per pixel", at: at + 10, size: 2) ?? 0
            return (Int64(w), Int64(h), bpp, 0, 0, 0)
        }
        guard size >= 40 else { return nil }
        let w = Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: f.uint("Width", at: at + 4, size: 4, value: { "\(Int32(bitPattern: UInt32(truncatingIfNeeded: $0))) pixels" }) ?? 0)))
        let hRaw = Int32(bitPattern: UInt32(truncatingIfNeeded: f.uint("Height", at: at + 8, size: 4, value: { raw in
            let v = Int32(bitPattern: UInt32(truncatingIfNeeded: raw))
            return v < 0 ? "\(v) · \(-Int64(v)) pixels, rows from the top down" : "\(v) pixels, rows from the bottom up"
        }) ?? 0))
        f.uint("Colour planes", at: at + 12, size: 2, note: { _ in "Always 1." })
        let bpp = f.uint("Bits per pixel", at: at + 14, size: 2) ?? 0
        let compression = f.uint("Compression", at: at + 16, size: 4, value: { compressionName($0) }) ?? 0
        let imageSize = f.uint("Image size", at: at + 20, size: 4, value: { $0 == 0 ? "0 · not given" : FieldText.bytes(Int64($0)) }) ?? 0
        f.uint("Horizontal resolution", at: at + 24, size: 4, value: { "\(Int32(bitPattern: UInt32(truncatingIfNeeded: $0))) pixels per metre" })
        f.uint("Vertical resolution", at: at + 28, size: 4, value: { "\(Int32(bitPattern: UInt32(truncatingIfNeeded: $0))) pixels per metre" })
        let colours = f.uint("Colours used", at: at + 32, size: 4, value: { $0 == 0 ? "0 · all that the bits per pixel allow" : "\($0)" }) ?? 0
        f.uint("Important colours", at: at + 36, size: 4, value: { $0 == 0 ? "0 · all" : "\($0)" })
        if size >= 52 {
            f.uint("Red mask", at: at + 40, size: 4, kind: .flags, value: { FieldText.hexNumber($0, size: 4) })
            f.uint("Green mask", at: at + 44, size: 4, kind: .flags, value: { FieldText.hexNumber($0, size: 4) })
            f.uint("Blue mask", at: at + 48, size: 4, kind: .flags, value: { FieldText.hexNumber($0, size: 4) })
        }
        if size >= 56 { f.uint("Alpha mask", at: at + 52, size: 4, kind: .flags, value: { FieldText.hexNumber($0, size: 4) }) }
        if size >= 108 {
            f.bytes("Colour space type", at: at + 56, length: 4, kind: .text, value: nil, note: "\"sRGB\" is stored as the number 0x73524742, read backwards: the bytes spell BGRs.")
            f.bytes("Colour space endpoints", at: at + 60, length: 36)
            f.uint("Red gamma", at: at + 96, size: 4)
            f.uint("Green gamma", at: at + 100, size: 4)
            f.uint("Blue gamma", at: at + 104, size: 4)
        }
        if size >= 124 {
            f.uint("Rendering intent", at: at + 108, size: 4)
            f.uint("Profile data", at: at + 112, size: 4)
            f.uint("Profile size", at: at + 116, size: 4)
            f.bytes("Reserved", at: at + 120, length: 4, kind: .padding)
        }
        return (w, Int64(hRaw), bpp, compression, imageSize, colours)
    }

    private static func headerName(_ size: UInt64) -> String {
        switch size {
        case 12: return "BITMAPCOREHEADER (OS/2)"
        case 40: return "BITMAPINFOHEADER"
        case 52: return "BITMAPV2INFOHEADER"
        case 56: return "BITMAPV3INFOHEADER"
        case 64: return "OS/2 2.x header"
        case 108: return "BITMAPV4HEADER"
        case 124: return "BITMAPV5HEADER"
        default: return "an unknown size"
        }
    }

    static func parse(_ source: ByteSource, context: ParseContext) -> ParseOutcome {
        var outcome = ParseOutcome()
        let total = source.count
        var problems: [String] = []
        let window = ByteWindow(source: source, at: 0, count: 256)
        var list = FieldList(idPrefix: "bmp", window: window, endianness: .little)
        var declaredSize: UInt64 = 0
        var dataOffset: UInt64 = 0
        list.group("File header", at: 0, length: 14, note: "Says how big the file is and where the pixels begin.") { f in
            f.text("Signature", at: 0, length: 2, note: "BM.")
            declaredSize = f.uint("File size", at: 2, size: 4, value: { FieldText.bytes(Int64($0)) }) ?? 0
            f.bytes("Reserved", at: 6, length: 4, kind: .padding)
            dataOffset = f.uint("Pixel data offset", at: 10, size: 4) ?? 0
            f.groupValue = "BM"
        }
        let dibSize = UInt64(window.u32(14, .little) ?? 0)
        var facts: (width: Int64, height: Int64, bpp: UInt64, compression: UInt64, imageSize: UInt64, colours: UInt64)?
        list.group("DIB header", at: 14, length: Int64(dibSize), note: "The picture's size, depth and colour layout.") { f in
            facts = dibFields(&f, at: 14, size: dibSize)
            if let facts { f.groupValue = "\(facts.width) × \(abs(facts.height)), \(facts.bpp)-bit" }
        }
        outcome.roots.append(contentsOf: list.nodes)
        guard let facts, !list.truncated else {
            outcome.problems = ["The file ends inside its headers."]
            outcome.summary = "BMP image, cut off in its header"
            return outcome
        }
        var position = 14 + Int64(dibSize)
        if dibSize == 40, facts.compression == 3 || facts.compression == 6 {
            let length = facts.compression == 3 ? 12 : 16
            outcome.roots.append(FieldNode(id: "bmp/masks", name: "Colour masks", offset: position, length: min(Int64(length), total - position), kind: .flags,
                                           value: "\(length / 4) masks", note: "Which bits of each pixel are red, green, blue (and alpha)."))
            position += Int64(length)
        }
        let entry: Int64 = dibSize == 12 ? 3 : 4
        let count: Int64 = facts.colours > 0 ? Int64(min(facts.colours, 65_536)) : (facts.bpp <= 8 && facts.bpp > 0 ? Int64(1) << Int64(facts.bpp) : 0)
        if count > 0, position < Int64(dataOffset) || position < total {
            let length = min(count * entry, max(0, min(total, Int64(dataOffset)) - position))
            if length > 0 {
                outcome.roots.append(FieldNode(id: "bmp/colours", name: "Colour table", offset: position, length: length, kind: .bytes,
                                               value: "\(count) colours", note: "Each pixel is a number that picks one of these. \(entry) bytes each: blue, green, red\(entry == 4 ? " and a spare" : "")."))
                position += length
            }
        }
        let offset = Int64(clamping: dataOffset)
        if offset > position, offset <= total {
            outcome.roots.append(FieldNode(id: "bmp/gap", name: "Gap", offset: position, length: offset - position, kind: .padding, value: FieldText.bytes(offset - position),
                                           note: "Unused bytes between the headers and the pixels."))
        } else if offset < position {
            problems.append("The pixel data is said to begin at \(offset), inside the headers, which run to \(position).")
        }
        if offset > total {
            problems.append("The pixel data is said to begin at \(offset), past the end of the file.")
        } else {
            let start = max(offset, min(position, total))
            let available = total - start
            let rowBytes = ((facts.width * Int64(facts.bpp) + 31) / 32) * 4
            let expected = facts.compression == 0 || facts.compression == 3 || facts.compression == 6 ? rowBytes * abs(facts.height) : Int64(facts.imageSize)
            var length = available
            var note = "The pixels, \(facts.height < 0 ? "top row first" : "bottom row first"), each row padded to a multiple of four bytes."
            if expected > 0, expected < available {
                length = expected
            } else if expected > available {
                note += " The headers say there should be \(FieldText.bytes(expected)) and the file ends after \(FieldText.bytes(available))."
                problems.append("The pixels are cut short: \(FieldText.bytes(expected)) are described and \(FieldText.bytes(available)) are in the file.")
            }
            outcome.roots.append(FieldNode(id: "bmp/pixels", name: "Pixel data", offset: start, length: length, kind: expected > available ? .problem : .bytes,
                                           value: FieldText.bytes(length), note: note))
            if length < available {
                outcome.roots.append(FieldNode(id: "bmp/after", name: "Data after the pixels", offset: start + length, length: available - length, kind: .bytes,
                                               value: FieldText.bytes(available - length)))
            }
        }
        if declaredSize != UInt64(total) {
            problems.append("The header says the file is \(FieldText.bytes(Int64(clamping: declaredSize))) and it is \(FieldText.bytes(total)).")
        }
        outcome.problems = Array(problems.prefix(20))
        outcome.summary = "BMP image, \(facts.width) × \(abs(facts.height)), \(facts.bpp)-bit, " + (facts.compression == 0 ? "uncompressed" : compressionName(facts.compression).dropFirst(4))
        return outcome
    }
}
