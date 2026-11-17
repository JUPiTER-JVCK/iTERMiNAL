import Foundation

/// A Microsoft compound file taken apart: the container of Word 97–2003 documents (.doc), Excel workbooks (.xls),
/// PowerPoint presentations (.ppt), Outlook messages (.msg) and Windows installers (.msi).
///
/// A compound file is a small file system in a file. It is cut into sectors; a table (the FAT) says which sector
/// follows which, so a stream can be anywhere and in any order; a directory names the streams and says where each
/// starts; and streams smaller than 4 KB are kept together in one "mini stream", cut into 64-byte mini sectors with
/// a table of their own. So the tree shows the file as it lies on disk: the header, then runs of sectors, each
/// named by what it belongs to. A Word document's own structure, its file information block and its text, is
/// shown inside the sectors that hold it.
///
/// Every sector number the file gives is checked against the file, every chain is followed with a guard against
/// loops and against two streams claiming one sector, and what does not add up is said.
enum CFBParser: FormatParser {
    static let identity = FormatIdentity(id: "cfb", name: "a compound file", detail: "Microsoft Compound File Binary", hasParser: true)
    static var alsoParses: [String] { ["doc", "xls", "ppt", "msg", "msi"] }

    static let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

    static let freeSector: UInt32 = 0xFFFF_FFFF
    static let endOfChain: UInt32 = 0xFFFF_FFFE
    static let fatSector: UInt32 = 0xFFFF_FFFD
    static let difatSector: UInt32 = 0xFFFF_FFFC
    static let maxRegularSector: UInt32 = 0xFFFF_FFFA
    static let noStream: UInt32 = 0xFFFF_FFFF

    /// The most sectors mapped: 8 million, 4 GB of 512-byte sectors.
    static let maxSectors = 1 << 23
    /// The most directory entries read.
    static let maxEntries = 100_000

    static func matches(head: [UInt8], length: Int64) -> Bool {
        head.count >= 8 && Array(head[0..<8]) == signature
    }

    // MARK: Words

    static func sectorName(_ value: UInt32) -> String {
        switch value {
        case freeSector: return "FREESECT · free"
        case endOfChain: return "ENDOFCHAIN · the last of its chain"
        case fatSector: return "FATSECT · a sector of the FAT"
        case difatSector: return "DIFSECT · a sector of the DIFAT"
        case 0xFFFF_FFFB: return "reserved"
        default: return "\(value)"
        }
    }

    static func typeName(_ raw: UInt64) -> String {
        switch raw {
        case 0: return "0 · unused"
        case 1: return "1 · storage"
        case 2: return "2 · stream"
        case 5: return "5 · root storage"
        default: return "\(raw) · not a type"
        }
    }

    /// A FILETIME: hundreds of nanoseconds since 1601.
    static func fileTime(_ raw: UInt64) -> String {
        guard raw != 0 else { return "0 · not set" }
        let seconds = Int64(raw / 10_000_000) - 11_644_473_600
        return ZIPParser.unixTime(UInt64(bitPattern: seconds))
    }

    /// A name as stored: UTF-16, with the control characters some names start with (\u{5}SummaryInformation) drawn.
    static func displayName(_ units: [UInt16]) -> String {
        var out = String.UnicodeScalarView()
        for scalar in String(decoding: units, as: UTF16.self).unicodeScalars {
            out.append(scalar.value < 0x20 ? Unicode.Scalar(0x2400 + scalar.value)! : scalar)
        }
        return String(out)
    }

    static func clsid(_ bytes: [UInt8]) -> String {
        guard bytes.count == 16 else { return "" }
        if bytes.allSatisfy({ $0 == 0 }) { return "none" }
        func hex(_ range: [Int]) -> String { range.map { String(format: "%02X", bytes[$0]) }.joined() }
        return "{" + hex([3, 2, 1, 0]) + "-" + hex([5, 4]) + "-" + hex([7, 6]) + "-" + hex([8, 9]) + "-" + hex(Array(10..<16)) + "}"
    }

    // MARK: Reading numbers

    /// The little-endian 32-bit number at `at` in `bytes`; nil if it is not all there. In steps, which the type
    /// checker takes at once, where one expression of four shifts takes it too long.
    static func le32(_ bytes: [UInt8], _ at: Int) -> UInt32? {
        guard at >= 0, at + 4 <= bytes.count else { return nil }
        var value = UInt32(bytes[at + 3])
        value = value << 8 | UInt32(bytes[at + 2])
        value = value << 8 | UInt32(bytes[at + 1])
        value = value << 8 | UInt32(bytes[at])
        return value
    }

    // MARK: The file as a file system

    /// One directory entry.
    struct Entry: Equatable {
        var index: Int
        var name: String
        var type: UInt8
        var left: UInt32
        var right: UInt32
        var child: UInt32
        var start: UInt32
        var size: Int64
        /// Where it is in the file, and its path from the root, once the tree of entries is walked.
        var recordOffset: Int64 = 0
        var path: String = ""

        var isStream: Bool { type == 2 }
    }

    /// Where the bytes of a stream are: runs of it, each a run of the file.
    struct StreamMap: Equatable {
        struct Run: Equatable {
            var stream: Int64
            var file: Int64
            var length: Int64
        }
        var runs: [Run] = []
        var length: Int64 { runs.last.map { $0.stream + $0.length } ?? 0 }

        mutating func append(stream: Int64, file: Int64, length: Int64) {
            guard length > 0 else { return }
            if let last = runs.last, last.stream + last.length == stream, last.file + last.length == file {
                runs[runs.count - 1].length += length
            } else {
                runs.append(Run(stream: stream, file: file, length: length))
            }
        }

        /// The parts of the file that hold `range` of the stream, in stream order.
        func pieces(_ range: Range<Int64>) -> [Run] {
            var out: [Run] = []
            for run in runs where run.stream < range.upperBound && run.stream + run.length > range.lowerBound {
                let start = max(run.stream, range.lowerBound)
                let end = min(run.stream + run.length, range.upperBound)
                out.append(Run(stream: start, file: run.file + (start - run.stream), length: end - start))
            }
            return out
        }

        /// Where byte `offset` of the stream is in the file.
        func fileOffset(_ offset: Int64) -> Int64? {
            pieces(offset..<(offset + 1)).first?.file
        }

