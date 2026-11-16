import Foundation

/// An ELF program, library or object file taken apart: the file header, the program headers (what the loader maps),
/// the section headers (what the linker and debuggers use), and the sections themselves, with the ones that have a
/// layout of their own opened: symbols, the dynamic table, notes, relocations, and string tables.
/// Both classes (32 and 64 bit) and both byte orders are read.
enum ELFParser: FormatParser {
    static let identity = FormatIdentity(id: "elf", name: "an ELF program or library", detail: "Executable and Linkable Format", hasParser: true)

    static func matches(head: [UInt8], length: Int64) -> Bool {
        head.count >= 6 && head[0] == 0x7F && head[1] == 0x45 && head[2] == 0x4C && head[3] == 0x46 && (head[4] == 1 || head[4] == 2) && (head[5] == 1 || head[5] == 2)
    }

    // MARK: Words

    static func name(_ raw: UInt64, in table: [UInt64: String]) -> String {
        table[raw].map { "\(raw) · \($0)" } ?? "\(raw)"
    }

    static let fileTypes: [UInt64: String] = [0: "none", 1: "relocatable object", 2: "executable", 3: "shared object or position-independent executable", 4: "core dump"]

    static let machines: [UInt64: String] = [
        0: "none", 2: "SPARC", 3: "Intel 80386", 4: "Motorola 68000", 6: "Intel MCU", 8: "MIPS", 20: "PowerPC", 21: "PowerPC 64-bit", 22: "IBM S/390",
        40: "ARM", 42: "SuperH", 43: "SPARC V9", 50: "Itanium", 62: "x86-64", 83: "AVR", 92: "OpenRISC", 94: "Xtensa", 105: "MSP430", 164: "Qualcomm Hexagon",
        183: "AArch64", 189: "MicroBlaze", 243: "RISC-V", 247: "Linux BPF", 258: "LoongArch"
    ]

    static let abis: [UInt64: String] = [0: "UNIX System V", 1: "HP-UX", 2: "NetBSD", 3: "Linux", 6: "Solaris", 9: "FreeBSD", 12: "OpenBSD", 97: "ARM", 255: "standalone"]

    static let segmentTypes: [UInt64: String] = [
        0: "NULL", 1: "LOAD", 2: "DYNAMIC", 3: "INTERP", 4: "NOTE", 5: "SHLIB", 6: "PHDR", 7: "TLS",
        0x6474_E550: "GNU_EH_FRAME", 0x6474_E551: "GNU_STACK", 0x6474_E552: "GNU_RELRO", 0x6474_E553: "GNU_PROPERTY", 0x7000_0001: "ARM_EXIDX"
    ]

    static let sectionTypes: [UInt64: String] = [
        0: "NULL", 1: "PROGBITS", 2: "SYMTAB", 3: "STRTAB", 4: "RELA", 5: "HASH", 6: "DYNAMIC", 7: "NOTE", 8: "NOBITS", 9: "REL", 10: "SHLIB", 11: "DYNSYM",
        14: "INIT_ARRAY", 15: "FINI_ARRAY", 16: "PREINIT_ARRAY", 17: "GROUP", 18: "SYMTAB_SHNDX", 0x6FFF_FFF6: "GNU_HASH", 0x6FFF_FFFD: "GNU_VERDEF",
        0x6FFF_FFFE: "GNU_VERNEED", 0x6FFF_FFFF: "GNU_VERSYM", 0x7000_0001: "ARM_EXIDX"
    ]

    static let dynamicTags: [UInt64: String] = [
        0: "NULL", 1: "NEEDED", 2: "PLTRELSZ", 3: "PLTGOT", 4: "HASH", 5: "STRTAB", 6: "SYMTAB", 7: "RELA", 8: "RELASZ", 9: "RELAENT", 10: "STRSZ", 11: "SYMENT",
        12: "INIT", 13: "FINI", 14: "SONAME", 15: "RPATH", 16: "SYMBOLIC", 17: "REL", 18: "RELSZ", 19: "RELENT", 20: "PLTREL", 21: "DEBUG", 22: "TEXTREL",
        23: "JMPREL", 24: "BIND_NOW", 25: "INIT_ARRAY", 26: "FINI_ARRAY", 27: "INIT_ARRAYSZ", 28: "FINI_ARRAYSZ", 29: "RUNPATH", 30: "FLAGS",
        0x6FFF_FEF5: "GNU_HASH", 0x6FFF_FFF0: "VERSYM", 0x6FFF_FFFB: "FLAGS_1", 0x6FFF_FFFE: "VERNEED", 0x6FFF_FFFF: "VERNEEDNUM"
    ]

