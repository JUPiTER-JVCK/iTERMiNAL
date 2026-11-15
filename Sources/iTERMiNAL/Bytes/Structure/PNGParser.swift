import Foundation

/// A PNG file taken apart: the signature, then chunks of length, type, data and CRC.
///
/// Every CRC is checked, so a file that was edited, cut or damaged says so at the chunk
/// it happened in. What is inside a chunk is made when the chunk is opened. The data
/// of the biggest chunks (the image itself) is not read to be shown, only to be
/// checksummed, a megabyte at a time, and only up to a total budget.
enum PNGParser: FormatParser {
    static let identity = FormatIdentity(id: "png", name: "a PNG image", detail: "Portable Network Graphics", hasParser: true)

    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// The most chunk data read in all, to check CRCs. A chunk past this is listed and
    /// not checked.
    static let crcBudget: Int64 = 512 * 1024 * 1024

    static func matches(head: [UInt8], length: Int64) -> Bool {
        head.count >= 8 && Array(head[0..<8]) == signature
    }

    private enum CRCState {
        case matches(UInt32)
        case differs(stored: UInt32, computed: UInt32)
        case unchecked(stored: UInt32)
    }

    static func parse(_ source: ByteSource, context: ParseContext) -> ParseOutcome {
        var outcome = ParseOutcome()
        let total = source.count

        outcome.roots.append(FieldNode(
            id: "png/signature", name: "Signature", offset: 0, length: 8, kind: .magic,
            value: "89 50 4E 47 0D 0A 1A 0A",
            note: "The eight bytes every PNG begins with. The first is not text, so no editor mistakes the file for text; the CR LF, Ctrl-Z and LF catch a transfer that rewrote the line endings."))

        var position: Int64 = 8
        var index = 0
        var colourType: UInt8?
        var summaryHeader: String?
        var sawIEND = false
        var sawIDAT = false
        var budget = crcBudget
        var problems: [String] = []
        /// Set when the walk stopped for a reason of its own, so "no IEND" is not said as well.
        var stoppedEarly = false

        while position < total {
            if index >= context.maxRecords {
                stoppedEarly = true
                outcome.listingLimit = "The first \(context.maxRecords) chunks are listed; the rest of the file is in the dump."
                outcome.roots.append(FieldNode(id: "png/more", name: "More chunks", offset: position, length: total - position,
                                               kind: .bytes, value: "not listed",
                                               note: "Listing stops after \(context.maxRecords) chunks."))
                break
            }
            if context.isCancelled() {
                stoppedEarly = true
                problems.append("Stopped before the end of the file.")
                break
            }
            let remaining = total - position
            let header = ByteWindow(source: source, at: position, count: 8)
            guard remaining >= 8, header.bytes.count == 8 else {
                stoppedEarly = true
                outcome.roots.append(FieldNode(
                    id: "png/cut", name: "Cut off", offset: position, length: remaining, kind: .problem,
                    value: "\(FieldText.bytes(remaining)) left",
                    note: "A chunk starts with eight bytes (length and type) and the file ends before they do."))
                problems.append("The file ends in the middle of a chunk header, at \(FieldText.hexNumber(UInt64(position), size: 1)).")
                break
            }
            // A constant, not `position`, which the loop moves on: the closures below run later.
            let start = position
            let declared = Int64(header.u32(position, .big) ?? 0)
            let typeBytes = Array(header.bytes[4..<8])
            let type = String(decoding: typeBytes.map(HexGeometry.textByte), as: UTF8.self)
            let fullSize = 12 + declared
            let fits = fullSize <= remaining
            let id = "png/chunk\(index + 1)-\(type)"
            index += 1

            if index == 1, type != "IHDR" {
                problems.append("The first chunk is \(type), and a PNG must start with IHDR.")
            }

            if !fits {
                stoppedEarly = true
                let held = remaining
                let dataHeld = max(0, held - 8)
                let note = "The chunk says it has \(FieldText.bytes(declared)) of data, but the file ends after \(FieldText.bytes(dataHeld)) of it."
                problems.append("\(type) at \(FieldText.hexNumber(UInt64(position), size: 1)) is cut off: \(note)")
                outcome.roots.append(FieldNode(
                    id: id, name: type, offset: position, length: held, kind: .problem,
                    value: "cut off", note: note,
                    children: .deferred(DeferredChildren {
                        truncatedChunkChildren(id: id, source: source, position: start, type: type,
                                               typeBytes: typeBytes, declared: declared, held: held)
                    })))
                break
            }

            // The checksum, over the type and the data.
            let storedWindow = ByteWindow(source: source, at: position + 8 + declared, count: 4)
            let stored = storedWindow.u32(position + 8 + declared, .big) ?? 0
            let state = checkCRC(source: source, from: position + 4, count: 4 + declared, stored: stored,
                                 budget: &budget, context: context)

            let isIDAT = type == "IDAT"
            let firstIDAT = isIDAT && !sawIDAT
            if isIDAT { sawIDAT = true }

            // IHDR is decoded now: the summary and the colour type of the chunks that follow need it.
            var shortValue = ""
            if type == "IHDR", declared >= 13 {
                let w = ByteWindow(source: source, at: position + 8, count: 13)
                if let width = w.u32(position + 8, .big), let height = w.u32(position + 12, .big),
                   let depth = w.u8(position + 16), let colour = w.u8(position + 17) {
                    colourType = colour
                    shortValue = "\(width) × \(height), \(depth)-bit \(colourShort(colour)) · "
                    summaryHeader = "\(width) × \(height) pixels, \(depth)-bit \(colourShort(colour))"
                }
            }
            let crcWords: String
            switch state {
            case .matches: crcWords = "CRC ok"
            case .differs(_, let computed):
                crcWords = "CRC wrong"
                problems.append("\(type) at \(FieldText.hexNumber(UInt64(position), size: 1)) has the wrong CRC (the file says \(FieldText.hexNumber(UInt64(stored), size: 4)), its bytes add up to \(FieldText.hexNumber(UInt64(computed), size: 4))): it was damaged or edited.")
            case .unchecked: crcWords = "CRC not checked"
            }
            let title = chunkTitles[type].map { "\($0) · " } ?? ""
            let capturedColour = colourType
            let capturedState = state
            let note = classification(typeBytes) + (chunkNotes[type].map { " " + $0 } ?? "")
            let isProblem: Bool
            if case .differs = state { isProblem = true } else { isProblem = false }

            outcome.roots.append(FieldNode(
                id: id, name: type, offset: position, length: fullSize, kind: isProblem ? .problem : .container,
                value: "\(title)\(shortValue)\(FieldText.bytes(declared)) · \(crcWords)", note: note,
                children: .deferred(DeferredChildren {
                    chunkChildren(id: id, source: source, position: start, type: type, typeBytes: typeBytes,
                                  declared: declared, firstIDAT: firstIDAT, colourType: capturedColour,
                                  crc: capturedState)
                })))

            position += fullSize
            if type == "IEND" {
                sawIEND = true
                break
            }
        }

        if sawIEND, position < total {
            let rest = total - position
            let preview = ByteWindow(source: source, at: position, count: 16)
            outcome.roots.append(FieldNode(
                id: "png/trailer", name: "Data after IEND", offset: position, length: rest, kind: .bytes,
                value: FieldText.hex(preview.bytes[...]),
                note: "Readers stop at IEND and ignore what follows. Some files carry more here: a thumbnail, a signature, an appended archive."))
        } else if !sawIEND, !stoppedEarly {
            problems.append("There is no IEND chunk, so the file may be cut short.")
        }

        outcome.problems = Array(problems.prefix(20))
        let chunkCount = outcome.roots.filter { $0.id.hasPrefix("png/chunk") }.count
        outcome.summary = "PNG image" + (summaryHeader.map { ", " + $0 } ?? "") + ", \(chunkCount) \(chunkCount == 1 ? "chunk" : "chunks")"
        return outcome
    }