        /// Where `count` bytes from `offset` of the stream are in the file, if they are all in one run.
        func contiguous(_ offset: Int64, _ count: Int64) -> Int64? {
            let found = pieces(offset..<(offset + count))
            return found.count == 1 && found[0].length == count ? found[0].file : nil
        }

        func read(_ source: ByteSource, _ range: Range<Int64>) -> [UInt8] {
            var out: [UInt8] = []
            for piece in pieces(range) {
                let bytes = source.read(piece.file..<(piece.file + piece.length))
                out += bytes
                if Int64(bytes.count) < piece.length { break }
            }
            return out
        }
    }

    /// What owns a sector.
    enum Owner: Equatable {
        case unknown
        case free
        case fat
        case difat
        case directory
        case miniFAT
        /// A stream, by entry index; the root's is the mini stream.
        case entry(Int)
    }

    /// The compound file, read: everything the tree and the checks need.
    struct Compound {
        var major: UInt16 = 0
        var sectorShift = 9
        var sectorSize: Int64 { 1 << Int64(sectorShift) }
        var miniShift = 6
        var miniCutoff: Int64 = 4096
        var sectorCount = 0
        var fat: [UInt32] = []
        var miniFAT: [UInt32] = []
        var owners: [Owner] = []
        var fatSectors: [UInt32] = []
        var difatSectors: [UInt32] = []
        var directorySectors: [UInt32] = []
        var miniFATSectors: [UInt32] = []
        var entries: [Entry] = []
        /// Every stream's map, by entry index; the root's is the mini stream.
        var maps: [Int: StreamMap] = [:]
        /// For each mini sector, the entry it belongs to.
        var miniOwners: [Int] = []
        var problems: [String] = []

        func sectorOffset(_ sector: Int) -> Int64 { Int64(sector + 1) << Int64(sectorShift) }

        func entry(named name: String) -> Entry? {
            entries.first { $0.path == name }
        }
    }

