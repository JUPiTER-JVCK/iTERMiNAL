import Foundation

/// A ZIP archive taken apart. The central directory at the end says where every entry is, so it is read first;
/// then each entry is shown where it lies: a local header, the compressed data, and a data descriptor if the
/// sizes were not known when it was written. Bytes no entry accounts for (a program in front of a
/// self-extracting archive, padding, a gap) are shown as what they are. Archives that are .docx, .xlsx,
/// .jar, .apk and the like are the same format.
enum ZIPParser: FormatParser {
    static let identity = FormatIdentity(id: "zip", name: "a ZIP archive", detail: "also the container of .docx, .xlsx, .jar and .apk files", hasParser: true)

    static func matches(head: [UInt8], length: Int64) -> Bool {
        head.count >= 4 && head[0] == 0x50 && head[1] == 0x4B && ((head[2] == 3 && head[3] == 4) || (head[2] == 5 && head[3] == 6))
    }

    // MARK: Signatures

    static let localSignature: UInt32 = 0x0403_4B50
    static let centralSignature: UInt32 = 0x0201_4B50
    static let endSignature: UInt32 = 0x0605_4B50
    static let zip64EndSignature: UInt32 = 0x0606_4B50
    static let zip64LocatorSignature: UInt32 = 0x0706_4B50
    static let descriptorSignature: UInt32 = 0x0807_4B50

    /// The most a record after the central directory can reach back: the comment is at most 65535 bytes.
    static let searchLength: Int64 = 22 + 65_535

    /// How many bytes of a stored entry are read to check its CRC when its node is opened.
    static let checkLimit: Int64 = 64 * 1024 * 1024

    // MARK: Words

    static func methodName(_ raw: UInt64) -> String {
        let names: [UInt64: String] = [0: "stored", 1: "shrunk", 2: "reduced 1", 3: "reduced 2", 4: "reduced 3", 5: "reduced 4", 6: "imploded", 8: "deflated",
                                       9: "deflate64", 10: "PKWARE implode", 12: "bzip2", 14: "LZMA", 18: "IBM TERSE", 19: "IBM LZ77", 93: "Zstandard",
                                       94: "MP3", 95: "xz", 96: "JPEG", 97: "WavPack", 98: "PPMd", 99: "AES encryption"]
        return names[raw].map { "\(raw) · \($0)" } ?? "\(raw)"
    }

    static func flagsText(_ raw: UInt64) -> String {
        var names: [String] = []
        if raw & 0x0001 != 0 { names.append("encrypted") }
        if raw & 0x0008 != 0 { names.append("sizes in a data descriptor") }
        if raw & 0x0010 != 0 { names.append("enhanced deflate") }
        if raw & 0x0020 != 0 { names.append("patched data") }
        if raw & 0x0040 != 0 { names.append("strong encryption") }
        if raw & 0x0800 != 0 { names.append("UTF-8 names") }
        if raw & 0x2000 != 0 { names.append("directory masked") }
        return FieldText.hexNumber(raw, size: 2) + (names.isEmpty ? "" : " · " + names.joined(separator: ", "))
    }

    static func dosTime(date: UInt64, time: UInt64) -> String {
        let year = 1980 + Int(date >> 9)
        let month = Int((date >> 5) & 15)
        let day = Int(date & 31)
        let hour = Int(time >> 11)
        let minute = Int((time >> 5) & 63)
        let second = Int(time & 31) * 2
        guard (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 60 else {
            return "\(FieldText.hexNumber(date, size: 2)) \(FieldText.hexNumber(time, size: 2)) · not a date"
        }
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d", year, month, day, hour, minute, second)
    }

    static func unixTime(_ raw: UInt64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(Int64(bitPattern: raw)))
        let calendar = Calendar(identifier: .gregorian)
        var utc = calendar
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d UTC", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    static func hostName(_ raw: UInt64) -> String {
        let names: [UInt64: String] = [0: "MS-DOS", 1: "Amiga", 2: "OpenVMS", 3: "Unix", 4: "VM/CMS", 5: "Atari ST", 6: "OS/2", 7: "Macintosh", 8: "Z-System",
                                       9: "CP/M", 10: "Windows NTFS", 11: "MVS", 12: "VSE", 13: "Acorn Risc", 14: "VFAT", 15: "alternate MVS", 16: "BeOS",
                                       17: "Tandem", 18: "OS/400", 19: "macOS"]
        return names[raw].map { "\(raw) · \($0)" } ?? "\(raw)"
    }

    static func versionText(_ raw: UInt64, host: Bool) -> String {
        let version = "\((raw & 0xFF) / 10).\((raw & 0xFF) % 10)"
        return host ? "\(version) on \(hostName(raw >> 8))" : version
    }

    static func extraName(_ id: UInt64) -> String {
        let names: [UInt64: String] = [0x0001: "Zip64 sizes", 0x0007: "AV info", 0x0009: "OS/2", 0x000A: "NTFS times", 0x000C: "OpenVMS", 0x000D: "Unix",
                                       0x5455: "Extended timestamp", 0x5855: "Info-ZIP Unix (old)", 0x7075: "Unicode path", 0x6375: "Unicode comment",
                                       0x756E: "ASi Unix", 0x7855: "Info-ZIP Unix", 0x7875: "Unix IDs", 0x9901: "AES encryption", 0xCAFE: "Java class",
                                       0xA220: "Microsoft Open Packaging", 0x4B46: "FWKCS MD5", 0x4453: "Windows security descriptor"]
        return names[id] ?? "unknown"
    }