    // MARK: CRC

    /// The CRC of `count` bytes from `start`, a megabyte at a time, if the budget has room.
    private static func checkCRC(source: ByteSource, from start: Int64, count: Int64, stored: UInt32,
                                 budget: inout Int64, context: ParseContext) -> CRCState {
        guard count <= budget else { return .unchecked(stored: stored) }
        budget -= count
        var crc = CRC32()
        var done: Int64 = 0
        while done < count {
            if context.isCancelled() { return .unchecked(stored: stored) }
            let step = Int(min(Int64(1 << 20), count - done))
            let bytes = source.read((start + done)..<(start + done + Int64(step)))
            guard bytes.count == step else { return .unchecked(stored: stored) }
            crc.update(bytes)
            done += Int64(step)
        }
        return crc.value == stored ? .matches(stored) : .differs(stored: stored, computed: crc.value)
    }

    // MARK: Inside a chunk

    private static func chunkChildren(id: String, source: ByteSource, position: Int64, type: String, typeBytes: [UInt8],
                                      declared: Int64, firstIDAT: Bool, colourType: UInt8?, crc: CRCState) -> [FieldNode] {
        var nodes: [FieldNode] = []
        nodes.append(FieldNode(id: id + "/length", name: "Length", offset: position, length: 4, kind: .integer,
                               value: FieldText.bytes(declared) + " of data",
                               note: "The size of the data alone, not counting the length, type or CRC."))
        nodes.append(FieldNode(id: id + "/type", name: "Type", offset: position + 4, length: 4, kind: .text,
                               value: "\"\(type)\"", note: classification(typeBytes)))
        nodes.append(dataNode(id: id + "/data", source: source, position: position + 8, length: declared, type: type,
                              firstIDAT: firstIDAT, colourType: colourType))
        let crcValue: String
        let crcNote: String
        switch crc {
        case .matches(let stored):
            crcValue = "\(FieldText.hexNumber(UInt64(stored), size: 4)) · matches"
            crcNote = "The CRC-32 of the type and data, which the bytes add up to."
        case .differs(let stored, let computed):
            crcValue = "\(FieldText.hexNumber(UInt64(stored), size: 4)) · wrong"
            crcNote = "The type and data add up to \(FieldText.hexNumber(UInt64(computed), size: 4)), not this. The chunk was damaged or edited."
        case .unchecked(let stored):
            crcValue = "\(FieldText.hexNumber(UInt64(stored), size: 4)) · not checked"
            crcNote = "Checking it means reading all of this chunk, and the budget for that is spent."
        }
        nodes.append(FieldNode(id: id + "/crc", name: "CRC", offset: position + 8 + declared, length: 4, kind: .checksum,
                               value: crcValue, note: crcNote))
        return nodes
    }