    /// Reads the file system: header, DIFAT, FAT, directory, mini FAT and the map of every stream. Nil if the
    /// header is not one.
    static func read(_ source: ByteSource, isCancelled: () -> Bool = { false }) -> Compound? {
        let total = source.count
        let header = ByteWindow(source: source, at: 0, count: 512)
        guard header.bytes.count >= 76, Array(header.bytes[0..<8]) == signature else { return nil }
        var compound = Compound()
        compound.major = header.u16(26, .little) ?? 0
        let shift = Int(header.u16(30, .little) ?? 9)
        compound.sectorShift = (7...16).contains(shift) ? shift : 9
        if shift != 9 && shift != 12 { compound.problems.append("The sector size is 2^\(shift); a compound file's is 512 or 4096.") }
        let miniShift = Int(header.u16(32, .little) ?? 6)
        compound.miniShift = (2...12).contains(miniShift) && miniShift < compound.sectorShift ? miniShift : 6
        compound.miniCutoff = Int64(header.u32(56, .little) ?? 4096)
        if compound.miniCutoff != 4096 { compound.problems.append("The mini stream cutoff is \(compound.miniCutoff); it is always 4096.") }
        let sectorSize = compound.sectorSize
        let perSector = Int(sectorSize / 4)
        compound.sectorCount = Int(min(Int64(maxSectors), max(0, (total - sectorSize + sectorSize - 1) / sectorSize)))
        compound.owners = [Owner](repeating: .unknown, count: compound.sectorCount)
        let count = compound.sectorCount

        func valid(_ sector: UInt32) -> Bool { sector <= maxRegularSector && Int(sector) < count }
        func sectorWords(_ sector: UInt32) -> [UInt32] {
            let bytes = source.read(compound.sectorOffset(Int(sector))..<(compound.sectorOffset(Int(sector)) + sectorSize))
            return stride(from: 0, to: bytes.count - 3, by: 4).map { (at: Int) -> UInt32 in le32(bytes, at) ?? freeSector }
        }
        func claim(_ sector: UInt32, _ owner: Owner, _ what: String) -> Bool {
            guard valid(sector) else {
                compound.problems.append("\(what) names sector \(sectorName(sector)), which is not in the file.")
                return false
            }
            if compound.owners[Int(sector)] != .unknown {
                compound.problems.append("\(what) uses sector \(sector), which something else already uses.")
                return false
            }
            compound.owners[Int(sector)] = owner
            return true
        }

        // The DIFAT: where the sectors of the FAT are. 109 in the header, the rest in a chain of DIFAT sectors.
        let fatCount = Int(header.u32(44, .little) ?? 0)
        var fatSectors: [UInt32] = []
        for index in 0..<109 {
            guard let value = header.u32(76 + Int64(index) * 4, .little) else { break }
            if value == freeSector || fatSectors.count >= fatCount { continue }
            fatSectors.append(value)
        }
        var difat = header.u32(68, .little) ?? endOfChain
        let difatCount = Int(header.u32(72, .little) ?? 0)
        var guardCount = 0
        while difat != endOfChain && difat != freeSector, guardCount < max(difatCount, 1) + 1, guardCount < count {
            guardCount += 1
            guard claim(difat, .difat, "The DIFAT") else { break }
            compound.difatSectors.append(difat)
            let words = sectorWords(difat)
            for value in words.dropLast() where value != freeSector && fatSectors.count < fatCount { fatSectors.append(value) }
            difat = words.last ?? endOfChain
        }
        if fatSectors.count < fatCount { compound.problems.append("The header says the FAT is \(fatCount) sectors and the DIFAT lists \(fatSectors.count).") }

        // The FAT.
        for sector in fatSectors {
            if isCancelled() { break }
            guard claim(sector, .fat, "The DIFAT") else { compound.fat += [UInt32](repeating: freeSector, count: perSector); continue }
            compound.fatSectors.append(sector)
            compound.fat += sectorWords(sector)
        }
        for (sector, value) in compound.fat.prefix(count).enumerated() where value == fatSector && compound.owners[sector] == .unknown {
            compound.problems.append("The FAT marks sector \(sector) as one of its own, and the DIFAT does not list it.")
            break
        }

        /// Follows a chain of sectors from `start`, claiming each for `owner`.
        func chain(_ start: UInt32, _ owner: Owner, _ what: String, limit: Int) -> [UInt32] {
            var out: [UInt32] = []
            var sector = start
            while sector != endOfChain, out.count < limit {
                guard claim(sector, owner, what) else { break }
                out.append(sector)
                guard Int(sector) < compound.fat.count else {
                    compound.problems.append("\(what) reaches sector \(sector), past the end of the FAT.")
                    break
                }
                sector = compound.fat[Int(sector)]
                if sector == freeSector { compound.problems.append("\(what) runs into a free sector."); break }
            }
            return out
        }

        // The directory.
        let directoryStart = header.u32(48, .little) ?? endOfChain
        compound.directorySectors = chain(directoryStart, .directory, "The directory", limit: maxEntries * 128 / Int(sectorSize) + 1)
        var entries: [Entry] = []
        let perDirectorySector = Int(sectorSize / 128)
        for (sectorIndex, sector) in compound.directorySectors.enumerated() {
            let base = compound.sectorOffset(Int(sector))
            let window = ByteWindow(source: source, at: base, count: Int(sectorSize))
            for slot in 0..<perDirectorySector {
                let at = base + Int64(slot) * 128
                guard window.has(at, 128) else { break }
                let nameLength = Int(window.u16(at + 64, .little) ?? 0)
                let units = (0..<min(32, max(0, nameLength / 2 - 1))).compactMap { window.u16(at + Int64($0) * 2, .little) }
                var size = Int64(clamping: window.u64(at + 120, .little) ?? 0)
                // Version 3 files keep only 32 bits of a size, and some writers leave rubbish in the rest.
                if compound.major == 3 { size &= 0xFFFF_FFFF }
                entries.append(Entry(index: sectorIndex * perDirectorySector + slot, name: displayName(units), type: window.u8(at + 66) ?? 0,
                                     left: window.u32(at + 68, .little) ?? noStream, right: window.u32(at + 72, .little) ?? noStream,
                                     child: window.u32(at + 76, .little) ?? noStream, start: window.u32(at + 116, .little) ?? endOfChain,
                                     size: max(0, size), recordOffset: at))
            }
        }
        guard let root = entries.first, root.type == 5 else {
            compound.problems.append(entries.isEmpty ? "There is no directory." : "The first directory entry is not the root.")
            compound.entries = entries
            return compound
        }

        // The tree of entries: each storage's children are a tree of siblings.
        var visited = Set<Int>([0])
        entries[0].path = "Root Entry"
        func walk(_ index: UInt32, parent: String, depth: Int) {
            guard index != noStream, depth < 64 else { return }
            guard Int(index) < entries.count else { compound.problems.append("A directory entry points at entry \(index), which there is not."); return }
            guard visited.insert(Int(index)).inserted else { compound.problems.append("Directory entry \(index) is reached twice: the directory loops."); return }
            let entry = entries[Int(index)]
            walk(entry.left, parent: parent, depth: depth + 1)
            entries[Int(index)].path = parent.isEmpty ? entry.name : parent + "/" + entry.name
            if entry.type == 1 { walk(entry.child, parent: entries[Int(index)].path, depth: depth + 1) }
            walk(entry.right, parent: parent, depth: depth + 1)
        }
        walk(root.child, parent: "", depth: 0)

        // The mini stream is the root's stream; the mini FAT says which mini sector follows which.
        let miniFATStart = header.u32(60, .little) ?? endOfChain
        compound.miniFATSectors = chain(miniFATStart, .miniFAT, "The mini FAT", limit: count)
        for sector in compound.miniFATSectors { compound.miniFAT += sectorWords(sector) }
        var rootMap = StreamMap()
        let rootSectors = root.start == endOfChain ? [] : chain(root.start, .entry(0), "The mini stream", limit: count)
        for (index, sector) in rootSectors.enumerated() {
            let offset = Int64(index) * sectorSize
            let length = min(sectorSize, root.size - offset, total - compound.sectorOffset(Int(sector)))
            rootMap.append(stream: offset, file: compound.sectorOffset(Int(sector)), length: length)
        }
        compound.maps[0] = rootMap
        let miniSize = Int64(1) << Int64(compound.miniShift)
        let miniCount = Int(min(Int64(compound.miniFAT.count), rootMap.length / miniSize))
        compound.miniOwners = [Int](repeating: -1, count: miniCount)

        // Every stream.
        for entry in entries where entry.isStream && visited.contains(entry.index) {
            if isCancelled() { break }
            var map = StreamMap()
            let what = "Stream \"\(entry.path)\""
            if entry.size < compound.miniCutoff {
                var mini = entry.start
                var index: Int64 = 0
                while mini != endOfChain, index * miniSize < entry.size {
                    guard Int(mini) < miniCount else { compound.problems.append("\(what) names mini sector \(sectorName(mini)), which is not in the mini stream."); break }
                    guard compound.miniOwners[Int(mini)] == -1 else { compound.problems.append("\(what) uses mini sector \(mini), which something else already uses."); break }
                    compound.miniOwners[Int(mini)] = entry.index
                    let length = min(miniSize, entry.size - index * miniSize)
                    for piece in rootMap.pieces((Int64(mini) * miniSize)..<(Int64(mini) * miniSize + length)) {
                        map.append(stream: index * miniSize + (piece.stream - Int64(mini) * miniSize), file: piece.file, length: piece.length)
                    }
                    mini = compound.miniFAT[Int(mini)]
                    index += 1
                }
            } else {
                let sectors = chain(entry.start, .entry(entry.index), what, limit: Int(min(Int64(count), entry.size / sectorSize + 1)))
                for (index, sector) in sectors.enumerated() {
                    let offset = Int64(index) * sectorSize
                    map.append(stream: offset, file: compound.sectorOffset(Int(sector)), length: min(sectorSize, entry.size - offset, max(0, total - compound.sectorOffset(Int(sector)))))
                }
            }
            if map.length < entry.size {
                compound.problems.append("\(what) is said to be \(FieldText.bytes(entry.size)) and its sectors hold \(FieldText.bytes(map.length)).")
            }
            compound.maps[entry.index] = map
        }
        for (sector, value) in compound.fat.prefix(count).enumerated() where value == freeSector && compound.owners[sector] == .unknown {
            compound.owners[sector] = .free
        }
        compound.entries = entries
        return compound
    }