    static let symbolTypes: [UInt64: String] = [0: "NOTYPE", 1: "OBJECT", 2: "FUNC", 3: "SECTION", 4: "FILE", 5: "COMMON", 6: "TLS", 10: "GNU_IFUNC"]
    static let symbolBinds: [UInt64: String] = [0: "LOCAL", 1: "GLOBAL", 2: "WEAK", 10: "GNU_UNIQUE"]

    static func segmentFlags(_ raw: UInt64) -> String {
        let letters = (raw & 4 != 0 ? "R" : "") + (raw & 2 != 0 ? "W" : "") + (raw & 1 != 0 ? "X" : "")
        return FieldText.hexNumber(raw, size: 4) + (letters.isEmpty ? "" : " · " + letters)
    }

    static func sectionFlags(_ raw: UInt64) -> String {
        let names: [(UInt64, String)] = [(0x1, "WRITE"), (0x2, "ALLOC"), (0x4, "EXECINSTR"), (0x10, "MERGE"), (0x20, "STRINGS"), (0x40, "INFO_LINK"), (0x80, "LINK_ORDER"),
                                         (0x100, "OS_NONCONFORMING"), (0x200, "GROUP"), (0x400, "TLS"), (0x800, "COMPRESSED")]
        let set = names.filter { raw & $0.0 != 0 }.map { $0.1 }
        return FieldText.hexNumber(raw, size: 4) + (set.isEmpty ? "" : " · " + set.joined(separator: ", "))
    }

    static func visibility(_ raw: UInt64) -> String {
        ["0 · DEFAULT", "1 · INTERNAL", "2 · HIDDEN", "3 · PROTECTED"][Int(raw & 3)]
    }

    static func sectionIndex(_ raw: UInt64) -> String {
        switch raw {
        case 0: return "0 · UND (undefined)"
        case 0xFFF1: return "65521 · ABS (absolute)"
        case 0xFFF2: return "65522 · COMMON"
        case 0xFFFF: return "65535 · XINDEX"
        default: return "\(raw)"
        }
    }

    /// A NUL-ended string inside `bytes` from `index`, or nil outside them.
    static func string(_ bytes: [UInt8], at index: UInt64) -> String? {
        guard index < UInt64(bytes.count) else { return nil }
        var end = Int(index)
        while end < bytes.count, bytes[end] != 0, end - Int(index) < 512 { end += 1 }
        return String(decoding: bytes[Int(index)..<end].map { $0 < 0x20 || $0 > 0x7E ? UInt8(ascii: ".") : $0 }, as: UTF8.self)
    }

    // MARK: What the headers say

    private struct Section {
        var index = 0
        var nameIndex: UInt64 = 0
        var type: UInt64 = 0
        var flags: UInt64 = 0
        var address: UInt64 = 0
        var offset: UInt64 = 0
        var size: UInt64 = 0
        var link: UInt64 = 0
        var info: UInt64 = 0
        var align: UInt64 = 0
        var entrySize: UInt64 = 0
        var name = ""
    }

    private struct Layout {
        let wide: Bool
        let endianness: Endianness
        var word: Int { wide ? 8 : 4 }
    }

    private static func section(_ window: ByteWindow, at start: Int64, index: Int, layout: Layout) -> Section? {
        let e = layout.endianness
        let w = layout.word
        let base = start
        guard let name = window.uint(base, size: 4, e), let type = window.uint(base + 4, size: 4, e),
              let flags = window.uint(base + 8, size: w, e), let address = window.uint(base + 8 + Int64(w), size: w, e),
              let offset = window.uint(base + 8 + 2 * Int64(w), size: w, e), let size = window.uint(base + 8 + 3 * Int64(w), size: w, e),
              let link = window.uint(base + 8 + 4 * Int64(w), size: 4, e), let info = window.uint(base + 12 + 4 * Int64(w), size: 4, e),
              let align = window.uint(base + 16 + 4 * Int64(w), size: w, e), let entry = window.uint(base + 16 + 5 * Int64(w), size: w, e) else { return nil }
        return Section(index: index, nameIndex: name, type: type, flags: flags, address: address, offset: offset, size: size, link: link, info: info, align: align, entrySize: entry)
    }

