import Foundation

/// A Mach-O file (macOS and iOS programs, libraries and objects) taken apart: the header, the load commands (what the
/// loader reads: segments and their sections, the symbol tables, which libraries are needed, the build and the
/// entry point) and the bytes they point at. A universal ("fat") file holds several of these, one per architecture,
/// and each is shown where it lies.
enum MachOParser: FormatParser {
    static let identity = FormatIdentity(id: "macho", name: "a Mach-O program or library", detail: "Mach-O, thin or universal", hasParser: true)

    static func matches(head: [UInt8], length: Int64) -> Bool {
        guard head.count >= 8 else { return false }
        let magic = UInt32(head[0]) << 24 | UInt32(head[1]) << 16 | UInt32(head[2]) << 8 | UInt32(head[3])
        switch magic {
        case 0xFEED_FACE, 0xFEED_FACF, 0xCEFA_EDFE, 0xCFFA_EDFE:
            return true
        case 0xCAFE_BABE, 0xCAFE_BABF:
            // A Java class file begins the same way: its next four bytes are a version, a fat file's are a small count.
            let count = UInt32(head[4]) << 24 | UInt32(head[5]) << 16 | UInt32(head[6]) << 8 | UInt32(head[7])
            let entry: Int64 = magic == 0xCAFE_BABE ? 20 : 32
            return count >= 1 && count < 45 && 8 + Int64(count) * entry <= length
        default:
            return false
        }
    }

    // MARK: Words

    static func name(_ raw: UInt64, in table: [UInt64: String]) -> String {
        table[raw].map { "\(raw) · \($0)" } ?? "\(raw)"
    }

    static let cpuTypes: [UInt64: String] = [
        1: "VAX", 6: "MC680x0", 7: "x86", 0x0100_0007: "x86-64", 10: "MC98000", 11: "HPPA", 12: "ARM", 0x0100_000C: "ARM64", 0x0200_000C: "ARM64_32",
        13: "MC88000", 14: "SPARC", 15: "i860", 18: "PowerPC", 0x0100_0012: "PowerPC 64"
    ]

    static let fileTypes: [UInt64: String] = [
        1: "OBJECT (relocatable object)", 2: "EXECUTE (program)", 3: "FVMLIB", 4: "CORE (core dump)", 5: "PRELOAD", 6: "DYLIB (dynamic library)", 7: "DYLINKER",
        8: "BUNDLE", 9: "DYLIB_STUB", 10: "DSYM (debug symbols)", 11: "KEXT_BUNDLE", 12: "FILESET"
    ]

    static let flagNames: [(UInt64, String)] = [
        (0x1, "NOUNDEFS"), (0x2, "INCRLINK"), (0x4, "DYLDLINK"), (0x8, "BINDATLOAD"), (0x10, "PREBOUND"), (0x20, "SPLIT_SEGS"), (0x40, "LAZY_INIT"),
        (0x80, "TWOLEVEL"), (0x100, "FORCE_FLAT"), (0x200, "NOMULTIDEFS"), (0x400, "NOFIXPREBINDING"), (0x800, "PREBINDABLE"), (0x1000, "ALLMODSBOUND"),
        (0x2000, "SUBSECTIONS_VIA_SYMBOLS"), (0x4000, "CANONICAL"), (0x8000, "WEAK_DEFINES"), (0x10000, "BINDS_TO_WEAK"), (0x20000, "ALLOW_STACK_EXECUTION"),
        (0x40000, "ROOT_SAFE"), (0x80000, "SETUID_SAFE"), (0x100000, "NO_REEXPORTED_DYLIBS"), (0x200000, "PIE"), (0x400000, "DEAD_STRIPPABLE_DYLIB"),
        (0x800000, "HAS_TLV_DESCRIPTORS"), (0x1000000, "NO_HEAP_EXECUTION"), (0x2000000, "APP_EXTENSION_SAFE")
    ]

    static func flagsText(_ raw: UInt64) -> String {
        let set = flagNames.filter { raw & $0.0 != 0 }.map { $0.1 }
        return FieldText.hexNumber(raw, size: 4) + (set.isEmpty ? "" : " · " + set.joined(separator: ", "))
    }