    // MARK: What kind of document

    /// What the streams say the file is.
    static func kind(_ compound: Compound) -> FormatIdentity {
        let paths = Set(compound.entries.map { $0.path })
        func has(_ name: String) -> Bool { paths.contains(name) }
        if has("WordDocument") { return FormatIdentity(id: "doc", name: "a Word document", detail: "Word 97–2003 (.doc), in a compound file", hasParser: true) }
        if has("Workbook") || has("Book") { return FormatIdentity(id: "xls", name: "an Excel workbook", detail: "Excel 97–2003 (.xls), in a compound file", hasParser: true) }
        if has("PowerPoint Document") { return FormatIdentity(id: "ppt", name: "a PowerPoint presentation", detail: "PowerPoint 97–2003 (.ppt), in a compound file", hasParser: true) }
        if has("__properties_version1.0") { return FormatIdentity(id: "msg", name: "an Outlook message", detail: ".msg, in a compound file", hasParser: true) }
        let root = compound.entries.first
        // An installer's tables are streams whose names are packed into characters from U+3800 to U+4840.
        if let root, root.path == "Root Entry", compound.entries.contains(where: { $0.name.unicodeScalars.contains { (0x3800...0x4840).contains($0.value) } }) {
            return FormatIdentity(id: "msi", name: "a Windows installer", detail: ".msi, in a compound file", hasParser: true)
        }
        return identity
    }

    // MARK: Word

    /// What a Word document's file information block says, and where its text is.
    struct Word: Equatable {
        var nFib: UInt16 = 0
        var flags: UInt16 = 0
        var encrypted: Bool { flags & 0x0100 != 0 }
        var tableName: String { flags & 0x0200 != 0 ? "1Table" : "0Table" }
        var ccpText: Int64 = 0
        var fcClx: Int64 = 0
        var lcbClx: Int64 = 0
        /// The text, a piece at a time: where it is in the WordDocument stream, how many characters, and whether
        /// one byte (Windows-1252) or two (UTF-16) each.
        struct Piece: Equatable {
            var cp: Int64
            var characters: Int64
            var streamOffset: Int64
            var compressed: Bool
            var byteLength: Int64 { characters * (compressed ? 1 : 2) }
        }
        var pieces: [Piece] = []
        var problems: [String] = []
    }

    static func word(_ source: ByteSource, _ compound: Compound) -> Word? {
        guard let document = compound.entry(named: "WordDocument"), let map = compound.maps[document.index] else { return nil }
        let fib = map.read(source, 0..<min(map.length, 1024))
        func u16(_ at: Int) -> UInt16? { at + 2 <= fib.count ? UInt16(fib[at]) | UInt16(fib[at + 1]) << 8 : nil }
        func u32(_ at: Int) -> Int64? { le32(fib, at).map { Int64($0) } }
        var word = Word()
        guard u16(0) == 0xA5EC else {
            word.problems.append("The WordDocument stream does not start with Word's signature, 0xA5EC.")
            return word
        }
        word.nFib = u16(2) ?? 0
        word.flags = u16(10) ?? 0
        word.ccpText = u32(64 + 12) ?? 0
        word.fcClx = u32(154 + 33 * 8) ?? 0
        word.lcbClx = u32(154 + 33 * 8 + 4) ?? 0
        guard !word.encrypted else { return word }
        guard let table = compound.entry(named: word.tableName), let tableMap = compound.maps[table.index] else {
            word.problems.append("The document's table stream, \(word.tableName), is missing.")
            return word
        }
        guard word.lcbClx > 0, word.fcClx >= 0, word.fcClx + word.lcbClx <= tableMap.length, word.lcbClx < 1 << 26 else {
            word.problems.append("The table of the document's text pieces is not inside \(word.tableName).")
            return word
        }
        let clx = tableMap.read(source, word.fcClx..<(word.fcClx + word.lcbClx))
        func clx32(_ at: Int) -> Int64 { Int64(le32(clx, at) ?? 0) }
        var at = 0
        // Formatting (Prc) first, each 0x01 and a 16-bit length; then the piece table (Pcdt), 0x02 and a 32-bit length.
        var guardCount = 0
        while at < clx.count, clx[at] == 0x01, guardCount < 100_000 {
            guardCount += 1
            guard at + 3 <= clx.count else { break }
            at += 3 + (Int(clx[at + 1]) | Int(clx[at + 2]) << 8)
        }
        guard at + 5 <= clx.count, clx[at] == 0x02 else {
            word.problems.append("The text's piece table is not where the file information block says.")
            return word
        }
        let plcLength = Int(min(clx32(at + 1), Int64(clx.count - at - 5)))
        let plc = at + 5
        // n + 1 character positions, then n descriptions of 8 bytes.
        let count = (plcLength - 4) / 12
        guard count > 0, count < 1_000_000 else { word.problems.append("The piece table holds no pieces."); return word }
        for index in 0..<count {
            let cpStart = clx32(plc + index * 4)
            let cpEnd = clx32(plc + (index + 1) * 4)
            let descriptor = plc + (count + 1) * 4 + index * 8
            let raw = clx32(descriptor + 2)
            let compressed = raw & 0x4000_0000 != 0
            let fc = raw & 0x3FFF_FFFF
            guard cpEnd > cpStart else { continue }
            word.pieces.append(Word.Piece(cp: cpStart, characters: cpEnd - cpStart, streamOffset: compressed ? fc / 2 : fc, compressed: compressed))
        }
        for piece in word.pieces where piece.streamOffset + piece.byteLength > map.length {
            word.problems.append("A piece of the text is said to run past the end of the WordDocument stream.")
            break
        }
        return word
    }