    /// The bytes of a section, if they are in the file and no more than `limit`.
    private static func contents(_ source: ByteSource, _ section: Section?, limit: Int64) -> [UInt8] {
        guard let section, section.type != 8, section.offset < UInt64(source.count) else { return [] }
        let start = Int64(section.offset)
        let length = min(Int64(clamping: section.size), limit, source.count - start)
        guard length > 0 else { return [] }
        return source.read(start..<(start + length))
    }

    // MARK: Headers

    private static func headerFields(_ f: inout FieldList, layout: Layout, total: Int64) -> (phoff: Int64, shoff: Int64, phentsize: Int64, phnum: Int64, shentsize: Int64, shnum: Int64, shstrndx: Int64, machine: UInt64)? {
        let w = layout.word
        let wide = layout.wide
        f.group("Identification", at: 0, length: 16, kind: .container, value: (wide ? "64-bit, " : "32-bit, ") + (layout.endianness == .little ? "little-endian" : "big-endian")) { g in
            g.bytes("Magic", at: 0, length: 4, kind: .magic, value: "7F 45 4C 46", note: "The byte 7F and the letters ELF.")
            g.uint("Class", at: 4, size: 1, value: { $0 == 1 ? "1 · 32-bit" : ($0 == 2 ? "2 · 64-bit" : "\($0)") }, note: { _ in "Decides how wide addresses and sizes are in everything below." })
            g.uint("Data encoding", at: 5, size: 1, value: { $0 == 1 ? "1 · little-endian" : ($0 == 2 ? "2 · big-endian" : "\($0)") }, note: { _ in "The byte order of every number in the file." })
            g.uint("Header version", at: 6, size: 1)
            g.uint("OS ABI", at: 7, size: 1, value: { name($0, in: abis) })
            g.uint("ABI version", at: 8, size: 1)
            g.bytes("Padding", at: 9, length: 7, kind: .padding)
        }
        f.uint("Type", at: 16, size: 2, value: { name($0, in: fileTypes) })
        let machine = f.uint("Machine", at: 18, size: 2, value: { name($0, in: machines) }) ?? 0
        f.uint("Version", at: 20, size: 4)
        f.uint("Entry point", at: 24, size: w, kind: .address, value: { FieldText.hexNumber($0, size: w) }, note: { _ in "Where execution begins, as an address in the program's own memory." })
        let phoff = f.uint("Program headers offset", at: 24 + Int64(w), size: w) ?? 0
        let shoff = f.uint("Section headers offset", at: 24 + 2 * Int64(w), size: w) ?? 0
        let at = 24 + 3 * Int64(w)
        f.uint("Flags", at: at, size: 4, kind: .flags, value: { FieldText.hexNumber($0, size: 4) })
        f.uint("Header size", at: at + 4, size: 2)
        let phentsize = f.uint("Program header size", at: at + 6, size: 2) ?? 0
        let phnum = f.uint("Program header count", at: at + 8, size: 2) ?? 0
        let shentsize = f.uint("Section header size", at: at + 10, size: 2) ?? 0
        let shnum = f.uint("Section header count", at: at + 12, size: 2) ?? 0
        let shstrndx = f.uint("Section name table index", at: at + 14, size: 2) ?? 0
        guard !f.truncated else { return nil }
        let limit = Int64(UInt32.max)
        return (min(Int64(clamping: phoff), limit), min(Int64(clamping: shoff), limit), Int64(phentsize), Int64(phnum), Int64(shentsize), Int64(shnum), Int64(shstrndx), machine)
    }