    static let commands: [UInt64: String] = [
        0x1: "LC_SEGMENT", 0x2: "LC_SYMTAB", 0x3: "LC_SYMSEG", 0x4: "LC_THREAD", 0x5: "LC_UNIXTHREAD", 0x6: "LC_LOADFVMLIB", 0x7: "LC_IDFVMLIB", 0x8: "LC_IDENT",
        0x9: "LC_FVMFILE", 0xA: "LC_PREPAGE", 0xB: "LC_DYSYMTAB", 0xC: "LC_LOAD_DYLIB", 0xD: "LC_ID_DYLIB", 0xE: "LC_LOAD_DYLINKER", 0xF: "LC_ID_DYLINKER",
        0x10: "LC_PREBOUND_DYLIB", 0x11: "LC_ROUTINES", 0x12: "LC_SUB_FRAMEWORK", 0x13: "LC_SUB_UMBRELLA", 0x14: "LC_SUB_CLIENT", 0x15: "LC_SUB_LIBRARY",
        0x16: "LC_TWOLEVEL_HINTS", 0x17: "LC_PREBIND_CKSUM", 0x8000_0018: "LC_LOAD_WEAK_DYLIB", 0x19: "LC_SEGMENT_64", 0x1A: "LC_ROUTINES_64", 0x1B: "LC_UUID",
        0x8000_001C: "LC_RPATH", 0x1D: "LC_CODE_SIGNATURE", 0x1E: "LC_SEGMENT_SPLIT_INFO", 0x8000_001F: "LC_REEXPORT_DYLIB", 0x20: "LC_LAZY_LOAD_DYLIB",
        0x21: "LC_ENCRYPTION_INFO", 0x22: "LC_DYLD_INFO", 0x8000_0022: "LC_DYLD_INFO_ONLY", 0x8000_0023: "LC_LOAD_UPWARD_DYLIB", 0x24: "LC_VERSION_MIN_MACOSX",
        0x25: "LC_VERSION_MIN_IPHONEOS", 0x26: "LC_FUNCTION_STARTS", 0x27: "LC_DYLD_ENVIRONMENT", 0x8000_0028: "LC_MAIN", 0x29: "LC_DATA_IN_CODE",
        0x2A: "LC_SOURCE_VERSION", 0x2B: "LC_DYLIB_CODE_SIGN_DRS", 0x2C: "LC_ENCRYPTION_INFO_64", 0x2D: "LC_LINKER_OPTION", 0x2E: "LC_LINKER_OPTIMIZATION_HINT",
        0x2F: "LC_VERSION_MIN_TVOS", 0x30: "LC_VERSION_MIN_WATCHOS", 0x31: "LC_NOTE", 0x32: "LC_BUILD_VERSION", 0x8000_0033: "LC_DYLD_EXPORTS_TRIE",
        0x8000_0034: "LC_DYLD_CHAINED_FIXUPS", 0x8000_0035: "LC_FILESET_ENTRY"
    ]

    static let platforms: [UInt64: String] = [1: "macOS", 2: "iOS", 3: "tvOS", 4: "watchOS", 5: "bridgeOS", 6: "Mac Catalyst", 7: "iOS Simulator", 8: "tvOS Simulator",
                                              9: "watchOS Simulator", 10: "DriverKit", 11: "visionOS", 12: "visionOS Simulator"]

    static let sectionTypes: [UInt64: String] = [
        0: "REGULAR", 1: "ZEROFILL", 2: "CSTRING_LITERALS", 3: "4BYTE_LITERALS", 4: "8BYTE_LITERALS", 5: "LITERAL_POINTERS", 6: "NON_LAZY_SYMBOL_POINTERS",
        7: "LAZY_SYMBOL_POINTERS", 8: "SYMBOL_STUBS", 9: "MOD_INIT_FUNC_POINTERS", 10: "MOD_TERM_FUNC_POINTERS", 11: "COALESCED", 12: "GB_ZEROFILL", 13: "INTERPOSING",
        14: "16BYTE_LITERALS", 15: "DTRACE_DOF", 16: "LAZY_DYLIB_SYMBOL_POINTERS", 17: "THREAD_LOCAL_REGULAR", 18: "THREAD_LOCAL_ZEROFILL",
        19: "THREAD_LOCAL_VARIABLES", 20: "THREAD_LOCAL_VARIABLE_POINTERS", 21: "THREAD_LOCAL_INIT_FUNCTION_POINTERS", 22: "INIT_FUNC_OFFSETS"
    ]

    static func protection(_ raw: UInt64) -> String {
        let letters = (raw & 1 != 0 ? "r" : "-") + (raw & 2 != 0 ? "w" : "-") + (raw & 4 != 0 ? "x" : "-")
        return "\(raw) · \(letters)"
    }

    static func version(_ raw: UInt64) -> String {
        "\(raw >> 16).\((raw >> 8) & 0xFF).\(raw & 0xFF)"
    }

    static func sourceVersion(_ raw: UInt64) -> String {
        "\(raw >> 40).\((raw >> 30) & 0x3FF).\((raw >> 20) & 0x3FF).\((raw >> 10) & 0x3FF).\(raw & 0x3FF)"
    }

    static func uuid(_ bytes: ArraySlice<UInt8>) -> String {
        let hex = bytes.map { String(format: "%02X", $0) }
        guard hex.count == 16 else { return hex.joined() }
        return hex[0..<4].joined() + "-" + hex[4..<6].joined() + "-" + hex[6..<8].joined() + "-" + hex[8..<10].joined() + "-" + hex[10..<16].joined()
    }