    /// The document's main text, as far as `limit` characters: Word's paragraph marks as line ends.
    static func text(_ source: ByteSource, _ compound: Compound, _ word: Word, limit: Int64 = 1 << 20) -> String {
        guard let document = compound.entry(named: "WordDocument"), let map = compound.maps[document.index] else { return "" }
        var out = String.UnicodeScalarView()
        var taken: Int64 = 0
        for piece in word.pieces.sorted(by: { $0.cp < $1.cp }) where piece.cp < word.ccpText && taken < limit {
            let characters = min(piece.characters, word.ccpText - piece.cp, limit - taken)
            let bytes = map.read(source, piece.streamOffset..<(piece.streamOffset + characters * (piece.compressed ? 1 : 2)))
            if piece.compressed {
                for scalar in TextParser.windows1252(bytes).unicodeScalars { out.append(scalar) }
            } else {
                let units = stride(from: 0, to: bytes.count - 1, by: 2).map { (at: Int) -> UInt16 in
                    let low = UInt16(bytes[at])
                    let high = UInt16(bytes[at + 1])
                    return high << 8 | low
                }
                for scalar in String(decoding: units, as: UTF16.self).unicodeScalars { out.append(scalar) }
            }
            taken += characters
        }
        return String(out).replacingOccurrences(of: "\r", with: "\n")
    }

    // MARK: Summary information

    /// The title and author, and the like, from the \u{5}SummaryInformation property set.
    static func summaryInformation(_ source: ByteSource, _ compound: Compound) -> [(String, String)] {
        guard let entry = compound.entries.first(where: { $0.path == "\u{2405}SummaryInformation" }), let map = compound.maps[entry.index] else { return [] }
        let bytes = map.read(source, 0..<min(map.length, 65_536))
        func u16(_ at: Int) -> Int? { at >= 0 && at + 2 <= bytes.count ? Int(bytes[at]) | Int(bytes[at + 1]) << 8 : nil }
        func u32(_ at: Int) -> Int? { le32(bytes, at).map { Int($0) } }
        guard u16(0) == 0xFFFE, let sections = u32(24), sections >= 1, let section = u32(44), let count = u32(section + 4), count < 1000 else { return [] }
        let names = [2: "Title", 3: "Subject", 4: "Author", 5: "Keywords", 6: "Comments", 8: "Last saved by", 12: "Created", 13: "Saved", 14: "Pages", 15: "Words", 18: "Program"]
        var out: [(String, String)] = []
        for index in 0..<count {
            guard let id = u32(section + 8 + index * 8), let offset = u32(section + 12 + index * 8), let name = names[id] else { continue }
            let at = section + offset
            guard let type = u32(at) else { continue }
            switch type & 0xFFFF {
            case 0x1E:
                guard let length = u32(at + 4), length > 0, length < 32_768, at + 8 + length <= bytes.count else { continue }
                let raw = bytes[(at + 8)..<(at + 8 + length)].prefix { $0 != 0 }
                let text = TextParser.windows1252(Array(raw))
                if !text.isEmpty { out.append((name, text)) }
            case 0x03:
                if let value = u32(at + 4) { out.append((name, "\(Int32(truncatingIfNeeded: value))")) }
            case 0x40:
                if let low = u32(at + 4), let high = u32(at + 8) { out.append((name, fileTime(UInt64(high) << 32 | UInt64(low)))) }
            default:
                continue
            }
        }
        return out
    }

    // MARK: The tree

    static func parse(_ source: ByteSource, context: ParseContext) -> ParseOutcome {
        var outcome = ParseOutcome()
        let total = source.count
        guard let compound = read(source, isCancelled: context.isCancelled) else {
            outcome.problems = ["This does not start with a compound file's signature."]
            return outcome
        }
        let sectorSize = compound.sectorSize
        let kind = kind(compound)
        outcome.identity = kind
        let word = kind.id == "doc" ? word(source, compound) : nil

        outcome.roots.append(headerNode(source, compound: compound))
        // The sectors, in file order, a run of them for each thing that owns them.
        var sector = 0
        var runs = 0
        while sector < compound.sectorCount {
            if runs >= context.maxRecords {
                outcome.listingLimit = "The first \(context.maxRecords) runs of sectors are listed; the rest of the file is in the dump."
                let at = compound.sectorOffset(sector)
                outcome.roots.append(FieldNode(id: "cfb/more", name: "More sectors", offset: at, length: total - at, kind: .bytes, value: "not listed"))
                break
            }
            let owner = compound.owners[sector]
            var last = sector
            while last + 1 < compound.sectorCount, compound.owners[last + 1] == owner { last += 1 }
            let start = compound.sectorOffset(sector)
            let end = min(total, compound.sectorOffset(last) + sectorSize)
            outcome.roots.append(runNode(source, compound: compound, word: word, owner: owner, first: sector, last: last, start: start, end: end))
            runs += 1
            sector = last + 1
        }
        let mapped = compound.sectorOffset(compound.sectorCount)
        if compound.sectorCount == maxSectors, mapped < total {
            outcome.roots.append(FieldNode(id: "cfb/unmapped", name: "Not mapped", offset: mapped, length: total - mapped, kind: .bytes,
                                           value: FieldText.bytes(total - mapped), note: "Only the first \(maxSectors) sectors are mapped."))
        }

        var problems = compound.problems
        if let word { problems += word.problems }
        outcome.problems = Array(problems.prefix(20))
        let streams = compound.entries.filter { $0.isStream && !$0.path.isEmpty }
        var summary = "\(kind.id == identity.id ? "Compound file" : kind.detail.components(separatedBy: ",").first ?? "Compound file"), version \(compound.major), \(sectorSize)-byte sectors, "
        summary += TextParser.count(streams.count, "stream", "streams")
        if let word {
            if word.encrypted {
                summary += ", encrypted"
            } else {
                let text = self.text(source, compound, word)
                let words = text.split { $0.isWhitespace }.count
                summary += ", \(TextParser.count(Int(word.ccpText), "character", "characters")), \(TextParser.count(words, "word", "words"))"
                let opening = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                if !opening.isEmpty { summary += ": \"" + (opening.count > 60 ? String(opening.prefix(60)) + "…" : opening) + "\"" }
            }
        }
        let info = summaryInformation(source, compound)
        if let title = info.first(where: { $0.0 == "Title" })?.1 { summary += ", titled \"\(title)\"" }
        if let author = info.first(where: { $0.0 == "Author" })?.1 { summary += ", by \(author)" }
        outcome.summary = summary
        return outcome
    }

