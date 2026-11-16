import Foundation

/// What to look for in a file: bytes, any of which may stand for "any byte", or text in one of
/// the encodings a file might hold it in.
///
/// Foundation only, so the rules (what "DE AD ?? EF" means, where a match may start, which end of
/// a chunk a match can straddle) are checked in CI rather than seen.
struct SearchPattern: Equatable {
    /// The bytes to match. Where `wildcard` is true the byte at the same index matches anything.
    let bytes: [UInt8]
    let wildcard: [Bool]
    /// The letters A to Z match either case. Bytes that are not those letters are matched as they are.
    let ignoresCase: Bool

    var count: Int { bytes.count }

    /// The longest pattern: a longer one is more likely a paste of the wrong thing than a search.
    static let maxLength = 4096

    enum Failure: Error, Equatable {
        case empty
        /// A group of hex digits with one left over.
        case oddDigits(String)
        /// Something that is neither a hex digit nor a wildcard.
        case notHex(String)
        case tooLong
        /// A character the chosen encoding has no byte for.
        case unencodable(String)
    }

    enum TextEncoding: String, CaseIterable {
        case utf8
        case utf16LittleEndian
        case utf16BigEndian
        case latin1

        var title: String {
            switch self {
            case .utf8: return "UTF-8"
            case .utf16LittleEndian: return "UTF-16 little-endian"
            case .utf16BigEndian: return "UTF-16 big-endian"
            case .latin1: return "Latin-1"
            }
        }
    }

    init(bytes: [UInt8], wildcard: [Bool]? = nil, ignoresCase: Bool = false) {
        self.bytes = bytes
        self.wildcard = wildcard ?? [Bool](repeating: false, count: bytes.count)
        self.ignoresCase = ignoresCase
    }

    // MARK: Hex

    /// Bytes written as hex: "DE AD BE EF", "deadbeef", "0xDE 0xAD", with "??" (or a lone "?") for a byte of any value.
    static func hex(_ text: String) -> Result<SearchPattern, Failure> {
        var bytes: [UInt8] = []
        var wildcard: [Bool] = []
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:"))
        for var token in text.components(separatedBy: separators) where !token.isEmpty {
            if token.hasPrefix("0x") || token.hasPrefix("0X") { token = String(token.dropFirst(2)) }
            if token == "?" {
                bytes.append(0)
                wildcard.append(true)
                continue
            }
            let characters = Array(token)
            guard !characters.isEmpty else { return .failure(.notHex(token)) }
            guard characters.count % 2 == 0 else {
                let bad = characters.first { !($0.isHexDigit || $0 == "?") }
                return .failure(bad.map { .notHex(String($0)) } ?? .oddDigits(token))
            }
            var index = 0
            while index < characters.count {
                let pair = String(characters[index..<(index + 2)])
                if pair == "??" {
                    bytes.append(0)
                    wildcard.append(true)
                } else if let value = UInt8(pair, radix: 16), characters[index].isHexDigit, characters[index + 1].isHexDigit {
                    bytes.append(value)
                    wildcard.append(false)
                } else {
                    return .failure(.notHex(pair))
                }
                index += 2
            }
            if bytes.count > maxLength { return .failure(.tooLong) }
        }
        guard !bytes.isEmpty else { return .failure(.empty) }
        guard bytes.count <= maxLength else { return .failure(.tooLong) }
        return .success(SearchPattern(bytes: bytes, wildcard: wildcard))
    }

    // MARK: Text