    /// A chunk the file ends in the middle of: its length and type, and what data there is.
    private static func truncatedChunkChildren(id: String, source: ByteSource, position: Int64, type: String,
                                               typeBytes: [UInt8], declared: Int64, held: Int64) -> [FieldNode] {
        var nodes: [FieldNode] = []
        nodes.append(FieldNode(id: id + "/length", name: "Length", offset: position, length: 4, kind: .integer,
                               value: FieldText.bytes(declared) + " of data"))
        nodes.append(FieldNode(id: id + "/type", name: "Type", offset: position + 4, length: 4, kind: .text,
                               value: "\"\(type)\"", note: classification(typeBytes)))
        let dataHeld = max(0, held - 8)
        if dataHeld > 0 {
            let preview = ByteWindow(source: source, at: position + 8, count: 16)
            nodes.append(FieldNode(id: id + "/data", name: "Data", offset: position + 8, length: dataHeld, kind: .problem,
                                   value: FieldText.hex(preview.bytes[...]),
                                   note: "Cut off: \(FieldText.bytes(declared)) were promised and the file ends after \(FieldText.bytes(dataHeld))."))
        }
        return nodes
    }

    /// The data of a chunk, with what the data says as fields where it is known.
    private static func dataNode(id: String, source: ByteSource, position: Int64, length: Int64, type: String,
                                 firstIDAT: Bool, colourType: UInt8?) -> FieldNode {
        // A big chunk (the image) is described, not read: its first kilobytes are plenty.
        let window = ByteWindow(source: source, at: position, count: Int(min(length, 65_536)))
        var list = FieldList(idPrefix: id, window: window, endianness: .big)
        let end = position + length

        switch type {
        case "IHDR":
            list.uint("Width", at: position, size: 4, value: { "\($0) pixels" }, note: { $0 == 0 ? "A width of zero is not allowed." : nil })
            list.uint("Height", at: position + 4, size: 4, value: { "\($0) pixels" }, note: { $0 == 0 ? "A height of zero is not allowed." : nil })
            list.uint("Bit depth", at: position + 8, size: 1, value: { "\($0) bits per sample" })
            list.uint("Colour type", at: position + 9, size: 1, value: { "\($0) · \(colourName($0))" },
                      note: { _ in "Which samples make a pixel: grey, red-green-blue, a palette index, with or without alpha." })
            list.uint("Compression method", at: position + 10, size: 1, value: { $0 == 0 ? "0 · deflate" : "\($0) · unknown" })
            list.uint("Filter method", at: position + 11, size: 1, value: { $0 == 0 ? "0 · adaptive filtering" : "\($0) · unknown" })
            list.uint("Interlace method", at: position + 12, size: 1, value: { $0 == 0 ? "0 · none" : ($0 == 1 ? "1 · Adam7" : "\($0) · unknown") })
            if length > 13 {
                list.bytes("Extra bytes", at: position + 13, length: length - 13, kind: .padding,
                           note: "IHDR is exactly 13 bytes; these should not be here.")
            }
        case "PLTE":
            let entries = length / 3
            let shown = min(entries, 16)
            for entry in 0..<shown {
                let at = position + entry * 3
                if let rgb = window.slice(at, 3) {
                    let colour = rgb.map { ByteRadix.hex.cell($0) }.joined()
                    list.bytes("Entry \(entry)", at: at, length: 3, value: "#" + colour)
                }
            }
            if entries > shown {
                list.bytes("More entries", at: position + shown * 3, length: (entries - shown) * 3,
                           value: "\(entries - shown) more")
            }
            if length % 3 != 0 {
                list.bytes("Stray bytes", at: position + entries * 3, length: length % 3, kind: .padding,
                           note: "A palette is whole entries of three bytes.")
            }
        case "tRNS":
            switch colourType {
            case 3?:
                list.bytes("Alpha values", at: position, length: length,
                           note: "One alpha for each of the first palette entries; the rest are opaque.")
            case 0?:
                list.uint("Transparent grey", at: position, size: 2)
            case 2?:
                list.uint("Transparent red", at: position, size: 2)
                list.uint("Transparent green", at: position + 2, size: 2)
                list.uint("Transparent blue", at: position + 4, size: 2)
            default:
                list.bytes("Data", at: position, length: length)
            }
        case "gAMA":
            list.uint("Gamma", at: position, size: 4, value: { "\(Double($0) / 100_000)" },
                      note: { _ in "Stored times 100,000. 0.45455 is the usual 1/2.2." })
        case "cHRM":
            let names = ["White point x", "White point y", "Red x", "Red y", "Green x", "Green y", "Blue x", "Blue y"]
            for (n, name) in names.enumerated() {
                list.uint(name, at: position + Int64(n) * 4, size: 4, value: { "\(Double($0) / 100_000)" })
            }
        case "sRGB":
            list.uint("Rendering intent", at: position, size: 1, value: { raw in
                let names = ["perceptual", "relative colorimetric", "saturation", "absolute colorimetric"]
                return names[safe: Int(truncatingIfNeeded: raw)].map { "\(raw) · \($0)" } ?? "\(raw)"
            })
        case "pHYs":
            let unit = window.u8(position + 8)
            list.uint("Pixels per unit, x", at: position, size: 4, value: { value in
                unit == 1 ? "\(value) per metre · \(String(format: "%.1f", Double(value) * 0.0254)) dpi" : "\(value)"
            })
            list.uint("Pixels per unit, y", at: position + 4, size: 4, value: { value in
                unit == 1 ? "\(value) per metre · \(String(format: "%.1f", Double(value) * 0.0254)) dpi" : "\(value)"
            })
            list.uint("Unit", at: position + 8, size: 1, value: { $0 == 1 ? "1 · metre" : ($0 == 0 ? "0 · unknown (only the shape of a pixel)" : "\($0)") })
        case "tIME":
            // Plain decimal: a date is not read in hex.
            list.uint("Year", at: position, size: 2, value: { "\($0)" })
            list.uint("Month", at: position + 2, size: 1, value: { "\($0)" })
            list.uint("Day", at: position + 3, size: 1, value: { "\($0)" })
            list.uint("Hour", at: position + 4, size: 1, value: { "\($0)" })
            list.uint("Minute", at: position + 5, size: 1, value: { "\($0)" })
            list.uint("Second", at: position + 6, size: 1, value: { "\($0)" })
        case "tEXt":
            textChunk(&list, window: window, position: position, length: length, kind: "tEXt")
        case "zTXt":
            if let nul = firstZero(in: window, from: position, limit: min(length, 80)) {
                list.text("Keyword", at: position, length: nul - position)
                list.bytes("Separator", at: nul, length: 1, kind: .padding)
                list.uint("Compression method", at: nul + 1, size: 1, value: { $0 == 0 ? "0 · deflate" : "\($0) · unknown" })
                list.bytes("Compressed text", at: nul + 2, length: max(0, end - nul - 2), note: "Deflate-compressed, so it is not text here.")
            } else {
                list.bytes("Data", at: position, length: length)
            }
        case "iTXt":
            if let nul = firstZero(in: window, from: position, limit: min(length, 80)) {
                list.text("Keyword", at: position, length: nul - position)
                list.bytes("Separator", at: nul, length: 1, kind: .padding)
                list.uint("Compressed", at: nul + 1, size: 1, value: { $0 == 0 ? "0 · no" : "\($0) · yes" })
                list.uint("Compression method", at: nul + 2, size: 1)
                list.bytes("Language, translated keyword and text", at: nul + 3, length: max(0, end - nul - 3), kind: .text,
                           value: window.slice(nul + 3, Int(min(max(0, end - nul - 3), 48))).map { FieldText.ascii($0) },
                           note: "Language tag, translated keyword and text, each ending in a zero byte; the text is UTF-8.")
            } else {
                list.bytes("Data", at: position, length: length)
            }
        case "iCCP":
            if let nul = firstZero(in: window, from: position, limit: min(length, 80)) {
                list.text("Profile name", at: position, length: nul - position)
                list.bytes("Separator", at: nul, length: 1, kind: .padding)
                list.uint("Compression method", at: nul + 1, size: 1, value: { $0 == 0 ? "0 · deflate" : "\($0) · unknown" })
                list.bytes("Compressed profile", at: nul + 2, length: max(0, end - nul - 2))
            } else {
                list.bytes("Data", at: position, length: length)
            }
        case "bKGD":
            switch colourType {
            case 3?: list.uint("Palette index", at: position, size: 1)
            case 0?, 4?: list.uint("Grey", at: position, size: 2)
            case 2?, 6?:
                list.uint("Red", at: position, size: 2)
                list.uint("Green", at: position + 2, size: 2)
                list.uint("Blue", at: position + 4, size: 2)
            default: list.bytes("Data", at: position, length: length)
            }
        case "acTL":
            list.uint("Frames", at: position, size: 4)
            list.uint("Plays", at: position + 4, size: 4, value: { $0 == 0 ? "0 · forever" : "\($0)" })
        case "fcTL":
            list.uint("Sequence number", at: position, size: 4)
            list.uint("Width", at: position + 4, size: 4, value: { "\($0) pixels" })
            list.uint("Height", at: position + 8, size: 4, value: { "\($0) pixels" })
            list.uint("X offset", at: position + 12, size: 4)
            list.uint("Y offset", at: position + 16, size: 4)
            list.uint("Delay numerator", at: position + 20, size: 2)
            list.uint("Delay denominator", at: position + 22, size: 2, note: { $0 == 0 ? "Zero means a hundredth of a second." : nil })
            list.uint("Dispose", at: position + 24, size: 1, value: { ["0 · none", "1 · background", "2 · previous"][safe: Int($0)] ?? "\($0)" })
            list.uint("Blend", at: position + 25, size: 1, value: { ["0 · source", "1 · over"][safe: Int($0)] ?? "\($0)" })
        case "fdAT":
            list.uint("Sequence number", at: position, size: 4)
            list.bytes("Frame data", at: position + 4, length: max(0, length - 4), note: "Compressed like IDAT.")
        case "IDAT":
            if firstIDAT {
                let method = list.uint("zlib method and window", at: position, size: 1, value: { cmf in
                    let isDeflate = cmf & 0x0F == 8
                    let windowSize = 1 << Int((cmf >> 4) + 8)
                    let hex = FieldText.hexNumber(cmf, size: 1)
                    return isDeflate ? "\(hex) · deflate, \(windowSize / 1024) KB window" : "\(hex) · not deflate"
                })
                if method != nil {
                    list.uint("zlib flags", at: position + 1, size: 1, value: { flg in
                        let levels = ["fastest", "fast", "default", "best"]
                        let level = levels[Int((flg >> 6) & 3)]
                        let dictionary = flg & 0x20 != 0 ? ", preset dictionary" : ""
                        return "\(FieldText.hexNumber(flg, size: 1)) · \(level)\(dictionary)"
                    })
                    list.bytes("Compressed pixels", at: position + 2, length: max(0, length - 2),
                               note: "A deflate stream of filtered scanlines. This view does not decompress it.")
                }
            } else {
                list.bytes("More compressed pixels", at: position, length: length, note: "Continues the deflate stream of the chunk before.")
            }
        case "IEND":
            break
        default:
            if length > 0 { list.bytes("Data", at: position, length: length) }
        }

        let children = list.nodes
        var kind: FieldNode.Kind = children.isEmpty ? .bytes : .container
        var value: String?
        if children.isEmpty, length > 0 { value = FieldText.hex(window.bytes[...]) }
        if length == 0 { kind = .bytes; value = "no data" }
        return FieldNode(id: id, name: "Data", offset: position, length: length, kind: kind, value: value,
                         children: children.isEmpty ? .none : .list(children))
    }