    private static func headerNode(_ source: ByteSource, compound: Compound) -> FieldNode {
        let length = min(compound.sectorSize, source.count)
        let window = ByteWindow(source: source, at: 0, count: 512)
        var list = FieldList(idPrefix: "cfb/header", window: window, endianness: .little)
        list.bytes("Signature", at: 0, length: 8, kind: .magic, value: "D0 CF 11 E0 A1 B1 1A E1", note: "\"DOCFILE\", more or less, in hex.")
        list.bytes("Class id", at: 8, length: 16, value: window.slice(8, 16).map { clsid(Array($0)) })
        list.uint("Minor version", at: 24, size: 2, value: { FieldText.hexNumber($0, size: 2) })
        list.uint("Major version", at: 26, size: 2, value: { "\($0)\($0 == 3 ? " · 512-byte sectors" : $0 == 4 ? " · 4096-byte sectors" : "")" })
        list.uint("Byte order", at: 28, size: 2, value: { $0 == 0xFFFE ? "0xFFFE · little-endian" : FieldText.hexNumber($0, size: 2) })
        list.uint("Sector shift", at: 30, size: 2, value: { "\($0) · \(1 << min($0, 30)) bytes" })
        list.uint("Mini sector shift", at: 32, size: 2, value: { "\($0) · \(1 << min($0, 30)) bytes" })
        list.bytes("Reserved", at: 34, length: 6, kind: .padding)
        list.uint("Directory sectors", at: 40, size: 4, note: { _ in "Always 0 in version 3." })
        list.uint("FAT sectors", at: 44, size: 4)
        list.uint("First directory sector", at: 48, size: 4, value: { sectorName(UInt32($0)) })
        list.uint("Transaction signature", at: 52, size: 4)
        list.uint("Mini stream cutoff", at: 56, size: 4, value: { "\($0) bytes" }, note: { _ in "Streams smaller than this are in the mini stream." })
        list.uint("First mini FAT sector", at: 60, size: 4, value: { sectorName(UInt32($0)) })
        list.uint("Mini FAT sectors", at: 64, size: 4)
        list.uint("First DIFAT sector", at: 68, size: 4, value: { sectorName(UInt32($0)) })
        list.uint("DIFAT sectors", at: 72, size: 4)
        list.deferredGroup("DIFAT", at: 76, length: 436, value: "109 entries",
                           note: "The first 109 sectors of the FAT. A FAT longer than that lists the rest in DIFAT sectors.") { id in
            var inner = FieldList(idPrefix: id, window: window, endianness: .little)
            for index in 0..<109 { inner.uint("FAT sector \(index)", at: 76 + Int64(index) * 4, size: 4, value: { sectorName(UInt32($0)) }) }
            return inner.nodes
        }
        if length > 512 { list.add(FieldNode(id: "cfb/header/rest", name: "Rest of the first sector", offset: 512, length: length - 512, kind: .padding, value: FieldText.bytes(length - 512))) }
        return FieldNode(id: "cfb/header", name: "Header", offset: 0, length: length, kind: .container, value: "version \(compound.major)",
                         note: "Where everything else is: the sizes of sectors, and the first sectors of the FAT, the directory and the mini FAT.",
                         children: .list(list.nodes))
    }

    private static func runNode(_ source: ByteSource, compound: Compound, word: Word?, owner: Owner, first: Int, last: Int, start: Int64, end: Int64) -> FieldNode {
        let id = "cfb/sector-\(first)"
        let range = first == last ? "Sector \(first)" : "Sectors \(first)–\(last)"
        let length = max(0, end - start)
        switch owner {
        case .fat, .difat, .miniFAT:
            let what = owner == .fat ? "FAT" : owner == .difat ? "DIFAT" : "mini FAT"
            let note = owner == .fat ? "For every sector, the one that follows it in its chain." : owner == .difat ? "Where the FAT's sectors are, past the first 109." : "For every mini sector, the one that follows it."
            return FieldNode(id: id, name: "\(range) · \(what)", offset: start, length: length, kind: .container, value: FieldText.bytes(length), note: note,
                             children: .deferred(DeferredChildren { tableNodes(source, compound: compound, owner: owner, first: first, last: last, id: id, end: end) }))
        case .directory:
            return FieldNode(id: id, name: "\(range) · directory", offset: start, length: length, kind: .container,
                             value: "\(length / 128) entries", note: "128 bytes for each stream and storage: its name, type, size, first sector, and its place in the tree.",
                             children: .deferred(DeferredChildren { directoryNodes(source, compound: compound, start: start, end: end, id: id) }))
        case .free:
            return FieldNode(id: id, name: "\(range) · free", offset: start, length: length, kind: .padding, value: FieldText.bytes(length),
                             note: "The FAT marks these free. What is in them is left over.")
        case .unknown:
            return FieldNode(id: id, name: "\(range) · not used", offset: start, length: length, kind: .padding, value: FieldText.bytes(length),
                             note: "Nothing in the file points at these sectors.")
        case .entry(let index):
            let entry = compound.entries[index]
            let map = compound.maps[index] ?? StreamMap()
            let pieces = map.runs.filter { $0.file < end && $0.file + $0.length > start }
            let streamStart = pieces.map { $0.stream }.min() ?? 0
            let streamEnd = pieces.map { $0.stream + $0.length }.max() ?? 0
            if index == 0 {
                return FieldNode(id: id, name: "\(range) · mini stream", offset: start, length: length, kind: .container,
                                 value: FieldText.bytes(length), note: "The streams smaller than \(compound.miniCutoff) bytes, in mini sectors of \(1 << compound.miniShift) bytes.",
                                 children: .deferred(DeferredChildren { miniNodes(source, compound: compound, word: word, start: start, end: end, id: id) }))
            }
            let name = entry.path.isEmpty ? entry.name : entry.path
            return FieldNode(id: id, name: "\(range) · \(name)", offset: start, length: length, kind: .container,
                             value: pieces.isEmpty ? FieldText.bytes(length) : "bytes \(streamStart)–\(streamEnd - 1) of \(FieldText.bytes(entry.size))",
                             note: streamNote(entry.name),
                             children: .deferred(DeferredChildren { streamNodes(source, compound: compound, word: word, entry: entry, start: start, end: end, id: id) }))
        }
    }