    static func text(_ text: String, encoding: TextEncoding, ignoresCase: Bool) -> Result<SearchPattern, Failure> {
        guard !text.isEmpty else { return .failure(.empty) }
        var bytes: [UInt8] = []
        switch encoding {
        case .utf8:
            bytes = Array(text.utf8)
        case .utf16LittleEndian:
            for unit in text.utf16 { bytes += [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
        case .utf16BigEndian:
            for unit in text.utf16 { bytes += [UInt8(unit >> 8), UInt8(unit & 0xFF)] }
        case .latin1:
            for scalar in text.unicodeScalars {
                guard scalar.value <= 0xFF else { return .failure(.unencodable(String(scalar))) }
                bytes.append(UInt8(scalar.value))
            }
        }
        guard bytes.count <= maxLength else { return .failure(.tooLong) }
        return .success(SearchPattern(bytes: bytes, ignoresCase: ignoresCase))
    }

    static func message(_ failure: Failure) -> String {
        switch failure {
        case .empty: return "Type what to look for."
        case .oddDigits(let group): return "\"\(group)\" is an odd number of hex digits: a byte is two."
        case .notHex(let group): return "\"\(group)\" is not hex. Write bytes like DE AD ?? EF, where ?? is any byte."
        case .tooLong: return "That is longer than a search can be: \(maxLength) bytes."
        case .unencodable(let character): return "\"\(character)\" has no byte in that encoding."
        }
    }

    // MARK: Matching

    /// `byte` with A to Z made lower case.
    @inline(__always)
    static func folded(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
    }

    /// Whether the pattern is at `index` in `data`.
    func matches(in data: [UInt8], at index: Int) -> Bool {
        guard index >= 0, index + count <= data.count else { return false }
        for position in 0..<count where !wildcard[position] {
            let want = bytes[position]
            let have = data[index + position]
            if ignoresCase ? SearchPattern.folded(want) != SearchPattern.folded(have) : want != have { return false }
        }
        return true
    }
}

enum SearchDirection: Equatable {
    case forward
    case backward
}

enum SearchOutcome: Equatable {
    /// The bytes that matched.
    case found(Range<Int64>)
    case notFound
    /// Stopped before the whole file was looked through.
    case cancelled
}

enum ByteSearcher {
    /// The most bytes read at a time.
    static let defaultChunk = 1 << 20

    /// The first match from `start`, going `direction`, and, if `wraps`, round again from the other end.
    ///
    /// Going forward a match may start at `start` or after it; going back, at `start` or before it, so a
    /// caller that wants "the next one after this" passes one past (or before) the match it is on. The
    /// file is read `chunk` bytes of starting positions at a time, with the length of the pattern read
    /// beyond each so that a match across the join is not missed. `isCancelled` is asked between chunks.
    static func find(_ pattern: SearchPattern, in source: ByteSource, startingAt start: Int64, direction: SearchDirection, wraps: Bool = true,
                     chunk: Int = defaultChunk, isCancelled: () -> Bool = { false }, progress: ((Double) -> Void)? = nil) -> SearchOutcome {
        let length = Int64(pattern.count)
        let total = source.count
        guard length > 0, total >= length else { return .notFound }
        let lastStart = total - length
        let size = Int64(max(chunk, 1))
        var scanned: Int64 = 0
        let budget = Double(lastStart + 1)

        // Looks for the first match among starts lo...hi, in the order of `direction`.
        func scan(_ lo: Int64, _ hi: Int64) -> SearchOutcome? {
            guard lo <= hi else { return nil }
            switch direction {
            case .forward:
                var blockLow = lo
                while blockLow <= hi {
                    if isCancelled() { return .cancelled }
                    let blockHigh = min(blockLow + size - 1, hi)
                    let data = source.read(blockLow..<(blockHigh + length))
                    let usable = min(Int64(data.count) - length, blockHigh - blockLow)
                    if usable >= 0 {
                        for offset in 0...Int(usable) where pattern.matches(in: data, at: offset) {
                            return .found((blockLow + Int64(offset))..<(blockLow + Int64(offset) + length))
                        }
                    }
                    scanned += blockHigh - blockLow + 1
                    progress?(min(1, Double(scanned) / budget))
                    blockLow = blockHigh + 1
                }
            case .backward:
                var blockHigh = hi
                while blockHigh >= lo {
                    if isCancelled() { return .cancelled }
                    let blockLow = max(blockHigh - size + 1, lo)
                    let data = source.read(blockLow..<(blockHigh + length))
                    let usable = min(Int64(data.count) - length, blockHigh - blockLow)
                    if usable >= 0 {
                        for offset in stride(from: Int(usable), through: 0, by: -1) where pattern.matches(in: data, at: offset) {
                            return .found((blockLow + Int64(offset))..<(blockLow + Int64(offset) + length))
                        }
                    }
                    scanned += blockHigh - blockLow + 1
                    progress?(min(1, Double(scanned) / budget))
                    blockHigh = blockLow - 1
                }
            }
            return nil
        }

        switch direction {
        case .forward:
            let from = min(max(start, 0), total)
            if let result = scan(from, lastStart) { return result }
            if wraps, let result = scan(0, min(from - 1, lastStart)) { return result }
        case .backward:
            let from = min(start, lastStart)
            if let result = scan(0, from) { return result }
            if wraps, let result = scan(max(start + 1, 0), lastStart) { return result }
        }
        return .notFound
    }
}

/// A file with its edits laid over it, as a `ByteSource`, so a search sees what the panel shows. It holds the
/// buffer as it was when the search began: an edit made while a search runs does not change what that search reads.
final class EditedBytesSource: ByteSource {
    private let buffer: ByteEditBuffer

    init(_ buffer: ByteEditBuffer) {
        self.buffer = buffer
    }

    var count: Int64 { buffer.length }

    func read(_ range: Range<Int64>) -> [UInt8] {
        buffer.read(range)
    }
}