    private static func textChunk(_ list: inout FieldList, window: ByteWindow, position: Int64, length: Int64, kind: String) {
        if let nul = firstZero(in: window, from: position, limit: min(length, 80)) {
            list.text("Keyword", at: position, length: nul - position, note: "1 to 79 characters of Latin-1, then a zero byte.")
            list.bytes("Separator", at: nul, length: 1, kind: .padding)
            let textLength = max(0, position + length - nul - 1)
            list.bytes("Text", at: nul + 1, length: textLength, kind: .text,
                       value: window.slice(nul + 1, Int(min(textLength, 48))).map { FieldText.ascii($0) })
        } else {
            list.bytes("Data", at: position, length: length, note: "No zero byte after the keyword, so this is not a well-formed \(kind) chunk.")
        }
    }

    /// The offset of the first zero byte at or after `from`, within `limit` bytes, in the window.
    private static func firstZero(in window: ByteWindow, from: Int64, limit: Int64) -> Int64? {
        var offset = from
        let stop = from + limit
        while offset < stop, let byte = window.u8(offset) {
            if byte == 0 { return offset }
            offset += 1
        }
        return nil
    }

    // MARK: Words

    static func colourName(_ value: UInt64) -> String {
        switch value {
        case 0: return "greyscale"
        case 2: return "truecolour (red, green, blue)"
        case 3: return "indexed colour (a palette)"
        case 4: return "greyscale with alpha"
        case 6: return "truecolour with alpha"
        default: return "unknown"
        }
    }