    static func streamNote(_ name: String) -> String? {
        switch name {
        case "WordDocument": return "The document: its file information block, its text, and its formatting."
        case "1Table", "0Table": return "Word's tables: where the text's pieces are, styles, fonts, lists."
        case "Data": return "Pictures and other objects in the document."
        case "Workbook", "Book": return "The workbook, as a run of BIFF records."
        case "PowerPoint Document": return "The presentation, as a tree of records."
        case "\u{2405}SummaryInformation": return "The title, author, dates and counts, as a property set."
        case "\u{2405}DocumentSummaryInformation": return "More properties: the company, the manager, the parts of the document."
        case "\u{2401}CompObj": return "What program made the object."
        default: return nil
        }
    }

    /// The entries of FAT, DIFAT or mini FAT sectors.
    private static func tableNodes(_ source: ByteSource, compound: Compound, owner: Owner, first: Int, last: Int, id: String, end: Int64) -> [FieldNode] {
        var nodes: [FieldNode] = []
        let perSector = Int(compound.sectorSize / 4)
        for sector in first...last {
            let base = compound.sectorOffset(sector)
            guard base < end else { break }
            let window = ByteWindow(source: source, at: base, count: Int(compound.sectorSize))
            var list = FieldList(idPrefix: id + "/s\(sector)", window: window, endianness: .little)
            let index: Int
            switch owner {
            case .fat: index = (compound.fatSectors.firstIndex(of: UInt32(sector)) ?? 0) * perSector
            case .miniFAT: index = (compound.miniFATSectors.firstIndex(of: UInt32(sector)) ?? 0) * perSector
            default: index = 0
            }
            let what = owner == .miniFAT ? "Mini sector" : "Sector"
            for slot in 0..<perSector {
                let at = base + Int64(slot) * 4
                guard window.has(at, 4) else { break }
                if owner == .difat {
                    list.uint(slot == perSector - 1 ? "Next DIFAT sector" : "FAT sector", at: at, size: 4, value: { sectorName(UInt32($0)) })
                } else {
                    list.uint("\(what) \(index + slot)", at: at, size: 4, value: { "→ " + sectorName(UInt32($0)) })
                }
            }
            nodes.append(FieldNode(id: id + "/s\(sector)", name: "Sector \(sector)", offset: base, length: Int64(window.bytes.count), kind: .container,
                                   value: owner == .difat ? nil : "entries \(index)–\(index + perSector - 1)", children: .list(list.nodes)))
        }
        return nodes.count == 1 ? nodes[0].resolvedChildren() : nodes
    }

    private static func directoryNodes(_ source: ByteSource, compound: Compound, start: Int64, end: Int64, id: String) -> [FieldNode] {
        var nodes: [FieldNode] = []
        for entry in compound.entries where entry.recordOffset >= start && entry.recordOffset + 128 <= end {
            let at = entry.recordOffset
            let window = ByteWindow(source: source, at: at, count: 128)
            var list = FieldList(idPrefix: id + "/e\(entry.index)", window: window, endianness: .little)
            list.bytes("Name", at: at, length: 64, kind: .text, value: entry.name.isEmpty ? "none" : "\"\(entry.name)\"", note: "UTF-16, up to 31 characters and a terminating zero.")
            list.uint("Name length", at: at + 64, size: 2, value: { "\($0) bytes" })
            list.uint("Type", at: at + 66, size: 1, value: { typeName($0) })
            list.uint("Colour", at: at + 67, size: 1, value: { $0 == 0 ? "0 · red" : $0 == 1 ? "1 · black" : "\($0)" }, note: { _ in "The siblings are a red-black tree." })
            list.uint("Left sibling", at: at + 68, size: 4, value: { $0 == UInt64(noStream) ? "none" : "entry \($0)" })
            list.uint("Right sibling", at: at + 72, size: 4, value: { $0 == UInt64(noStream) ? "none" : "entry \($0)" })
            list.uint("Child", at: at + 76, size: 4, value: { $0 == UInt64(noStream) ? "none" : "entry \($0)" })
            list.bytes("Class id", at: at + 80, length: 16, value: window.slice(at + 80, 16).map { clsid(Array($0)) })
            list.uint("State bits", at: at + 96, size: 4)
            list.uint("Created", at: at + 100, size: 8, kind: .time, value: { fileTime($0) })
            list.uint("Modified", at: at + 108, size: 8, kind: .time, value: { fileTime($0) })
            list.uint("First sector", at: at + 116, size: 4, value: { entry.size < compound.miniCutoff && entry.isStream ? "mini sector \(sectorName(UInt32($0)))" : sectorName(UInt32($0)) })
            list.uint("Size", at: at + 120, size: 8, value: { compound.major == 3 && $0 > 0xFFFF_FFFF ? "\($0 & 0xFFFF_FFFF) bytes · the high half is ignored" : "\($0) bytes" })
            let label = entry.type == 0 ? "unused" : entry.path.isEmpty ? (entry.name.isEmpty ? "not in the tree" : "\(entry.name), not in the tree") : entry.path
            nodes.append(FieldNode(id: id + "/e\(entry.index)", name: "Entry \(entry.index)", offset: at, length: 128, kind: entry.type == 0 ? .padding : .container,
                                   value: entry.type == 0 ? "unused" : "\(label) · \(typeName(UInt64(entry.type)).components(separatedBy: " · ").last ?? "")\(entry.isStream ? " · \(FieldText.bytes(entry.size))" : "")",
                                   children: .list(list.nodes)))
        }
        return nodes
    }

