import Foundation

/// A bare JPEG XL codestream: the two signature bytes FF 0A and then a header that begins with the
/// picture's size, packed into bits. (A JPEG XL file in its box container is read by `MP4Parser`.)
enum JXLParser: FormatParser {
    static let identity = FormatIdentity(id: "jxl", name: "a JPEG XL image", detail: "a bare codestream", hasParser: true)

    static func matches(head: [UInt8], length: Int64) -> Bool {
        head.count >= 2 && head[0] == 0xFF && head[1] == 0x0A
    }

    /// Reads bits least-significant first, the order JPEG XL packs them in.
    private struct BitReader {
        let bytes: [UInt8]
        var position = 0

        mutating func read(_ count: Int) -> UInt64? {
            guard position + count <= bytes.count * 8 else { return nil }
            var value: UInt64 = 0
            for index in 0..<count {
                let bit = position + index
                value |= UInt64((bytes[bit >> 3] >> UInt8(bit & 7)) & 1) << UInt64(index)
            }
            position += count
            return value
        }

        /// A number that is one of four widths, chosen by two bits ahead of it, plus one.
        mutating func size() -> UInt64? {
            guard let selector = read(2) else { return nil }
            let widths = [9, 13, 18, 30]
            guard let raw = read(widths[Int(selector)]) else { return nil }
            return raw + 1
        }
    }

    /// The ratios the size header can name for the width over the height.
    private static let ratios: [(Int, Int)] = [(1, 1), (12, 10), (4, 3), (3, 2), (16, 9), (5, 4), (2, 1)]

    /// Width and height from the bytes after the signature, and how many bits the size took.
    static func dimensions(_ bytes: [UInt8]) -> (width: UInt64, height: UInt64, bits: Int)? {
        var reader = BitReader(bytes: bytes)
        guard let small = reader.read(1) else { return nil }
        var height: UInt64
        var width: UInt64
        if small == 1 {
            guard let h = reader.read(5), let ratio = reader.read(3) else { return nil }
            height = (h + 1) * 8
            if ratio == 0 {
                guard let w = reader.read(5) else { return nil }
                width = (w + 1) * 8
            } else {
                width = height * UInt64(ratios[Int(ratio) - 1].0) / UInt64(ratios[Int(ratio) - 1].1)
            }
        } else {
            guard let h = reader.size(), let ratio = reader.read(3) else { return nil }
            height = h
            if ratio == 0 {
                guard let w = reader.size() else { return nil }
                width = w
            } else {
                width = height * UInt64(ratios[Int(ratio) - 1].0) / UInt64(ratios[Int(ratio) - 1].1)
            }
        }
        return (width, height, reader.position)
    }

    static func parse(_ source: ByteSource, context: ParseContext) -> ParseOutcome {
        var outcome = ParseOutcome()
        let total = source.count
        let window = ByteWindow(source: source, at: 0, count: Int(min(total, 64)))
        var list = FieldList(idPrefix: "jxl", window: window)
        list.bytes("Signature", at: 0, length: 2, kind: .magic, value: "FF 0A",
                   note: "Marks a bare JPEG XL codestream. In a file with the box container, the codestream is inside a jxlc box.")
        let head = window.slice(2, Int(min(total - 2, 62))).map(Array.init) ?? []
        if let size = dimensions(head) {
            let bytes = Int64((size.bits + 7) / 8)
            list.bytes("Size header", at: 2, length: bytes, kind: .bytes, value: "\(size.width) × \(size.height)",
                       note: "The picture's height, then its width, packed into \(size.bits) bits, lowest bit first: a flag for a small picture (sides in whole eights, up to 256), or a number chosen from four widths. A ratio code can stand for the width.")
            outcome.summary = "JPEG XL codestream, \(size.width) × \(size.height), \(FieldText.bytes(total))"
        } else {
            list.bytes("Size header", at: 2, length: max(0, min(total - 2, 62)), kind: .problem, note: "Cut off before the size is complete.")
            outcome.summary = "JPEG XL codestream, \(FieldText.bytes(total))"
            outcome.problems.append("The file ends before the picture's size.")
        }
        let used = list.nodes.last.map { $0.end } ?? 2
        outcome.roots = list.nodes
        if used < total {
            outcome.roots.append(FieldNode(id: "jxl/codestream", name: "Codestream", offset: used, length: total - used, kind: .bytes,
                                           value: FieldText.bytes(total - used),
                                           note: "The rest of the header (colour, bit depth, extra channels) and the compressed frames. Not read."))
        }
        return outcome
    }
}