    static func attributesText(host: UInt64, raw: UInt64) -> String {
        if host == 3 || host == 19 {
            let mode = raw >> 16
            let kind: String
            switch mode & 0o170000 {
            case 0o040000: kind = "directory"
            case 0o120000: kind = "symbolic link"
            case 0o100000: kind = "file"
            default: kind = "mode"
            }
            return "\(FieldText.hexNumber(raw, size: 4)) · \(kind) " + String(mode & 0o7777, radix: 8)
        }
        var names: [String] = []
        if raw & 0x01 != 0 { names.append("read-only") }
        if raw & 0x02 != 0 { names.append("hidden") }
        if raw & 0x04 != 0 { names.append("system") }
        if raw & 0x10 != 0 { names.append("directory") }
        if raw & 0x20 != 0 { names.append("archive") }
        return FieldText.hexNumber(raw, size: 4) + (names.isEmpty ? "" : " · " + names.joined(separator: ", "))
    }

    static func nameText(_ bytes: [UInt8], limit: Int = 120) -> String {
        let text = String(decoding: bytes.prefix(limit), as: UTF8.self)
        return bytes.count > limit ? text + "…" : text
    }

    // MARK: An entry, as the central directory says it

    struct Entry {
        var index = 0
        /// Where its record is in the central directory.
        var recordOffset: Int64 = 0
        var recordLength: Int64 = 0
        var name: [UInt8] = []
        var versionMade: UInt64 = 0
        var flags: UInt64 = 0
        var method: UInt64 = 0
        var crc: UInt64 = 0
        var compressedSize: UInt64 = 0
        var uncompressedSize: UInt64 = 0
        var localOffset: UInt64 = 0
        var usesZip64 = false
    }

    /// Reads the sizes and the offset out of a Zip64 extra field, for the numbers the record had to leave at their maximum.
    private static func zip64Values(_ window: ByteWindow, at start: Int64, length: Int64, entry: inout Entry, needs: (size: Bool, packed: Bool, offset: Bool)) {
        var position = start
        let end = start + length
        var guardCount = 0
        while position + 4 <= end, guardCount < 64 {
            guardCount += 1
            guard let id = window.u16(position, .little), let size = window.u16(position + 2, .little) else { return }
            let body = position + 4
            if id == 1 {
                var at = body
                let stop = min(end, body + Int64(size))
                if needs.size, at + 8 <= stop, let v = window.u64(at, .little) { entry.uncompressedSize = v; at += 8; entry.usesZip64 = true }
                if needs.packed, at + 8 <= stop, let v = window.u64(at, .little) { entry.compressedSize = v; at += 8; entry.usesZip64 = true }
                if needs.offset, at + 8 <= stop, let v = window.u64(at, .little) { entry.localOffset = v; entry.usesZip64 = true }
                return
            }
            position = body + Int64(size)
        }
    }

    // MARK: Fields

    /// The extra field: a list of (id, size, data), each opened as far as it is known.
    private static func extraFields(_ list: inout FieldList, at start: Int64, length: Int64, central: Bool) {
        guard length > 0 else { return }
        list.group("Extra field", at: start, length: length, kind: .container, value: FieldText.bytes(length),
                   note: "Further information, each item with a two-byte id and a two-byte size. Which ids a program writes is its own business.") { f in
            var position = start
            let end = start + length
            var count = 0
            while position < end {
                guard position + 4 <= end, count < 64 else {
                    f.bytes(count >= 64 ? "More items" : "Cut short", at: position, length: end - position, kind: count >= 64 ? .bytes : .problem,
                            note: count >= 64 ? "Only the first 64 items are opened." : "Less than the four bytes an item's id and size need.")
                    return
                }
                count += 1
                let id = f.window.u16(position, .little).map { UInt64($0) } ?? 0
                let size = Int64(f.window.u16(position + 2, .little) ?? 0)
                let itemLength = min(4 + size, end - position)
                let at = position
                f.group("Item \(FieldText.hexNumber(id, size: 2)) \(extraName(id))", at: at, length: itemLength, kind: .container,
                        value: FieldText.bytes(size)) { g in
                    g.uint("Id", at: at, size: 2, value: { "\(FieldText.hexNumber($0, size: 2)) · \(extraName($0))" })
                    g.uint("Size", at: at + 2, size: 2)
                    let body = at + 4
                    let available = max(0, itemLength - 4)
                    switch id {
                    case 0x5455 where available >= 1:
                        let flags = g.uint("Which times", at: body, size: 1, kind: .flags, value: { raw in
                            var names: [String] = []
                            if raw & 1 != 0 { names.append("modified") }
                            if raw & 2 != 0 { names.append("accessed") }
                            if raw & 4 != 0 { names.append("created") }
                            return FieldText.hexNumber(raw, size: 1) + " · " + names.joined(separator: ", ")
                        }) ?? 0
                        var cursor = body + 1
                        for (bit, name) in [(UInt64(1), "Modified"), (2, "Accessed"), (4, "Created")] where flags & bit != 0 {
                            // In a central directory only the modified time is kept.
                            guard cursor + 4 <= body + available, !(central && bit != 1) else { break }
                            g.uint(name, at: cursor, size: 4, kind: .time, value: { unixTime($0) })
                            cursor += 4
                        }
                        if cursor < body + available { g.bytes("More", at: cursor, length: body + available - cursor) }
                    case 0x7875 where available >= 3:
                        g.uint("Version", at: body, size: 1)
                        let uidSize = Int(g.uint("User id size", at: body + 1, size: 1) ?? 0)
                        var cursor = body + 2
                        if uidSize >= 1, uidSize <= 8, cursor + Int64(uidSize) <= body + available {
                            g.uint("User id", at: cursor, size: uidSize)
                            cursor += Int64(uidSize)
                        }
                        if cursor + 1 <= body + available {
                            let gidSize = Int(g.uint("Group id size", at: cursor, size: 1) ?? 0)
                            cursor += 1
                            if gidSize >= 1, gidSize <= 8, cursor + Int64(gidSize) <= body + available {
                                g.uint("Group id", at: cursor, size: gidSize)
                                cursor += Int64(gidSize)
                            }
                        }
                        if cursor < body + available { g.bytes("More", at: cursor, length: body + available - cursor) }
                    case 0x0001:
                        var cursor = body
                        for name in ["Uncompressed size", "Compressed size", "Offset of local header"] where cursor + 8 <= body + available {
                            g.uint(name, at: cursor, size: 8, value: { "\($0) bytes" })
                            cursor += 8
                        }
                        if cursor + 4 <= body + available { g.uint("Disk number", at: cursor, size: 4); cursor += 4 }
                        if cursor < body + available { g.bytes("More", at: cursor, length: body + available - cursor) }
                    case 0xCAFE:
                        if available > 0 { g.bytes("Data", at: body, length: available, note: "Marks a jar that can also be run as a Mach-O or shell program.") }
                    default:
                        if available > 0 { g.bytes("Data", at: body, length: available) }
                    }
                }
                position += 4 + size
            }
        }
    }