    private static func programHeaderNodes(id: String, source: ByteSource, layout: Layout, start: Int64, entrySize: Int64) -> [FieldNode] {
        let window = ByteWindow(source: source, at: start, count: Int(min(entrySize, 4096)))
        var f = FieldList(idPrefix: id, window: window, endianness: layout.endianness)
        let w = layout.word
        func field(_ name: String, _ at: Int64, _ size: Int, value: ((UInt64) -> String)? = nil, kind: FieldNode.Kind = .integer) {
            f.uint(name, at: start + at, size: size, kind: kind, value: value)
        }
        field("Type", 0, 4, value: { name($0, in: segmentTypes) })
        if layout.wide {
            field("Flags", 4, 4, value: { segmentFlags($0) }, kind: .flags)
            field("Offset in the file", 8, 8)
            field("Virtual address", 16, 8, value: { FieldText.hexNumber($0, size: 8) }, kind: .address)
            field("Physical address", 24, 8, value: { FieldText.hexNumber($0, size: 8) }, kind: .address)
            field("Size in the file", 32, 8, value: { "\($0) bytes" })
            field("Size in memory", 40, 8, value: { "\($0) bytes" })
            field("Alignment", 48, 8)
        } else {
            field("Offset in the file", 4, w)
            field("Virtual address", 8, w, value: { FieldText.hexNumber($0, size: 4) }, kind: .address)
            field("Physical address", 12, w, value: { FieldText.hexNumber($0, size: 4) }, kind: .address)
            field("Size in the file", 16, w, value: { "\($0) bytes" })
            field("Size in memory", 20, w, value: { "\($0) bytes" })
            field("Flags", 24, 4, value: { segmentFlags($0) }, kind: .flags)
            field("Alignment", 28, w)
        }
        let used: Int64 = layout.wide ? 56 : 32
        if entrySize > used { f.bytes("Extra bytes", at: start + used, length: entrySize - used, kind: .padding) }
        return f.nodes
    }

    private static func sectionHeaderNodes(id: String, source: ByteSource, layout: Layout, start: Int64, entrySize: Int64, names: [UInt8]) -> [FieldNode] {
        let window = ByteWindow(source: source, at: start, count: Int(min(entrySize, 4096)))
        var f = FieldList(idPrefix: id, window: window, endianness: layout.endianness)
        let w = layout.word
        let nameIndex = f.uint("Name", at: start, size: 4, value: { raw in
            string(names, at: raw).map { "\(raw) · \"\($0)\"" } ?? "\(raw)"
        })
        _ = nameIndex
        f.uint("Type", at: start + 4, size: 4, value: { name($0, in: sectionTypes) })
        f.uint("Flags", at: start + 8, size: w, kind: .flags, value: { sectionFlags($0) })
        f.uint("Address", at: start + 8 + Int64(w), size: w, kind: .address, value: { FieldText.hexNumber($0, size: w) })
        f.uint("Offset in the file", at: start + 8 + 2 * Int64(w), size: w)
        f.uint("Size", at: start + 8 + 3 * Int64(w), size: w, value: { "\($0) bytes" })
        f.uint("Link", at: start + 8 + 4 * Int64(w), size: 4)
        f.uint("Info", at: start + 12 + 4 * Int64(w), size: 4)
        f.uint("Alignment", at: start + 16 + 4 * Int64(w), size: w)
        f.uint("Entry size", at: start + 16 + 5 * Int64(w), size: w)
        let used = 16 + 6 * Int64(w)
        if entrySize > used { f.bytes("Extra bytes", at: start + used, length: entrySize - used, kind: .padding) }
        return f.nodes
    }

    // MARK: The contents of a section

    /// The most entries of a table that are opened one by one.
    private static let listed = 4096