    /// The mini sectors in one run of the mini stream, a run of them for each stream they belong to.
    private static func miniNodes(_ source: ByteSource, compound: Compound, word: Word?, start: Int64, end: Int64, id: String) -> [FieldNode] {
        guard let rootMap = compound.maps[0] else { return [] }
        let miniSize = Int64(1) << Int64(compound.miniShift)
        var nodes: [FieldNode] = []
        for piece in rootMap.runs where piece.file < end && piece.file + piece.length > start {
            let fileStart = max(piece.file, start)
            let fileEnd = min(piece.file + piece.length, end)
            var mini = Int((piece.stream + fileStart - piece.file) / miniSize)
            let lastMini = Int((piece.stream + fileEnd - piece.file - 1) / miniSize)
            while mini <= lastMini {
                let owner = mini < compound.miniOwners.count ? compound.miniOwners[mini] : -1
                var last = mini
                while last + 1 <= lastMini, last + 1 < compound.miniOwners.count, compound.miniOwners[last + 1] == owner { last += 1 }
                let at = piece.file + Int64(mini) * miniSize - piece.stream
                let stop = min(fileEnd, piece.file + Int64(last + 1) * miniSize - piece.stream)
                let range = mini == last ? "Mini sector \(mini)" : "Mini sectors \(mini)–\(last)"
                if owner >= 0 {
                    let entry = compound.entries[owner]
                    nodes.append(FieldNode(id: id + "/m\(mini)", name: "\(range) · \(entry.path)", offset: at, length: stop - at, kind: .container,
                                           value: FieldText.bytes(entry.size), note: streamNote(entry.name),
                                           children: .deferred(DeferredChildren { streamNodes(source, compound: compound, word: word, entry: entry, start: at, end: stop, id: id + "/m\(mini)") })))
                } else {
                    nodes.append(FieldNode(id: id + "/m\(mini)", name: "\(range) · not used", offset: at, length: stop - at, kind: .padding, value: FieldText.bytes(stop - at)))
                }
                mini = last + 1
            }
        }
        return nodes
    }

    /// What is in one run of a stream's bytes: for a Word document, its file information block and its text.
    private static func streamNodes(_ source: ByteSource, compound: Compound, word: Word?, entry: Entry, start: Int64, end: Int64, id: String) -> [FieldNode] {
        guard let map = compound.maps[entry.index] else { return [] }
        var nodes: [FieldNode] = []
        if entry.path == "WordDocument", let word {
            // The file information block, where its fields are in this run.
            if let fibAt = map.contiguous(0, 154), fibAt >= start, fibAt + 154 <= end {
                let window = ByteWindow(source: source, at: fibAt, count: Int(min(end - fibAt, 1024)))
                var list = FieldList(idPrefix: id + "/fib", window: window, endianness: .little)
                list.uint("Signature", at: fibAt, size: 2, kind: .magic, value: { $0 == 0xA5EC ? "0xA5EC · Word" : FieldText.hexNumber($0, size: 2) })
                list.uint("Version (nFib)", at: fibAt + 2, size: 2, value: { raw in
                    let names: [UInt64: String] = [0x65: "Word 6", 0x68: "Word 95", 0xC1: "Word 97, or a later Word that says so here", 0xD9: "Word 2000",
                                                   0x101: "Word 2002", 0x10C: "Word 2003", 0x112: "Word 2007"]
                    return FieldText.hexNumber(raw, size: 2) + (names[raw].map { " · " + $0 } ?? "")
                })
                list.uint("Language", at: fibAt + 6, size: 2, value: { FieldText.hexNumber($0, size: 2) })
                list.uint("Flags", at: fibAt + 10, size: 2, kind: .flags, value: { raw in
                    var names: [String] = []
                    if raw & 0x0001 != 0 { names.append("template") }
                    if raw & 0x0004 != 0 { names.append("saved quickly") }
                    if raw & 0x0100 != 0 { names.append("encrypted") }
                    names.append(raw & 0x0200 != 0 ? "tables in 1Table" : "tables in 0Table")
                    if raw & 0x0400 != 0 { names.append("read-only recommended") }
                    if raw & 0x8000 != 0 { names.append("obfuscated") }
                    return FieldText.hexNumber(raw, size: 2) + " · " + names.joined(separator: ", ")
                })
                list.uint("Counts of 16-bit values", at: fibAt + 32, size: 2)
                list.bytes("16-bit values", at: fibAt + 34, length: 28)
                list.uint("Counts of 32-bit values", at: fibAt + 62, size: 2)
                list.uint("End of the stream's used bytes", at: fibAt + 64, size: 4, value: { "\($0) bytes" })
                list.uint("Characters of main text", at: fibAt + 76, size: 4, note: { _ in "ccpText: the body, without headers, footnotes or comments." })
                list.uint("Characters of footnotes", at: fibAt + 80, size: 4)
                list.uint("Characters of headers and footers", at: fibAt + 84, size: 4)
                list.uint("Count of file offsets", at: fibAt + 152, size: 2, value: { "\($0) pairs" })
                if let clxAt = map.contiguous(418, 8), clxAt >= start, clxAt + 8 <= end, clxAt == fibAt + 418 {
                    list.uint("Text pieces at (fcClx)", at: clxAt, size: 4, value: { "\($0) in \(word.tableName)" })
                    list.uint("Text pieces length (lcbClx)", at: clxAt + 4, size: 4, value: { "\($0) bytes" })
                }
                nodes.append(FieldNode(id: id + "/fib", name: "File information block", offset: fibAt, length: min(end, fibAt + 426) - fibAt, kind: .container,
                                       value: "Word, nFib \(FieldText.hexNumber(UInt64(word.nFib), size: 2))",
                                       note: "Where everything in the document is: its text, styles, fonts and formatting, as offsets into this stream and the table stream.",
                                       children: .list(list.nodes)))
            }
            // The text, a node for each part of a piece that is in this run.
            var number = 0
            for piece in word.pieces.sorted(by: { $0.streamOffset < $1.streamOffset }) {
                number += 1
                for part in map.pieces(piece.streamOffset..<(piece.streamOffset + piece.byteLength)) where part.file >= start && part.file + part.length <= end {
                    let preview = TextParser.preview(source, from: part.file, to: part.file + part.length, encoding: piece.compressed ? .utf8 : .utf16LittleEndian,
                                                     eightBit: piece.compressed, limit: 60)
                    nodes.append(FieldNode(id: id + "/text-\(number)-\(part.stream)", name: "Text, piece \(number)", offset: part.file, length: part.length, kind: .text,
                                           value: "\"\(preview)\"",
                                           note: "Characters \(piece.cp + (part.stream - piece.streamOffset) / (piece.compressed ? 1 : 2)) onward, \(piece.compressed ? "one byte each, in Windows-1252" : "two bytes each, in UTF-16"). ␍ ends a paragraph."))
                }
            }
        }
        nodes.sort { $0.offset < $1.offset }
        var kept: [FieldNode] = []
        for node in nodes where kept.last.map({ $0.end <= node.offset }) ?? true { kept.append(node) }
        return kept
    }
}