    /// The local file header and what follows it, one entry's part of the file.
    private static func localNodes(id: String, source: ByteSource, entry: Entry, start: Int64, headerLength: Int64, dataLength: Int64,
                                   descriptorLength: Int64, total: Int64) -> [FieldNode] {
        let window = ByteWindow(source: source, at: start, count: Int(min(headerLength, Int64(ByteWindow.maxBytes))))
        var list = FieldList(idPrefix: id, window: window, endianness: .little)
        let nameLength = Int64(window.u16(start + 26, .little) ?? 0)
        let extraLength = Int64(window.u16(start + 28, .little) ?? 0)
        list.group("Local file header", at: start, length: min(headerLength, 30 + nameLength + extraLength), kind: .container,
                   value: nameText(entry.name), note: "Describes the entry that follows it. The central directory repeats this, and is what readers trust.") { f in
            f.uint("Signature", at: start, size: 4, kind: .magic, value: { FieldText.hexNumber($0, size: 4) + " · PK\\3\\4" })
            f.uint("Version needed", at: start + 4, size: 2, value: { versionText($0, host: false) })
            f.uint("Flags", at: start + 6, size: 2, kind: .flags, value: { flagsText($0) })
            f.uint("Method", at: start + 8, size: 2, value: { methodName($0) })
            f.uint("Modified", at: start + 10, size: 4, kind: .time, value: { dosTime(date: $0 >> 16, time: $0 & 0xFFFF) },
                   note: { _ in "A DOS time (two-second steps) and date (from 1980), as the format has always stored them." })
            f.uint("CRC-32", at: start + 14, size: 4, kind: .checksum, value: { FieldText.hexNumber($0, size: 4) },
                   note: { raw in entry.flags & 8 != 0 && raw == 0 ? "Zero: the real one follows the data, in the data descriptor." : nil })
            f.uint("Compressed size", at: start + 18, size: 4, value: { $0 == 0xFFFF_FFFF ? "4294967295 · see the Zip64 field" : "\($0) bytes" })
            f.uint("Uncompressed size", at: start + 22, size: 4, value: { $0 == 0xFFFF_FFFF ? "4294967295 · see the Zip64 field" : "\($0) bytes" })
            f.uint("Name length", at: start + 26, size: 2)
            f.uint("Extra field length", at: start + 28, size: 2)
            if nameLength > 0 { f.bytes("Name", at: start + 30, length: nameLength, kind: .text, value: "\"" + nameText(entry.name) + "\"") }
            extraFields(&f, at: start + 30 + nameLength, length: extraLength, central: false)
        }
        let dataStart = start + headerLength
        if dataLength > 0 {
            var note = "The entry's contents, \(methodName(entry.method).components(separatedBy: " · ").last ?? "")."
            var value = FieldText.bytes(dataLength)
            if entry.method == 0, entry.flags & 1 == 0, dataLength <= checkLimit, dataStart + dataLength <= total, dataLength == Int64(clamping: entry.uncompressedSize) {
                var crc = CRC32()
                var position = dataStart
                while position < dataStart + dataLength {
                    let piece = source.read(position..<min(position + 1 << 20, dataStart + dataLength))
                    if piece.isEmpty { break }
                    crc.update(piece)
                    position += Int64(piece.count)
                }
                let matches = UInt64(crc.value) == entry.crc
                value += matches ? " · CRC matches" : " · CRC DIFFERS"
                note += matches ? " Stored as it is, so its CRC-32 was checked: it matches." : " Stored as it is, and its CRC-32 is \(FieldText.hexNumber(UInt64(crc.value), size: 4)), not the \(FieldText.hexNumber(entry.crc, size: 4)) the archive records."
            }
            let held = max(0, min(dataLength, total - dataStart))
            list.add(FieldNode(id: id + "/data", name: "Compressed data", offset: dataStart, length: held, kind: .bytes, value: value, note: note))
        }
        if descriptorLength > 0 {
            let at = dataStart + dataLength
            let dWindow = ByteWindow(source: source, at: at, count: Int(descriptorLength))
            var d = FieldList(idPrefix: id + "/descriptor", window: dWindow, endianness: .little)
            let hasSignature = dWindow.u32(at, .little) == descriptorSignature
            let wide = descriptorLength == (hasSignature ? 24 : 20)
            let sizeBytes = wide ? 8 : 4
            var cursor = at
            if hasSignature { d.uint("Signature", at: cursor, size: 4, kind: .magic, value: { FieldText.hexNumber($0, size: 4) + " · PK\\7\\8" }); cursor += 4 }
            d.uint("CRC-32", at: cursor, size: 4, kind: .checksum, value: { FieldText.hexNumber($0, size: 4) }); cursor += 4
            d.uint("Compressed size", at: cursor, size: sizeBytes, value: { "\($0) bytes" }); cursor += Int64(sizeBytes)
            d.uint("Uncompressed size", at: cursor, size: sizeBytes, value: { "\($0) bytes" })
            list.add(FieldNode(id: id + "/descriptor", name: "Data descriptor", offset: at, length: min(descriptorLength, max(0, total - at)), kind: .container,
                               value: nil, note: "The CRC and sizes, written after the data when they were not known before it.", children: .list(d.nodes)))
        }
        return list.nodes
    }