    private static func sectionChildren(id: String, source: ByteSource, layout: Layout, section: Section, length: Int64, sections: [Section]) -> [FieldNode] {
        let start = Int64(section.offset)
        let w = layout.word
        let window = ByteWindow(source: source, at: start, count: Int(min(length, 1 << 20)))
        var f = FieldList(idPrefix: id, window: window, endianness: layout.endianness)
        let linked = section.link < UInt64(sections.count) ? sections[Int(section.link)] : nil
        let strings = contents(source, linked, limit: 4 << 20)
        switch section.type {
        case 2, 11:
            let size = Int64(clamping: section.entrySize) > 0 ? min(Int64(clamping: section.entrySize), 4096) : (layout.wide ? 24 : 16)
            let minimum: Int64 = layout.wide ? 24 : 16
            guard size >= minimum else { break }
            let count = Int(min(length / size, Int64(listed)))
            for index in 0..<count {
                let at = start + Int64(index) * size
                let entry = ByteWindow(source: source, at: at, count: Int(minimum))
                let nameIndex = entry.uint(at, size: 4, layout.endianness) ?? 0
                let label = string(strings, at: nameIndex) ?? ""
                let childID = id + "/symbol-\(index + 1)"
                f.add(FieldNode(id: childID, name: "Symbol \(index)", offset: at, length: size, kind: .container, value: label.isEmpty ? nil : label,
                                children: .deferred(DeferredChildren {
                                    var g = FieldList(idPrefix: childID, window: entry, endianness: layout.endianness)
                                    g.uint("Name", at: at, size: 4, value: { raw in string(strings, at: raw).map { "\(raw) · \"\($0)\"" } ?? "\(raw)" })
                                    func info() {
                                        g.uint("Info", at: at + (layout.wide ? 4 : 12), size: 1, kind: .flags, value: { raw in
                                            "\(FieldText.hexNumber(raw, size: 1)) · \(symbolBinds[raw >> 4] ?? "bind \(raw >> 4)"), \(symbolTypes[raw & 15] ?? "type \(raw & 15)")"
                                        })
                                        g.uint("Visibility", at: at + (layout.wide ? 5 : 13), size: 1, value: { visibility($0) })
                                        g.uint("Section", at: at + (layout.wide ? 6 : 14), size: 2, value: { sectionIndex($0) })
                                    }
                                    if layout.wide {
                                        info()
                                        g.uint("Value", at: at + 8, size: 8, kind: .address, value: { FieldText.hexNumber($0, size: 8) })
                                        g.uint("Size", at: at + 16, size: 8, value: { "\($0) bytes" })
                                    } else {
                                        g.uint("Value", at: at + 4, size: 4, kind: .address, value: { FieldText.hexNumber($0, size: 4) })
                                        g.uint("Size", at: at + 8, size: 4, value: { "\($0) bytes" })
                                        info()
                                    }
                                    return g.nodes
                                })))
            }
            if Int64(count) * size < length {
                f.add(FieldNode(id: id + "/more", name: "More symbols", offset: start + Int64(count) * size, length: length - Int64(count) * size, kind: .bytes,
                                value: count < listed ? FieldText.bytes(length - Int64(count) * size) : "not listed"))
            }
        case 6:
            let size = Int64(2 * w)
            let count = Int(min(length / size, Int64(listed)))
            for index in 0..<count {
                let at = start + Int64(index) * size
                let tag = window.uint(at, size: w, layout.endianness) ?? 0
                let value = window.uint(at + Int64(w), size: w, layout.endianness) ?? 0
                let needsString: Set<UInt64> = [1, 14, 15, 29]
                let text = needsString.contains(tag) ? string(strings, at: value) : nil
                var g = FieldList(idPrefix: id + "/entry-\(index + 1)", window: window, endianness: layout.endianness)
                g.uint("Tag", at: at, size: w, value: { name($0, in: dynamicTags) })
                g.uint("Value", at: at + Int64(w), size: w, value: { raw in text.map { "\(raw) · \"\($0)\"" } ?? FieldText.number(raw, size: w) })
                f.add(FieldNode(id: id + "/entry-\(index + 1)", name: "Entry \(index + 1)", offset: at, length: size, kind: .container,
                                value: (dynamicTags[tag] ?? "\(tag)") + (text.map { " " + $0 } ?? ""), children: .list(g.nodes)))
                if tag == 0 { break }
            }
        case 7:
            var at = start
            var index = 0
            let end = start + min(length, window.end - start)
            while at + 12 <= end, index < listed {
                let nameSize = Int64(window.uint(at, size: 4, layout.endianness) ?? 0)
                let descSize = Int64(window.uint(at + 4, size: 4, layout.endianness) ?? 0)
                let nameLength = (nameSize + 3) & ~3
                let descLength = (descSize + 3) & ~3
                let total = 12 + nameLength + descLength
                guard nameSize <= length, descSize <= length, at + total <= end || at + 12 + nameSize + descSize <= end else { break }
                let noteName = window.slice(at + 12, Int(max(0, nameSize - 1))).map { String(decoding: $0, as: UTF8.self) } ?? ""
                let used = min(total, end - at)
                var g = FieldList(idPrefix: id + "/note-\(index + 1)", window: window, endianness: layout.endianness)
                g.uint("Name size", at: at, size: 4)
                g.uint("Description size", at: at + 4, size: 4)
                g.uint("Type", at: at + 8, size: 4, value: { raw in noteName == "GNU" && raw == 3 ? "3 · build ID" : "\(raw)" })
                if nameSize > 0 { g.bytes("Name", at: at + 12, length: min(nameSize, end - at - 12), kind: .text, value: "\"" + noteName + "\"") }
                if descSize > 0, at + 12 + nameLength < end {
                    g.bytes("Description", at: at + 12 + nameLength, length: min(descSize, end - at - 12 - nameLength))
                }
                f.add(FieldNode(id: id + "/note-\(index + 1)", name: "Note \(index + 1)", offset: at, length: used, kind: .container, value: noteName, children: .list(g.nodes)))
                at += total
                index += 1
            }
        case 3:
            var position = 0
            var index = 0
            let bytes = window.bytes
            while position < bytes.count, index < listed {
                var end = position
                while end < bytes.count, bytes[end] != 0 { end += 1 }
                let text = String(decoding: bytes[position..<end].map { $0 < 0x20 || $0 > 0x7E ? UInt8(ascii: ".") : $0 }, as: UTF8.self)
                let take = Int64(min(end + 1, bytes.count) - position)
                f.add(FieldNode(id: id + "/string-\(index + 1)", name: "String at \(position)", offset: start + Int64(position), length: take, kind: .text, value: "\"" + text + "\""))
                position = end + 1
                index += 1
            }
        case 4, 9:
            let rela = section.type == 4
            let size = Int64(clamping: section.entrySize) > 0 ? min(Int64(clamping: section.entrySize), 4096) : Int64(w * (rela ? 3 : 2))
            let minimum = Int64(w * (rela ? 3 : 2))
            guard size >= minimum else { break }
            let count = Int(min(length / size, Int64(listed)))
            for index in 0..<count {
                let at = start + Int64(index) * size
                var g = FieldList(idPrefix: id + "/relocation-\(index + 1)", window: window, endianness: layout.endianness)
                g.uint("Offset", at: at, size: w, kind: .address, value: { FieldText.hexNumber($0, size: w) })
                let info = g.uint("Info", at: at + Int64(w), size: w, kind: .flags, value: { raw in
                    let symbol = layout.wide ? raw >> 32 : raw >> 8
                    let type = layout.wide ? raw & 0xFFFF_FFFF : raw & 0xFF
                    return "\(FieldText.hexNumber(raw, size: w)) · symbol \(symbol), type \(type)"
                }) ?? 0
                if rela { g.uint("Addend", at: at + 2 * Int64(w), size: w, value: { raw in
                    layout.wide ? "\(Int64(bitPattern: raw))" : "\(Int32(bitPattern: UInt32(truncatingIfNeeded: raw)))"
                }) }
                _ = info
                f.add(FieldNode(id: id + "/relocation-\(index + 1)", name: "Relocation \(index + 1)", offset: at, length: size, kind: .container, children: .list(g.nodes)))
            }
            if Int64(count) * size < length {
                f.add(FieldNode(id: id + "/more", name: "More relocations", offset: start + Int64(count) * size, length: length - Int64(count) * size, kind: .bytes, value: "not listed"))
            }
        default:
            break
        }
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
        let head = ByteWindow(source: source, at: 0, count: 64)
        guard head.has(0, 16), head.u8(4) == 1 || head.u8(4) == 2 else {
            outcome.problems = ["The file ends inside the ELF identification."]
            return outcome
        }
        let layout = Layout(wide: head.u8(4) == 2, endianness: head.u8(5) == 2 ? .big : .little)
        let headerLength: Int64 = layout.wide ? 64 : 52

        var header = FieldList(idPrefix: "elf/header", window: head, endianness: layout.endianness)
        let numbers = headerFields(&header, layout: layout, total: total)
        var pieces: [Piece] = [Piece(offset: 0, length: min(headerLength, total),
                                     node: FieldNode(id: "elf/header", name: "ELF header", offset: 0, length: min(headerLength, total), kind: .container,
                                                     value: nil, note: "Says what kind of file this is, for what machine, and where its two tables of headers are.", children: .list(header.nodes)))]
        guard let numbers else {
            outcome.roots = pieces.map { $0.node }
            outcome.problems = ["The file ends inside the ELF header."]
            outcome.summary = "ELF file, cut off in its header"
            return outcome
        }

        // Program headers.
        let phTable = numbers.phentsize * numbers.phnum
        if numbers.phoff > 0, numbers.phnum > 0 {
            if numbers.phentsize < (layout.wide ? 56 : 32) { problems.append("Program headers are said to be \(numbers.phentsize) bytes each, less than the \(layout.wide ? 56 : 32) they need.") }
            let available = max(0, min(phTable, total - numbers.phoff))
            if numbers.phoff >= total { problems.append("The program header table is said to start at \(numbers.phoff), outside the file.") }
            else {
                if available < phTable { problems.append("The program header table is cut off by the end of the file.") }
                var children: [FieldNode] = []
                let count = Int(min(numbers.phnum, available / max(numbers.phentsize, 1), Int64(context.maxRecords)))
                for index in 0..<count where numbers.phentsize >= (layout.wide ? 56 : 32) {
                    let at = numbers.phoff + Int64(index) * numbers.phentsize
                    let childID = "elf/program-headers/entry-\(index + 1)"
                    let window = ByteWindow(source: source, at: at, count: 8)
                    let type = window.uint(at, size: 4, layout.endianness) ?? 0
                    children.append(FieldNode(id: childID, name: "Segment \(index)", offset: at, length: min(numbers.phentsize, total - at), kind: .container,
                                              value: segmentTypes[type] ?? "\(type)",
                                              children: .deferred(DeferredChildren { programHeaderNodes(id: childID, source: source, layout: layout, start: at, entrySize: numbers.phentsize) })))
                }
                if available > 0 {
                    pieces.append(Piece(offset: numbers.phoff, length: available,
                                        node: FieldNode(id: "elf/program-headers", name: "Program headers", offset: numbers.phoff, length: available, kind: .container,
                                                        value: "\(numbers.phnum) segments", note: "What the loader maps into memory: each says which bytes of the file go where, and how they may be used.",
                                                        children: .list(children))))
                }
            }
        }

        // Section headers.
        var sections: [Section] = []
        var shnum = numbers.shnum
        var shstrndx = numbers.shstrndx
        if numbers.shoff > 0, numbers.shoff < total {
            let first = ByteWindow(source: source, at: numbers.shoff, count: Int(min(numbers.shentsize, 4096)))
            // An archive with 65280 sections or more says 0 here and keeps the count in the first header.
            if shnum == 0, numbers.shentsize >= (layout.wide ? 64 : 40), let extended = section(first, at: numbers.shoff, index: 0, layout: layout) { shnum = Int64(min(extended.size, UInt64(context.maxRecords))) }
            if shstrndx == 0xFFFF, let extended = section(first, at: numbers.shoff, index: 0, layout: layout) { shstrndx = Int64(min(extended.link, UInt64(UInt32.max))) }
            if numbers.shentsize < (layout.wide ? 64 : 40), shnum > 0 { problems.append("Section headers are said to be \(numbers.shentsize) bytes each, less than the \(layout.wide ? 64 : 40) they need.") }
            else {
                var at = numbers.shoff
                var window = ByteWindow(source: source, at: at, count: 1 << 20)
                let count = min(shnum, Int64(context.maxRecords))
                for index in 0..<Int(count) {
                    if !window.has(at, Int(numbers.shentsize)) { window = ByteWindow(source: source, at: at, count: 1 << 20) }
                    guard let entry = section(window, at: at, index: index, layout: layout) else {
                        problems.append("The section header table is cut off after \(index) of \(shnum) entries.")
                        break
                    }
                    sections.append(entry)
                    at += numbers.shentsize
                }
            }
        } else if numbers.shoff >= total, numbers.shoff > 0 {
            problems.append("The section header table is said to start at \(numbers.shoff), outside the file.")
        }
        let names = shstrndx < Int64(sections.count) ? contents(source, sections[Int(shstrndx)], limit: 4 << 20) : []
        for index in sections.indices { sections[index].name = string(names, at: sections[index].nameIndex) ?? "" }

        if !sections.isEmpty {
            var children: [FieldNode] = []
            for entry in sections {
                let at = numbers.shoff + Int64(entry.index) * numbers.shentsize
                let childID = "elf/section-headers/entry-\(entry.index + 1)"
                children.append(FieldNode(id: childID, name: "Header \(entry.index)", offset: at, length: min(numbers.shentsize, total - at), kind: .container,
                                          value: entry.name.isEmpty ? name(entry.type, in: sectionTypes) : entry.name,
                                          children: .deferred(DeferredChildren { sectionHeaderNodes(id: childID, source: source, layout: layout, start: at, entrySize: numbers.shentsize, names: names) })))
            }
            let length = min(Int64(sections.count) * numbers.shentsize, total - numbers.shoff)
            pieces.append(Piece(offset: numbers.shoff, length: length,
                                node: FieldNode(id: "elf/section-headers", name: "Section headers", offset: numbers.shoff, length: length, kind: .container,
                                                value: "\(shnum) sections", note: "What a linker or debugger uses: each names a section and says where its bytes are.", children: .list(children))))
        }

        // The sections' own bytes.
        var tableLowest = pieces.map { $0.offset }.min() ?? total
        tableLowest = min(tableLowest, total)
        for entry in sections where entry.type != 0 && entry.type != 8 && entry.size > 0 {
            guard entry.offset < UInt64(total) else {
                problems.append("Section \(entry.index) (\(entry.name)) is said to start at \(entry.offset), outside the file.")
                continue
            }
            let start = Int64(entry.offset)
            var length = min(Int64(clamping: entry.size), total - start)
            if length < Int64(clamping: entry.size) { problems.append("Section \(entry.index) (\(entry.name)) is cut off by the end of the file.") }
            if length <= 0 { continue }
            _ = tableLowest
            let id = "elf/section-\(entry.index)"
            let copy = entry
            let held = length
            let value = "\(name(entry.type, in: sectionTypes).components(separatedBy: " · ").last ?? ""), \(FieldText.bytes(Int64(clamping: entry.size)))"
            let sectionsCopy = sections
            length = held
            pieces.append(Piece(offset: start, length: held,
                                node: FieldNode(id: id, name: "Section \(entry.name.isEmpty ? "\(entry.index)" : entry.name)", offset: start, length: held, kind: .container, value: value,
                                                children: .deferred(DeferredChildren { sectionChildren(id: id, source: source, layout: layout, section: copy, length: held, sections: sectionsCopy) }))))
        }

        pieces.sort { $0.offset < $1.offset || ($0.offset == $1.offset && $0.length > $1.length) }
        var cursor: Int64 = 0
        var roots: [FieldNode] = []
        var gapCount = 0
        for piece in pieces where piece.length > 0 {
            if piece.offset < cursor {
                problems.append("\(piece.node.name) overlaps what comes before it, and is not shown again.")
                continue
            }
            if piece.offset > cursor {
                gapCount += 1
                roots.append(FieldNode(id: "elf/gap-\(gapCount)", name: "Bytes no header accounts for", offset: cursor, length: piece.offset - cursor, kind: .padding,
                                       value: FieldText.bytes(piece.offset - cursor), note: "Padding for alignment, or data that only a program headers' segment covers."))
            }
            roots.append(piece.node)
            cursor = piece.offset + piece.length
        }
        if cursor < total {
            roots.append(FieldNode(id: "elf/rest", name: "Bytes no header accounts for", offset: cursor, length: total - cursor, kind: .padding, value: FieldText.bytes(total - cursor)))
        }
        outcome.roots = roots
        outcome.problems = Array(problems.prefix(20))

        let kind = ByteWindow(source: source, at: 16, count: 2).uint(16, size: 2, layout.endianness).flatMap { fileTypes[$0] } ?? "file"
        let machineName = machines[numbers.machine] ?? "machine \(numbers.machine)"
        outcome.summary = "ELF \(layout.wide ? "64-bit" : "32-bit") \(layout.endianness == .little ? "little-endian" : "big-endian") \(kind), \(machineName), \(numbers.phnum) \(numbers.phnum == 1 ? "segment" : "segments"), \(shnum) \(shnum == 1 ? "section" : "sections")"
        return outcome
    }
}