    /// A fixed-size name field, up to its first NUL.
    static func fixedName(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes.prefix { $0 != 0 }.map { $0 < 0x20 || $0 > 0x7E ? UInt8(ascii: ".") : $0 }, as: UTF8.self)
    }

    static func symbolType(_ raw: UInt64) -> String {
        var parts: [String] = []
        if raw & 0xE0 != 0 { parts.append("STAB") }
        else {
            let kind: [UInt64: String] = [0: "UNDF", 2: "ABS", 0xA: "INDR", 0xC: "PBUD", 0xE: "SECT"]
            parts.append(kind[raw & 0x0E] ?? "type \(raw & 0x0E)")
            if raw & 0x10 != 0 { parts.append("PEXT") }
        }
        if raw & 1 != 0 { parts.append("EXT") }
        return FieldText.hexNumber(raw, size: 1) + " · " + parts.joined(separator: ", ")
    }

    // MARK: Layout of one thin file

    private struct Layout {
        let wide: Bool
        let endianness: Endianness
        /// Where the thin file starts in the whole file, and how long it is.
        let base: Int64
        let length: Int64
        var word: Int { wide ? 8 : 4 }
    }

    private struct Piece {
        var offset: Int64
        var length: Int64
        var node: FieldNode
    }

    /// The most entries of a table that are opened one by one.
    private static let listed = 4096

    /// Reads one thin Mach-O that lies at `base` for `length` bytes: its nodes (at their offsets in the whole file), what is wrong with it, and a summary.
    private static func parseThin(_ source: ByteSource, base: Int64, length: Int64, prefix: String, context: ParseContext)
        -> (roots: [FieldNode], problems: [String], summary: String) {
        var problems: [String] = []
        let head = ByteWindow(source: source, at: base, count: 32)
        guard head.has(base, 4) else { return ([], ["The file ends before a Mach-O header."], "Mach-O, cut off") }
        let magic = head.uint(base, size: 4, .big) ?? 0
        let wide = magic == 0xFEED_FACF || magic == 0xCFFA_EDFE
        let little = magic == 0xCEFA_EDFE || magic == 0xCFFA_EDFE
        guard magic == 0xFEED_FACE || magic == 0xFEED_FACF || little else {
            return ([FieldNode(id: prefix + "/unknown", name: "Not a Mach-O", offset: base, length: length, kind: .bytes, value: FieldText.bytes(length),
                               note: "These bytes do not begin with a Mach-O magic number (they may be an archive or another format).")],
                    [], "not a Mach-O")
        }
        let layout = Layout(wide: wide, endianness: little ? .little : .big, base: base, length: length)
        let e = layout.endianness
        let headerLength: Int64 = wide ? 32 : 28
        var header = FieldList(idPrefix: prefix + "/header", window: head, endianness: e)
        header.uint("Magic", at: base, size: 4, kind: .magic, value: { _ in
            "\(FieldText.hexNumber(magic, size: 4)) · \(wide ? "64-bit" : "32-bit"), \(little ? "little-endian" : "big-endian")"
        }, note: { _ in "Read in the file's own byte order it is always 0xFEEDFACE or 0xFEEDFACF, which is how the byte order is told." })
        let cpu = header.uint("CPU type", at: base + 4, size: 4, value: { name($0, in: cpuTypes) }) ?? 0
        header.uint("CPU subtype", at: base + 8, size: 4, value: { raw in
            raw & 0xFF00_0000 != 0 ? "\(raw & 0xFFFFFF) · with capability bits \(FieldText.hexNumber(raw >> 24, size: 1))" : "\(raw)"
        })
        let fileType = header.uint("File type", at: base + 12, size: 4, value: { name($0, in: fileTypes) }) ?? 0
        let count = header.uint("Load command count", at: base + 16, size: 4) ?? 0
        let commandsSize = header.uint("Load commands size", at: base + 20, size: 4, value: { "\($0) bytes" }) ?? 0
        header.uint("Flags", at: base + 24, size: 4, kind: .flags, value: { flagsText($0) })
        if wide { header.bytes("Reserved", at: base + 28, length: 4, kind: .padding) }
        let summaryKind = fileTypes[fileType].map { String($0.split(separator: " ").first ?? "") } ?? "file"
        let summary = "\(cpuTypes[cpu] ?? "cpu \(cpu)") \(summaryKind.lowercased()), \(count) load \(count == 1 ? "command" : "commands")"
        var pieces: [Piece] = []
        let headerHeld = max(0, min(headerLength, base + length - base))
        pieces.append(Piece(offset: base, length: min(headerHeld, source.count - base),
                            node: FieldNode(id: prefix + "/header", name: "Mach-O header", offset: base, length: min(headerHeld, source.count - base), kind: .container,
                                            value: summary, note: "The kind of file and machine, and how many load commands follow.", children: .list(header.nodes))))
        guard !header.truncated else {
            return (pieces.map { $0.node }, ["The file ends inside the Mach-O header."], summary)
        }

        // Load commands.
        let commandsStart = base + headerLength
        let commandsEnd = min(commandsStart + Int64(min(commandsSize, UInt64(Int32.max))), base + length, source.count)
        if commandsStart + Int64(min(commandsSize, UInt64(Int32.max))) > base + length { problems.append("The load commands are said to run past the end of the file.") }
        var children: [FieldNode] = []
        var contents: [Piece] = []
        var at = commandsStart
        var index = 0
        var window = ByteWindow(source: source, at: at, count: 1 << 20)
        while index < Int(min(count, UInt64(context.maxRecords))), at + 8 <= commandsEnd, !context.isCancelled() {
            if !window.has(at, 8) { window = ByteWindow(source: source, at: at, count: 1 << 20) }
            guard let command = window.uint(at, size: 4, e), let size = window.uint(at + 4, size: 4, e) else { break }
            guard size >= 8, Int64(size) <= commandsEnd - at else {
                problems.append("Load command \(index + 1) says it is \(size) bytes, which does not fit in the load commands.")
                children.append(FieldNode(id: prefix + "/commands/problem", name: "Load command \(index) (cut short)", offset: at, length: commandsEnd - at, kind: .problem,
                                          value: FieldText.bytes(commandsEnd - at), note: "A load command is at least 8 bytes and lies within the load commands."))
                break
            }
            let commandLength = Int64(size)
            let childID = prefix + "/commands/command-\(index + 1)"
            let label = commands[command] ?? "0x" + String(command, radix: 16, uppercase: true)
            let commandStart = at
            var summaryText: String?
            let body = ByteWindow(source: source, at: at, count: Int(min(commandLength, 1 << 20)))
            // What the command points at, found now so that the layout can show it.
            switch command {
            case 0x1, 0x19:
                let segmentWide = command == 0x19
                let sectionSize: Int64 = segmentWide ? 80 : 68
                let first: Int64 = segmentWide ? 72 : 56
                summaryText = fixedName(body.slice(at + 8, 16) ?? [])
                let sectionCount = Int64(body.uint(at + (segmentWide ? 64 : 48), size: 4, e) ?? 0)
                var k: Int64 = 0
                while k < sectionCount, first + (k + 1) * sectionSize <= commandLength {
                    let s = at + first + k * sectionSize
                    let sectionName = fixedName(body.slice(s, 16) ?? [])
                    let segmentName = fixedName(body.slice(s + 16, 16) ?? [])
                    let w = Int64(segmentWide ? 8 : 4)
                    let size = body.uint(s + 32 + w, size: Int(w), e) ?? 0
                    let offset = body.uint(s + 32 + 2 * w, size: 4, e) ?? 0
                    let flags = body.uint(s + 32 + 2 * w + 16, size: 4, e) ?? 0
                    let type = flags & 0xFF
                    if ![1, 12, 18].contains(type), size > 0, offset > 0 {
                        let start = base + Int64(offset)
                        let held = min(Int64(clamping: size), base + length - start, source.count - start)
                        if Int64(offset) >= length {
                            problems.append("Section \(segmentName),\(sectionName) is said to start at \(offset), outside the file.")
                        } else if held < Int64(clamping: size) {
                            problems.append("Section \(segmentName),\(sectionName) is cut off by the end of the file.")
                        }
                        if held > 0, Int64(offset) < length {
                            contents.append(Piece(offset: start, length: held,
                                                  node: FieldNode(id: prefix + "/section-\(contents.count + 1)", name: "Section \(segmentName),\(sectionName)", offset: start, length: held,
                                                                  kind: .bytes, value: "\(sectionTypes[type] ?? "type \(type)"), \(FieldText.bytes(Int64(clamping: size)))")))
                        }
                    }
                    k += 1
                }
            case 0x2:
                let symoff = Int64(body.uint(at + 8, size: 4, e) ?? 0)
                let nsyms = Int64(body.uint(at + 12, size: 4, e) ?? 0)
                let stroff = Int64(body.uint(at + 16, size: 4, e) ?? 0)
                let strsize = Int64(body.uint(at + 20, size: 4, e) ?? 0)
                let entry: Int64 = wide ? 16 : 12
                let symbolStart = base + symoff
                if symoff >= length, nsyms > 0 { problems.append("The symbol table is said to start at \(symoff), outside the file.") }
                if stroff >= length, strsize > 0 { problems.append("The string table is said to start at \(stroff), outside the file.") }
                if symoff > 0, nsyms > 0, symoff < length {
                    let held = min(nsyms * entry, base + length - symbolStart, source.count - symbolStart)
                    let stringStart = base + stroff
                    let stringHeld = max(0, min(strsize, base + length - stringStart, source.count - stringStart))
                    let strings = stroff > 0 && stroff < length ? Array(source.read(stringStart..<(stringStart + min(stringHeld, 4 << 20)))) : []
                    if held > 0 {
                        let symbolID = prefix + "/symbols"
                        let symbolCount = Int(held / entry)
                        contents.append(Piece(offset: symbolStart, length: held,
                                              node: FieldNode(id: symbolID, name: "Symbol table", offset: symbolStart, length: held, kind: .container, value: "\(nsyms) symbols",
                                                              note: "One record for every name: where it is defined, or that it is borrowed from another library.",
                                                              children: .deferred(DeferredChildren {
                                                                  var f = FieldList(idPrefix: symbolID, window: ByteWindow(base: 0, bytes: []), endianness: e)
                                                                  for number in 0..<min(symbolCount, listed) {
                                                                      let s = symbolStart + Int64(number) * entry
                                                                      let record = ByteWindow(source: source, at: s, count: Int(entry))
                                                                      let strx = record.uint(s, size: 4, e) ?? 0
                                                                      let text = ELFParser.string(strings, at: strx) ?? ""
                                                                      let childID = symbolID + "/symbol-\(number + 1)"
                                                                      f.add(FieldNode(id: childID, name: "Symbol \(number)", offset: s, length: entry, kind: .container, value: text.isEmpty ? nil : text,
                                                                                      children: .deferred(DeferredChildren {
                                                                                          var g = FieldList(idPrefix: childID, window: record, endianness: e)
                                                                                          g.uint("Name", at: s, size: 4, value: { raw in ELFParser.string(strings, at: raw).map { "\(raw) · \"\($0)\"" } ?? "\(raw)" })
                                                                                          g.uint("Type", at: s + 4, size: 1, kind: .flags, value: { symbolType($0) })
                                                                                          g.uint("Section", at: s + 5, size: 1, value: { $0 == 0 ? "0 · none" : "\($0)" })
                                                                                          g.uint("Description", at: s + 6, size: 2, kind: .flags, value: { FieldText.hexNumber($0, size: 2) })
                                                                                          g.uint("Value", at: s + 8, size: Int(wide ? 8 : 4), kind: .address, value: { FieldText.hexNumber($0, size: wide ? 8 : 4) })
                                                                                          return g.nodes
                                                                                      })))
                                                                  }
                                                                  if Int64(min(symbolCount, listed)) * entry < held {
                                                                      f.add(FieldNode(id: symbolID + "/more", name: "More symbols", offset: symbolStart + Int64(min(symbolCount, listed)) * entry,
                                                                                      length: held - Int64(min(symbolCount, listed)) * entry, kind: .bytes, value: "not listed"))
                                                                  }
                                                                  return f.nodes
                                                              }))))
                    }
                    if stringHeld > 0, stroff < length {
                        let stringID = prefix + "/strings"
                        contents.append(Piece(offset: stringStart, length: stringHeld,
                                              node: FieldNode(id: stringID, name: "String table", offset: stringStart, length: stringHeld, kind: .container, value: FieldText.bytes(strsize),
                                                              note: "The names the symbol table points into, each ended by a zero byte.",
                                                              children: .deferred(DeferredChildren {
                                                                  var nodes: [FieldNode] = []
                                                                  var position = 0
                                                                  while position < strings.count, nodes.count < listed {
                                                                      var end = position
                                                                      while end < strings.count, strings[end] != 0 { end += 1 }
                                                                      let text = String(decoding: strings[position..<end].map { $0 < 0x20 || $0 > 0x7E ? UInt8(ascii: ".") : $0 }, as: UTF8.self)
                                                                      nodes.append(FieldNode(id: stringID + "/string-\(nodes.count + 1)", name: "String at \(position)", offset: stringStart + Int64(position),
                                                                                             length: Int64(min(end + 1, strings.count) - position), kind: .text, value: "\"" + text + "\""))
                                                                      position = end + 1
                                                                  }
                                                                  return nodes
                                                              }))))
                    }
                }
            case 0xB:
                let offset = Int64(body.uint(at + 56, size: 4, e) ?? 0)
                let number = Int64(body.uint(at + 60, size: 4, e) ?? 0)
                if offset > 0, number > 0, offset < length {
                    let start = base + offset
                    let held = min(number * 4, base + length - start, source.count - start)
                    if held > 0 {
                        contents.append(Piece(offset: start, length: held, node: FieldNode(id: prefix + "/indirect", name: "Indirect symbol table", offset: start, length: held, kind: .bytes,
                                                                                             value: "\(number) entries", note: "For each stub or pointer in a symbol-pointer section, which symbol it stands for.")))
                    }
                }
            case 0x1D, 0x1E, 0x26, 0x29, 0x2B, 0x2E, 0x8000_0033, 0x8000_0034:
                let offset = Int64(body.uint(at + 8, size: 4, e) ?? 0)
                let size = Int64(body.uint(at + 12, size: 4, e) ?? 0)
                if offset > 0, size > 0, offset < length {
                    let start = base + offset
                    let held = min(size, base + length - start, source.count - start)
                    if held > 0 {
                        let nodeName = (commands[command] ?? "Data").replacingOccurrences(of: "LC_", with: "").lowercased().replacingOccurrences(of: "_", with: " ")
                        if command == 0x1D {
                            let signatureID = prefix + "/signature"
                            contents.append(Piece(offset: start, length: held,
                                                  node: FieldNode(id: signatureID, name: "Code signature", offset: start, length: held, kind: .container, value: FieldText.bytes(size),
                                                                  note: "A SuperBlob: an index of blobs (the code directory, requirements, entitlements, and the signature itself). Always big-endian.",
                                                                  children: .deferred(DeferredChildren { signatureNodes(id: signatureID, source: source, start: start, length: held) }))))
                        } else {
                            contents.append(Piece(offset: start, length: held, node: FieldNode(id: prefix + "/linkedit-\(contents.count + 1)", name: "Data: \(nodeName)", offset: start, length: held, kind: .bytes, value: FieldText.bytes(size))))
                        }
                    }
                }
            case 0x22, 0x8000_0022:
                for (k, label) in ["rebase", "binding", "weak binding", "lazy binding", "export"].enumerated() {
                    let offset = Int64(body.uint(at + 8 + Int64(k) * 8, size: 4, e) ?? 0)
                    let size = Int64(body.uint(at + 12 + Int64(k) * 8, size: 4, e) ?? 0)
                    guard offset > 0, size > 0, offset < length else { continue }
                    let start = base + offset
                    let held = min(size, base + length - start, source.count - start)
                    if held > 0 {
                        contents.append(Piece(offset: start, length: held, node: FieldNode(id: prefix + "/dyld-\(k)", name: "Dyld info: \(label)", offset: start, length: held, kind: .bytes, value: FieldText.bytes(size))))
                    }
                }
            default:
                break
            }
            children.append(FieldNode(id: childID, name: "Load command \(index): \(label)", offset: commandStart, length: commandLength, kind: .container, value: summaryText,
                                      children: .deferred(DeferredChildren { commandNodes(id: childID, source: source, layout: layout, command: command, start: commandStart, length: commandLength) })))
            at += commandLength
            index += 1
        }
        if UInt64(index) < count, !context.isCancelled(), at + 8 > commandsEnd { problems.append("The header says \(count) load commands and \(index) fit in the space given.") }
        let held = commandsEnd - commandsStart
        if held > 0 {
            pieces.append(Piece(offset: commandsStart, length: held,
                                node: FieldNode(id: prefix + "/commands", name: "Load commands", offset: commandsStart, length: held, kind: .container, value: "\(index) commands",
                                                note: "What the loader reads: the segments to map, the libraries to load, where to start, and how the file was built.",
                                                children: .list(children))))
        }
        pieces.append(contentsOf: contents)

        pieces.sort { $0.offset < $1.offset || ($0.offset == $1.offset && $0.length > $1.length) }
        var cursor = base
        var roots: [FieldNode] = []
        var gaps = 0
        for piece in pieces where piece.length > 0 {
            if piece.offset < cursor {
                problems.append("\(piece.node.name) overlaps what comes before it, and is not shown again.")
                continue
            }
            if piece.offset > cursor {
                gaps += 1
                roots.append(FieldNode(id: prefix + "/gap-\(gaps)", name: "Bytes no load command accounts for", offset: cursor, length: piece.offset - cursor, kind: .padding,
                                       value: FieldText.bytes(piece.offset - cursor), note: "Padding for alignment, or data that only a segment covers."))
            }
            roots.append(piece.node)
            cursor = piece.offset + piece.length
        }
        let end = min(base + length, source.count)
        if cursor < end {
            roots.append(FieldNode(id: prefix + "/rest", name: "Bytes no load command accounts for", offset: cursor, length: end - cursor, kind: .padding, value: FieldText.bytes(end - cursor)))
        }
        return (roots, problems, summary)
    }

    // MARK: The inside of one load command

    private static func commandNodes(id: String, source: ByteSource, layout: Layout, command: UInt64, start: Int64, length: Int64) -> [FieldNode] {
        let window = ByteWindow(source: source, at: start, count: Int(min(length, 1 << 20)))
        var f = FieldList(idPrefix: id, window: window, endianness: layout.endianness)
        let end = start + length
        f.uint("Command", at: start, size: 4, value: { name($0, in: commands).replacingOccurrences(of: "\($0) · ", with: "\(FieldText.hexNumber($0, size: 4)) · ") })
        f.uint("Size", at: start + 4, size: 4, value: { "\($0) bytes" })
        func versionField(_ title: String, _ at: Int64) { f.uint(title, at: at, size: 4, value: { "\($0) · \(version($0))" }) }
        func stringField(_ title: String, offsetAt: Int64) {
            let offset = Int64(window.uint(offsetAt, size: 4, layout.endianness) ?? 0)
            guard offset >= 8, offset < length else { return }
            let bytes = window.slice(start + offset, Int(length - offset)) ?? []
            let text = fixedName(bytes)
            f.bytes(title, at: start + offset, length: length - offset, kind: .text, value: "\"" + text + "\"")
        }
        func address(_ title: String, _ at: Int64, _ size: Int) { f.uint(title, at: at, size: size, kind: .address, value: { FieldText.hexNumber($0, size: size) }) }
        switch command {
        case 0x1, 0x19:
            let wide = command == 0x19
            let w = wide ? 8 : 4
            f.bytes("Segment name", at: start + 8, length: 16, kind: .text, value: "\"" + fixedName(window.slice(start + 8, 16) ?? []) + "\"")
            address("Address in memory", start + 24, w)
            f.uint("Size in memory", at: start + 24 + Int64(w), size: w, value: { "\($0) bytes" })
            f.uint("Offset in the file", at: start + 24 + 2 * Int64(w), size: w)
            f.uint("Size in the file", at: start + 24 + 3 * Int64(w), size: w, value: { "\($0) bytes" })
            let at = start + 24 + 4 * Int64(w)
            f.uint("Maximum protection", at: at, size: 4, value: { protection($0) })
            f.uint("Initial protection", at: at + 4, size: 4, value: { protection($0) })
            let sectionCount = Int64(f.uint("Section count", at: at + 8, size: 4) ?? 0)
            f.uint("Flags", at: at + 12, size: 4, kind: .flags, value: { FieldText.hexNumber($0, size: 4) })
            let sectionSize: Int64 = wide ? 80 : 68
            var section = at + 16
            var number: Int64 = 0
            while number < sectionCount, number < 4096, section + sectionSize <= end {
                let s = section
                let nameText = fixedName(window.slice(s, 16) ?? [])
                f.group("Section \(nameText)", at: s, length: sectionSize, kind: .container, value: nil) { g in
                    g.bytes("Section name", at: s, length: 16, kind: .text, value: "\"" + nameText + "\"")
                    g.bytes("Segment name", at: s + 16, length: 16, kind: .text, value: "\"" + fixedName(window.slice(s + 16, 16) ?? []) + "\"")
                    g.uint("Address", at: s + 32, size: w, kind: .address, value: { FieldText.hexNumber($0, size: w) })
                    g.uint("Size", at: s + 32 + Int64(w), size: w, value: { "\($0) bytes" })
                    let t = s + 32 + 2 * Int64(w)
                    g.uint("Offset in the file", at: t, size: 4)
                    g.uint("Alignment", at: t + 4, size: 4, value: { "\($0) · 2^\($0) = \($0 < 32 ? 1 << $0 : 0) bytes" })
                    g.uint("Relocations offset", at: t + 8, size: 4)
                    g.uint("Relocations count", at: t + 12, size: 4)
                    g.uint("Flags", at: t + 16, size: 4, kind: .flags, value: { raw in
                        "\(FieldText.hexNumber(raw, size: 4)) · \(sectionTypes[raw & 0xFF] ?? "type \(raw & 0xFF)")" + (raw & 0xFFFF_FF00 != 0 ? ", attributes \(FieldText.hexNumber(raw >> 8, size: 3))" : "")
                    })
                    g.uint("Reserved 1", at: t + 20, size: 4)
                    g.uint("Reserved 2", at: t + 24, size: 4)
                    if wide { g.uint("Reserved 3", at: t + 28, size: 4) }
                    g.groupValue = fixedName(window.slice(s + 16, 16) ?? []) + "," + nameText
                }
                section += sectionSize
                number += 1
            }
        case 0x2:
            f.uint("Symbol table offset", at: start + 8, size: 4)
            f.uint("Symbol count", at: start + 12, size: 4)
            f.uint("String table offset", at: start + 16, size: 4)
            f.uint("String table size", at: start + 20, size: 4, value: { "\($0) bytes" })
        case 0xB:
            for (k, title) in ["Local symbols index", "Local symbols count", "External symbols index", "External symbols count", "Undefined symbols index", "Undefined symbols count",
                               "Table of contents offset", "Table of contents count", "Module table offset", "Module table count", "External references offset",
                               "External references count", "Indirect symbols offset", "Indirect symbols count", "External relocations offset", "External relocations count",
                               "Local relocations offset", "Local relocations count"].enumerated() {
                f.uint(title, at: start + 8 + Int64(k) * 4, size: 4)
            }
        case 0xC, 0xD, 0x8000_0018, 0x8000_001F, 0x20, 0x8000_0023:
            f.uint("Name offset", at: start + 8, size: 4)
            f.uint("Timestamp", at: start + 12, size: 4, kind: .time)
            versionField("Current version", start + 16)
            versionField("Compatibility version", start + 20)
            stringField("Library", offsetAt: start + 8)
        case 0xE, 0xF, 0x27:
            f.uint("Name offset", at: start + 8, size: 4)
            stringField("Path", offsetAt: start + 8)
        case 0x8000_001C:
            f.uint("Path offset", at: start + 8, size: 4)
            stringField("Path", offsetAt: start + 8)
        case 0x1B:
            f.bytes("UUID", at: start + 8, length: 16, value: window.slice(start + 8, 16).map { uuid($0) })
        case 0x32:
            f.uint("Platform", at: start + 8, size: 4, value: { name($0, in: platforms) })
            versionField("Minimum OS", start + 12)
            versionField("SDK", start + 16)
            let tools = Int64(f.uint("Tool count", at: start + 20, size: 4) ?? 0)
            var at = start + 24
            var k: Int64 = 0
            while k < min(tools, 64), at + 8 <= end {
                f.uint("Tool \(k + 1)", at: at, size: 4, value: { name($0, in: [1: "clang", 2: "swift", 3: "ld", 4: "lld"]) })
                versionField("Tool \(k + 1) version", at + 4)
                at += 8
                k += 1
            }
        case 0x24, 0x25, 0x2F, 0x30:
            versionField("Minimum OS", start + 8)
            versionField("SDK", start + 12)
        case 0x2A:
            f.uint("Version", at: start + 8, size: 8, value: { "\($0) · \(sourceVersion($0))" })
        case 0x8000_0028:
            f.uint("Entry point offset", at: start + 8, size: 8, note: { _ in "Where execution begins, as an offset from the start of the __TEXT segment." })
            f.uint("Stack size", at: start + 16, size: 8)
        case 0x4, 0x5:
            f.uint("Flavor", at: start + 8, size: 4)
            f.uint("Count", at: start + 12, size: 4, value: { "\($0) words" })
            if length > 16 { f.bytes("Thread state", at: start + 16, length: length - 16) }
        case 0x1D, 0x1E, 0x26, 0x29, 0x2B, 0x2E, 0x8000_0033, 0x8000_0034:
            f.uint("Data offset", at: start + 8, size: 4)
            f.uint("Data size", at: start + 12, size: 4, value: { "\($0) bytes" })
        case 0x22, 0x8000_0022:
            for (k, title) in ["Rebase", "Binding", "Weak binding", "Lazy binding", "Export"].enumerated() {
                f.uint("\(title) offset", at: start + 8 + Int64(k) * 8, size: 4)
                f.uint("\(title) size", at: start + 12 + Int64(k) * 8, size: 4, value: { "\($0) bytes" })
            }
        case 0x21, 0x2C:
            f.uint("Encrypted offset", at: start + 8, size: 4)
            f.uint("Encrypted size", at: start + 12, size: 4)
            f.uint("Encryption system", at: start + 16, size: 4, value: { $0 == 0 ? "0 · not encrypted" : "\($0)" })
        default:
            if length > 8 { f.bytes("Contents", at: start + 8, length: length - 8) }
        }
        return f.nodes
    }

    /// A code signature's SuperBlob: its magic, size, and the index of the blobs it holds. Always big-endian.
    private static func signatureNodes(id: String, source: ByteSource, start: Int64, length: Int64) -> [FieldNode] {
        let window = ByteWindow(source: source, at: start, count: Int(min(length, 1 << 20)))
        var f = FieldList(idPrefix: id, window: window, endianness: .big)
        f.uint("Magic", at: start, size: 4, kind: .magic, value: { raw in raw == 0xFADE_0CC0 ? "\(FieldText.hexNumber(raw, size: 4)) · embedded signature" : FieldText.hexNumber(raw, size: 4) })
        f.uint("Length", at: start + 4, size: 4, value: { "\($0) bytes" })
        let count = Int64(f.uint("Blob count", at: start + 8, size: 4) ?? 0)
        let names: [UInt64: String] = [0: "code directory", 2: "requirements", 5: "entitlements", 7: "DER entitlements", 0x1000: "alternate code directory", 0x10000: "signature (CMS)"]
        var k: Int64 = 0
        while k < min(count, 64), start + 12 + (k + 1) * 8 <= start + length {
            let at = start + 12 + k * 8
            f.group("Blob \(k + 1)", at: at, length: 8, kind: .container) { g in
                g.uint("Type", at: at, size: 4, value: { raw in names[raw].map { "\(FieldText.hexNumber(raw, size: 4)) · \($0)" } ?? FieldText.hexNumber(raw, size: 4) })
                g.uint("Offset", at: at + 4, size: 4)
            }
            k += 1
        }
        return f.nodes
    }

    // MARK: Parsing

    static func parse(_ source: ByteSource, context: ParseContext) -> ParseOutcome {
        var outcome = ParseOutcome()
        let total = source.count
        let head = ByteWindow(source: source, at: 0, count: 8)
        let magic = head.uint(0, size: 4, .big) ?? 0
        guard magic == 0xCAFE_BABE || magic == 0xCAFE_BABF else {
            let result = parseThin(source, base: 0, length: total, prefix: "macho", context: context)
            outcome.roots = result.roots
            outcome.problems = Array(result.problems.prefix(20))
            outcome.summary = "Mach-O " + result.summary
            return outcome
        }

        // A universal file: a header and a table of slices, each a Mach-O of its own.
        let wide = magic == 0xCAFE_BABF
        let entrySize: Int64 = wide ? 32 : 20
        let count = Int64(head.uint(4, size: 4, .big) ?? 0)
        var problems: [String] = []
        let tableLength = min(8 + count * entrySize, total)
        let table = ByteWindow(source: source, at: 0, count: Int(min(tableLength, 1 << 20)))
        var header = FieldList(idPrefix: "macho/fat", window: table, endianness: .big)
        header.uint("Magic", at: 0, size: 4, kind: .magic, value: { raw in "\(FieldText.hexNumber(raw, size: 4)) · universal binary" + (raw == 0xCAFE_BABF ? " with 64-bit offsets" : "") },
                    note: { _ in "Also the first bytes of a Java class file; here the next number is a small count of architectures." })
        header.uint("Architecture count", at: 4, size: 4)
        var slices: [(offset: Int64, size: Int64, cpu: UInt64, index: Int)] = []
        var k: Int64 = 0
        while k < min(count, 64), 8 + (k + 1) * entrySize <= total {
            let at = 8 + k * entrySize
            header.group("Architecture \(k + 1)", at: at, length: entrySize, kind: .container) { g in
                let cpu = g.uint("CPU type", at: at, size: 4, value: { name($0, in: cpuTypes) }) ?? 0
                g.uint("CPU subtype", at: at + 4, size: 4)
                let offset = g.uint("Offset", at: at + 8, size: wide ? 8 : 4) ?? 0
                let size = g.uint("Size", at: at + 8 + (wide ? 8 : 4), size: wide ? 8 : 4, value: { "\($0) bytes" }) ?? 0
                g.uint("Alignment", at: at + 8 + (wide ? 16 : 8), size: 4, value: { "\($0) · 2^\($0)" })
                if wide { g.bytes("Reserved", at: at + 28, length: 4, kind: .padding) }
                g.groupValue = cpuTypes[cpu] ?? "cpu \(cpu)"
                slices.append((Int64(clamping: offset), Int64(clamping: size), cpu, Int(k)))
            }
            k += 1
        }
        if k < count { problems.append("The fat header says \(count) architectures and the file is too short for more than \(k).") }
        var pieces: [(offset: Int64, length: Int64, node: FieldNode)] = [(0, tableLength, FieldNode(id: "macho/fat", name: "Fat header", offset: 0, length: tableLength, kind: .container,
                                                                                                     value: "\(count) architectures", note: "A universal binary: one complete program or library for each architecture, side by side.", children: .list(header.nodes)))]
        var names: [String] = []
        for slice in slices {
            guard slice.offset >= tableLength, slice.offset < total else {
                problems.append("Architecture \(slice.index + 1) starts at \(slice.offset), outside the file or inside the fat header.")
                continue
            }
            let held = max(0, min(slice.size, total - slice.offset))
            if held < slice.size { problems.append("Architecture \(slice.index + 1) is cut off by the end of the file.") }
            if held == 0 { continue }
            let thin = parseThin(source, base: slice.offset, length: held, prefix: "macho/slice-\(slice.index + 1)", context: context)
            problems.append(contentsOf: thin.problems.map { "Architecture \(slice.index + 1): " + $0 })
            let cpuName = cpuTypes[slice.cpu] ?? "cpu \(slice.cpu)"
            names.append(cpuName)
            pieces.append((slice.offset, held, FieldNode(id: "macho/slice-\(slice.index + 1)", name: "Slice \(slice.index + 1): \(cpuName)", offset: slice.offset, length: held, kind: .container,
                                                         value: thin.summary, children: .list(thin.roots))))
        }
        pieces.sort { $0.offset < $1.offset || ($0.offset == $1.offset && $0.length > $1.length) }
        var cursor: Int64 = 0
        var roots: [FieldNode] = []
        var gaps = 0
        for piece in pieces {
            if piece.offset < cursor {
                problems.append("\(piece.node.name) overlaps what comes before it, and is not shown again.")
                continue
            }
            if piece.offset > cursor {
                gaps += 1
                roots.append(FieldNode(id: "macho/gap-\(gaps)", name: "Padding between slices", offset: cursor, length: piece.offset - cursor, kind: .padding, value: FieldText.bytes(piece.offset - cursor)))
            }
            roots.append(piece.node)
            cursor = piece.offset + piece.length
        }
        if cursor < total {
            roots.append(FieldNode(id: "macho/rest", name: "Bytes no slice accounts for", offset: cursor, length: total - cursor, kind: .padding, value: FieldText.bytes(total - cursor)))
        }
        outcome.roots = roots
        outcome.problems = Array(problems.prefix(20))
        outcome.summary = "Mach-O universal binary, \(count) \(count == 1 ? "architecture" : "architectures")" + (names.isEmpty ? "" : " (" + names.joined(separator: ", ") + ")")
        return outcome
    }
}