    /// One record of the central directory.
    private static func centralNodes(id: String, source: ByteSource, entry: Entry) -> [FieldNode] {
        let start = entry.recordOffset
        let window = ByteWindow(source: source, at: start, count: Int(min(entry.recordLength, Int64(ByteWindow.maxBytes))))
        var f = FieldList(idPrefix: id, window: window, endianness: .little)
        let nameLength = Int64(window.u16(start + 28, .little) ?? 0)
        let extraLength = Int64(window.u16(start + 30, .little) ?? 0)
        let commentLength = Int64(window.u16(start + 32, .little) ?? 0)
        f.uint("Signature", at: start, size: 4, kind: .magic, value: { FieldText.hexNumber($0, size: 4) + " · PK\\1\\2" })
        f.uint("Version made by", at: start + 4, size: 2, value: { versionText($0, host: true) })
        f.uint("Version needed", at: start + 6, size: 2, value: { versionText($0, host: false) })
        f.uint("Flags", at: start + 8, size: 2, kind: .flags, value: { flagsText($0) })
        f.uint("Method", at: start + 10, size: 2, value: { methodName($0) })
        f.uint("Modified", at: start + 12, size: 4, kind: .time, value: { dosTime(date: $0 >> 16, time: $0 & 0xFFFF) },
               note: { _ in "A DOS time (two-second steps) and date (from 1980), as the format has always stored them." })
        f.uint("CRC-32", at: start + 16, size: 4, kind: .checksum, value: { FieldText.hexNumber($0, size: 4) })
        f.uint("Compressed size", at: start + 20, size: 4, value: { $0 == 0xFFFF_FFFF && entry.usesZip64 ? "\(entry.compressedSize) bytes · from the Zip64 field" : ($0 == 0xFFFF_FFFF ? "4294967295 · see the Zip64 field" : "\($0) bytes") })
        f.uint("Uncompressed size", at: start + 24, size: 4, value: { $0 == 0xFFFF_FFFF && entry.usesZip64 ? "\(entry.uncompressedSize) bytes · from the Zip64 field" : ($0 == 0xFFFF_FFFF ? "4294967295 · see the Zip64 field" : "\($0) bytes") })
        f.uint("Name length", at: start + 28, size: 2)
        f.uint("Extra field length", at: start + 30, size: 2)
        f.uint("Comment length", at: start + 32, size: 2)
        f.uint("Disk number", at: start + 34, size: 2)
        f.uint("Internal attributes", at: start + 36, size: 2, kind: .flags, value: { $0 & 1 == 1 ? "\(FieldText.hexNumber($0, size: 2)) · text file" : FieldText.hexNumber($0, size: 2) })
        let host = entry.versionMade >> 8
        f.uint("External attributes", at: start + 38, size: 4, kind: .flags, value: { attributesText(host: host, raw: $0) })
        f.uint("Offset of local header", at: start + 42, size: 4, value: { $0 == 0xFFFF_FFFF && entry.usesZip64 ? "\(entry.localOffset) · from the Zip64 field" : ($0 == 0xFFFF_FFFF ? "4294967295 · see the Zip64 field" : "\($0)") })
        if nameLength > 0 { f.bytes("Name", at: start + 46, length: nameLength, kind: .text, value: "\"" + nameText(entry.name) + "\"") }
        extraFields(&f, at: start + 46 + nameLength, length: extraLength, central: true)
        if commentLength > 0 { f.bytes("Comment", at: start + 46 + nameLength + extraLength, length: commentLength, kind: .text, value: "\"" + nameText(window.slice(start + 46 + nameLength + extraLength, Int(commentLength)).map(Array.init) ?? []) + "\"") }
        return f.nodes
    }