    static func colourShort(_ value: UInt8) -> String {
        switch value {
        case 0: return "grey"
        case 2: return "RGB"
        case 3: return "palette"
        case 4: return "grey+alpha"
        case 6: return "RGBA"
        default: return "colour type \(value)"
        }
    }

    /// What the case of the four letters says: the PNG spec's four properties.
    static func classification(_ type: [UInt8]) -> String {
        guard type.count == 4 else { return "" }
        let critical = type[0] & 0x20 == 0
        let publicChunk = type[1] & 0x20 == 0
        let reservedOK = type[2] & 0x20 == 0
        let safeToCopy = type[3] & 0x20 != 0
        var parts = [critical ? "Critical: a reader that does not understand it cannot show the image." : "Ancillary: a reader may skip it."]
        parts.append(publicChunk ? "Public, from the PNG spec or its registry." : "Private to one program.")
        if !reservedOK { parts.append("The reserved bit is set, which a valid chunk does not have.") }
        parts.append(safeToCopy ? "An editor that does not understand it may keep it." : "An editor that changes the image should drop it.")
        return parts.joined(separator: " ")
    }

    private static let chunkTitles: [String: String] = [
        "IHDR": "Image header", "PLTE": "Palette", "IDAT": "Image data", "IEND": "Image end",
        "tRNS": "Transparency", "gAMA": "Gamma", "cHRM": "Chromaticities", "sRGB": "sRGB colour space",
        "iCCP": "ICC profile", "sBIT": "Significant bits", "bKGD": "Background colour", "hIST": "Palette histogram",
        "pHYs": "Pixel size", "sPLT": "Suggested palette", "tIME": "Last modified", "tEXt": "Text",
        "zTXt": "Compressed text", "iTXt": "International text", "eXIf": "Exif metadata",
        "acTL": "Animation control", "fcTL": "Frame control", "fdAT": "Frame data", "cICP": "Colour code points",
    ]

    private static let chunkNotes: [String: String] = [
        "IHDR": "Width, height, bit depth and colour type: what the pixels are. Always first.",
        "IDAT": "The pixels, filtered and deflate-compressed. A big image is many IDAT chunks in a row.",
        "IEND": "Always last, with no data: the end of the PNG.",
    ]
}

private extension Array {
    /// The element at `index`, or nil outside the array.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