    // MARK: Parsing

    private struct Piece {
        var offset: Int64
        var length: Int64
        var node: FieldNode
    }

    static func parse(_ source: ByteSource, context: ParseContext) -> ParseOutcome {
        var outcome = ParseOutcome()
        var problems: [String] = []
        let total = source.count

        // The end of central directory record: the last place its signature is, in the last 64 KB.
        let tailStart = max(0, total - searchLength)
        let tail = ByteWindow(source: source, at: tailStart, count: Int(total - tailStart))
        var eocd: Int64?
        var position = total - 22
        while position >= tailStart {
            if tail.u32(position, .little) == endSignature { eocd = position; break }
            position -= 1
        }

        var pieces: [Piece] = []
        var entries: [Entry] = []
        var declaredEntries: UInt64 = 0
        var centralStart: Int64 = 0
        var centralLength: Int64 = 0
        var shift: Int64 = 0
        var archiveComment: Int64 = 0

        if let eocd {
            func u16(_ at: Int64) -> UInt64 { tail.uint(at, size: 2, .little) ?? 0 }
            func u32(_ at: Int64) -> UInt64 { tail.uint(at, size: 4, .little) ?? 0 }
            let commentLength = Int64(u16(eocd + 20))
            archiveComment = min(commentLength, max(0, total - eocd - 22))
            let recordLength = min(22 + commentLength, total - eocd)
            var entryCount = u16(eocd + 10)
            var sizeOfCentral = u32(eocd + 12)
            var offsetOfCentral = u32(eocd + 16)
            var diskInfo = (u16(eocd + 4), u16(eocd + 6))

            // Zip64: a locator just before, naming a larger record that holds the numbers that did not fit.
            var zip64End: Int64?
            var zip64Length: Int64 = 0
            if eocd - 20 >= 0 {
                let locatorWindow = ByteWindow(source: source, at: eocd - 20, count: 20)
                if locatorWindow.u32(eocd - 20, .little) == zip64LocatorSignature {
                    let recordOffset = min(Int64(clamping: locatorWindow.u64(eocd - 12, .little) ?? UInt64.max), total)
                    let header = ByteWindow(source: source, at: recordOffset, count: 56)
                    if header.u32(recordOffset, .little) == zip64EndSignature, header.has(recordOffset, 56) {
                        zip64End = recordOffset
                        zip64Length = min(12 + min(Int64(clamping: header.u64(recordOffset + 4, .little) ?? 0), total), eocd - 20 - recordOffset)
                        entryCount = header.u64(recordOffset + 32, .little) ?? entryCount
                        sizeOfCentral = header.u64(recordOffset + 40, .little) ?? sizeOfCentral
                        offsetOfCentral = header.u64(recordOffset + 48, .little) ?? offsetOfCentral
                        diskInfo = (UInt64(header.u32(recordOffset + 16, .little) ?? 0), UInt64(header.u32(recordOffset + 20, .little) ?? 0))
                    } else {
                        problems.append("The Zip64 locator points at \(recordOffset), where there is no Zip64 end record.")
                    }
                    // The locator and the Zip64 record.
                    var locatorList = FieldList(idPrefix: "zip/zip64-locator", window: locatorWindow, endianness: .little)
                    locatorList.uint("Signature", at: eocd - 20, size: 4, kind: .magic, value: { FieldText.hexNumber($0, size: 4) + " · PK\\6\\7" })
                    locatorList.uint("Disk with the Zip64 end record", at: eocd - 16, size: 4)
                    locatorList.uint("Offset of the Zip64 end record", at: eocd - 12, size: 8)
                    locatorList.uint("Number of disks", at: eocd - 4, size: 4)
                    pieces.append(Piece(offset: eocd - 20, length: 20,
                                        node: FieldNode(id: "zip/zip64-locator", name: "Zip64 end of central directory locator", offset: eocd - 20, length: 20,
                                                        kind: .container, value: nil, note: "Says where the Zip64 end record is, for archives too large for the numbers in the ordinary one.",
                                                        children: .list(locatorList.nodes))))
                }
            }
            if let zip64End, zip64Length >= 56 {
                let window = ByteWindow(source: source, at: zip64End, count: Int(zip64Length))
                var f = FieldList(idPrefix: "zip/zip64-end", window: window, endianness: .little)
                f.uint("Signature", at: zip64End, size: 4, kind: .magic, value: { FieldText.hexNumber($0, size: 4) + " · PK\\6\\6" })
                f.uint("Size of the rest", at: zip64End + 4, size: 8)
                f.uint("Version made by", at: zip64End + 12, size: 2, value: { versionText($0, host: true) })
                f.uint("Version needed", at: zip64End + 14, size: 2, value: { versionText($0, host: false) })
                f.uint("This disk", at: zip64End + 16, size: 4)
                f.uint("Disk with the central directory", at: zip64End + 20, size: 4)
                f.uint("Entries on this disk", at: zip64End + 24, size: 8)
                f.uint("Entries", at: zip64End + 32, size: 8)
                f.uint("Size of the central directory", at: zip64End + 40, size: 8, value: { "\($0) bytes" })
                f.uint("Offset of the central directory", at: zip64End + 48, size: 8)
                if zip64Length > 56 { f.bytes("Extensible data", at: zip64End + 56, length: zip64Length - 56) }
                pieces.append(Piece(offset: zip64End, length: zip64Length,
                                    node: FieldNode(id: "zip/zip64-end", name: "Zip64 end of central directory", offset: zip64End, length: zip64Length,
                                                    kind: .container, value: "\(entryCount) entries", note: "The numbers the ordinary end record is too small for.",
                                                    children: .list(f.nodes))))
            }

            // The end record itself.
            var f = FieldList(idPrefix: "zip/end", window: tail, endianness: .little)
            f.uint("Signature", at: eocd, size: 4, kind: .magic, value: { FieldText.hexNumber($0, size: 4) + " · PK\\5\\6" })
            f.uint("This disk", at: eocd + 4, size: 2)
            f.uint("Disk with the central directory", at: eocd + 6, size: 2)
            f.uint("Entries on this disk", at: eocd + 8, size: 2)
            f.uint("Entries", at: eocd + 10, size: 2, value: { $0 == 0xFFFF ? "65535 · or more, see Zip64" : "\($0)" })
            f.uint("Size of the central directory", at: eocd + 12, size: 4, value: { $0 == 0xFFFF_FFFF ? "4294967295 · or more, see Zip64" : "\($0) bytes" })
            f.uint("Offset of the central directory", at: eocd + 16, size: 4, value: { $0 == 0xFFFF_FFFF ? "4294967295 · or more, see Zip64" : "\($0)" })
            f.uint("Comment length", at: eocd + 20, size: 2)
            if commentLength > 0 { f.text("Comment", at: eocd + 22, length: commentLength) }
            if 22 + commentLength > total - eocd { problems.append("The archive comment is cut off by the end of the file.") }
            pieces.append(Piece(offset: eocd, length: recordLength,
                                node: FieldNode(id: "zip/end", name: "End of central directory", offset: eocd, length: recordLength, kind: .container,
                                                value: "\(entryCount) entries", note: "The last record: where the central directory is, and how many entries it holds.", children: .list(f.nodes))))
            if diskInfo.0 != 0 || diskInfo.1 != 0 { problems.append("The archive is in several parts (disk \(diskInfo.0)); only this part is shown.") }

            declaredEntries = entryCount
            centralLength = min(Int64(clamping: sizeOfCentral), total)
            centralStart = min(Int64(clamping: offsetOfCentral), total)
            // A program or other data in front shifts every offset by its length.
            let stored = ByteWindow(source: source, at: centralStart, count: 4)
            if stored.u32(centralStart, .little) != centralSignature {
                let candidate = (zip64End ?? eocd) - centralLength
                if candidate > centralStart, candidate >= 0 {
                    let moved = ByteWindow(source: source, at: candidate, count: 4)
                    if moved.u32(candidate, .little) == centralSignature {
                        shift = candidate - centralStart
                        centralStart = candidate
                    }
                }
            }
            if centralStart + centralLength > total { problems.append("The central directory is said to reach past the end of the file."); centralLength = max(0, total - centralStart) }
        } else {
            problems.append("There is no end of central directory record: the file is cut short, or it is not a complete ZIP archive. The entries are found by reading from the front.")
        }

        // The central directory.
        if eocd != nil, centralStart >= 0, centralStart <= total {
            var at = centralStart
            let end = min(centralStart + centralLength, total)
            var window = ByteWindow(source: source, at: at, count: 1 << 20)
            var index = 0
            while at + 46 <= end, !context.isCancelled() {
                if index >= context.maxRecords {
                    outcome.listingLimit = "The first \(context.maxRecords) entries are listed; the rest of the archive is in the dump."
                    break
                }
                if !window.has(at, 46) {
                    window = ByteWindow(source: source, at: at, count: 1 << 20)
                    guard window.has(at, 46) else { break }
                }
                guard window.u32(at, .little) == centralSignature else {
                    problems.append("What is at \(at) in the central directory is not an entry (it does not begin with PK\\1\\2).")
                    break
                }
                let nameLength = Int64(window.u16(at + 28, .little) ?? 0)
                let extraLength = Int64(window.u16(at + 30, .little) ?? 0)
                let commentLength = Int64(window.u16(at + 32, .little) ?? 0)
                let length = 46 + nameLength + extraLength + commentLength
                guard at + length <= end else {
                    problems.append("Entry \(index + 1) of the central directory is cut off by the end of the directory.")
                    break
                }
                if !window.has(at, Int(length)) {
                    window = ByteWindow(source: source, at: at, count: max(1 << 20, Int(length)))
                }
                var entry = Entry()
                entry.index = index
                entry.recordOffset = at
                entry.recordLength = length
                entry.versionMade = UInt64(window.u16(at + 4, .little) ?? 0)
                entry.flags = UInt64(window.u16(at + 8, .little) ?? 0)
                entry.method = UInt64(window.u16(at + 10, .little) ?? 0)
                entry.crc = UInt64(window.u32(at + 16, .little) ?? 0)
                entry.compressedSize = UInt64(window.u32(at + 20, .little) ?? 0)
                entry.uncompressedSize = UInt64(window.u32(at + 24, .little) ?? 0)
                entry.localOffset = UInt64(window.u32(at + 42, .little) ?? 0)
                entry.name = window.slice(at + 46, Int(nameLength)).map(Array.init) ?? []
                zip64Values(window, at: at + 46 + nameLength, length: extraLength, entry: &entry,
                            needs: (entry.uncompressedSize == 0xFFFF_FFFF, entry.compressedSize == 0xFFFF_FFFF, entry.localOffset == 0xFFFF_FFFF))
                entries.append(entry)
                at += length
                index += 1
            }
            if outcome.listingLimit == nil, UInt64(entries.count) != declaredEntries, declaredEntries < 0xFFFF_FFFF {
                problems.append("The end record says \(declaredEntries) entries and the central directory holds \(entries.count).")
            }
            // The central directory's own node: a deferred group per record.
            let cdLength = at - centralStart
            let rest = end - at
            var children: [FieldNode] = []
            for entry in entries {
                let id = "zip/central/entry-\(entry.index + 1)"
                let copy = entry
                children.append(FieldNode(id: id, name: "Entry \(entry.index + 1)", offset: entry.recordOffset, length: entry.recordLength, kind: .container,
                                          value: nameText(entry.name), note: "\(methodName(entry.method).components(separatedBy: " · ").last ?? ""), \(entry.uncompressedSize) bytes",
                                          children: .deferred(DeferredChildren { centralNodes(id: id, source: source, entry: copy) })))
            }
            if rest > 0, outcome.listingLimit != nil {
                children.append(FieldNode(id: "zip/central/more", name: "More entries", offset: at, length: rest, kind: .bytes, value: "not listed"))
            } else if rest > 0 {
                children.append(FieldNode(id: "zip/central/extra", name: "Bytes the entries do not use", offset: at, length: rest, kind: .padding,
                                          value: FieldText.bytes(rest), note: "More than the entries above need: a digital signature, or padding."))
            }
            let shown = cdLength + (rest > 0 ? rest : 0)
            if shown > 0 {
                pieces.append(Piece(offset: centralStart, length: shown,
                                    node: FieldNode(id: "zip/central", name: "Central directory", offset: centralStart, length: shown, kind: .container,
                                                    value: "\(entries.count) entries", note: "A record for every entry: its name, sizes, CRC and where its local header is. A reader starts here.",
                                                    children: .list(children))))
            }
        }

        // The entries, in the file, found from the central directory or, without one, from the front.
        var starts: [(entry: Entry, offset: Int64)] = []
        let structureStart = pieces.map { $0.offset }.min() ?? total
        if eocd != nil {
            for entry in entries {
                let offset = min(Int64(clamping: entry.localOffset), total)
                starts.append((entry, offset + shift))
            }
        } else {
            var at: Int64 = 0
            var index = 0
            while at + 30 <= total, !context.isCancelled(), index < context.maxRecords {
                let window = ByteWindow(source: source, at: at, count: 30)
                guard window.u32(at, .little) == localSignature else { break }
                var entry = Entry()
                entry.index = index
                entry.flags = UInt64(window.u16(at + 6, .little) ?? 0)
                entry.method = UInt64(window.u16(at + 8, .little) ?? 0)
                entry.crc = UInt64(window.u32(at + 14, .little) ?? 0)
                entry.compressedSize = UInt64(window.u32(at + 18, .little) ?? 0)
                entry.uncompressedSize = UInt64(window.u32(at + 22, .little) ?? 0)
                let nameLength = Int64(window.u16(at + 26, .little) ?? 0)
                let extraLength = Int64(window.u16(at + 28, .little) ?? 0)
                entry.name = ByteWindow(source: source, at: at + 30, count: Int(nameLength)).bytes
                starts.append((entry, at))
                index += 1
                // Without the central directory the size is only known if it was written before the data.
                guard entry.flags & 8 == 0 || entry.compressedSize != 0 else {
                    problems.append("Entry \(index) has its size in a data descriptor, and without the central directory there is no telling where it ends.")
                    break
                }
                at += 30 + nameLength + extraLength + min(Int64(clamping: entry.compressedSize), total)
            }
            entries = starts.map { $0.entry }
        }
        starts.sort { $0.offset < $1.offset }
        for (position, item) in starts.enumerated() {
            let entry = item.entry
            let start = item.offset
            guard start >= 0, start + 30 <= total else {
                problems.append("Entry \(entry.index + 1) (\(nameText(entry.name, limit: 40))) is said to start at \(entry.localOffset), outside the file.")
                continue
            }
            let header = ByteWindow(source: source, at: start, count: 30)
            guard header.u32(start, .little) == localSignature else {
                problems.append("Entry \(entry.index + 1) (\(nameText(entry.name, limit: 40))) is said to start at \(start), where there is no local header (PK\\3\\4).")
                continue
            }
            let nameLength = Int64(header.u16(start + 26, .little) ?? 0)
            let extraLength = Int64(header.u16(start + 28, .little) ?? 0)
            let headerLength = 30 + nameLength + extraLength
            let dataLength = min(Int64(clamping: entry.compressedSize), total)
            // The descriptor: its signature is optional, and its numbers are eight bytes each in Zip64.
            var descriptorLength: Int64 = 0
            if entry.flags & 8 != 0 {
                let at = start + headerLength + dataLength
                let signed = at >= 0 && at + 4 <= total && ByteWindow(source: source, at: at, count: 4).u32(at, .little) == descriptorSignature
                // Zip64 shows in the central directory, or in the local header's own extra field.
                var wide = entry.usesZip64
                if !wide, extraLength >= 4 {
                    let extra = ByteWindow(source: source, at: start + 30 + nameLength, count: Int(min(extraLength, 4096)))
                    var cursor = start + 30 + nameLength
                    var items = 0
                    while cursor + 4 <= extra.end, items < 64 {
                        items += 1
                        if extra.u16(cursor, .little) == 1 { wide = true; break }
                        cursor += 4 + Int64(extra.u16(cursor + 2, .little) ?? 0)
                    }
                }
                descriptorLength = (signed ? 4 : 0) + 4 + (wide ? 16 : 8)
            }
            var length = headerLength + dataLength + descriptorLength
            let limit = position + 1 < starts.count ? starts[position + 1].offset : structureStart
            if limit > start, start + length > limit {
                problems.append("Entry \(entry.index + 1) (\(nameText(entry.name, limit: 40))) is said to run to \(start + length), past where the next part of the file begins.")
                length = limit - start
            }
            if start + length > total {
                problems.append("Entry \(entry.index + 1) (\(nameText(entry.name, limit: 40))) is cut off by the end of the file.")
                length = total - start
            }
            guard length > 0 else { continue }
            let id = "zip/entry-\(entry.index + 1)"
            let copy = entry
            let held = length
            let dataHeld = max(0, min(dataLength, held - headerLength))
            let descriptorHeld = max(0, held - headerLength - dataHeld)
            let value = nameText(entry.name)
            let note = "\(methodName(entry.method).components(separatedBy: " · ").last ?? ""), \(entry.compressedSize) bytes" + (entry.uncompressedSize != entry.compressedSize ? " from \(entry.uncompressedSize)" : "")
            pieces.append(Piece(offset: start, length: held,
                                node: FieldNode(id: id, name: "Entry \(entry.index + 1)", offset: start, length: held, kind: .container, value: value, note: note,
                                                children: .deferred(DeferredChildren {
                                                    localNodes(id: id, source: source, entry: copy, start: start, headerLength: min(headerLength, held),
                                                               dataLength: dataHeld, descriptorLength: descriptorHeld, total: total)
                                                }))))
        }

        // Put the pieces in file order and say what is between them.
        pieces.sort { $0.offset < $1.offset || ($0.offset == $1.offset && $0.length > $1.length) }
        var cursor: Int64 = 0
        var roots: [FieldNode] = []
        var gapCount = 0
        for piece in pieces {
            if piece.offset < cursor {
                problems.append("\(piece.node.name) overlaps what comes before it, and is not shown again.")
                continue
            }
            if piece.offset > cursor {
                gapCount += 1
                let first = roots.isEmpty
                roots.append(FieldNode(id: "zip/gap-\(gapCount)", name: first ? "Data before the first entry" : "Bytes no entry accounts for", offset: cursor, length: piece.offset - cursor,
                                       kind: first ? .bytes : .padding, value: FieldText.bytes(piece.offset - cursor),
                                       note: first ? "Not part of the archive's entries: a program in front of a self-extracting archive, or a header." : "Between two parts of the archive that nothing points at."))
            }
            roots.append(piece.node)
            cursor = piece.offset + piece.length
        }
        if cursor < total {
            roots.append(FieldNode(id: "zip/rest", name: roots.isEmpty ? "Bytes with no structure" : "Data after the end", offset: cursor, length: total - cursor,
                                   kind: roots.isEmpty ? .bytes : .padding, value: FieldText.bytes(total - cursor),
                                   note: roots.isEmpty ? "No entry could be found." : "After the last record: nothing of the archive."))
        }
        outcome.roots = roots
        outcome.problems = Array(problems.prefix(20))

        let names = entries.map { String(decoding: $0.name, as: UTF8.self) }
        var summary = "ZIP archive, \(entries.count) \(entries.count == 1 ? "entry" : "entries")"
        let uncompressed = entries.reduce(UInt64(0)) { $0 &+ $1.uncompressedSize }
        if !entries.isEmpty { summary += ", \(FieldText.bytes(Int64(clamping: uncompressed))) uncompressed" }
        if names.contains("[Content_Types].xml") {
            if names.contains(where: { $0.hasPrefix("word/") }) { summary += ", a Word document" }
            else if names.contains(where: { $0.hasPrefix("xl/") }) { summary += ", an Excel workbook" }
            else if names.contains(where: { $0.hasPrefix("ppt/") }) { summary += ", a PowerPoint presentation" }
            else { summary += ", an Office Open XML package" }
        } else if names.contains("AndroidManifest.xml") {
            summary += ", an Android package"
        } else if names.contains("META-INF/MANIFEST.MF") {
            summary += ", a Java archive"
        } else if names.first == "mimetype" {
            summary += ", an OpenDocument or EPUB file"
        }
        if eocd != nil { summary += ", comment \(archiveComment) bytes" } else { summary += ", end record missing" }
        outcome.summary = summary
        return outcome
    }
}
