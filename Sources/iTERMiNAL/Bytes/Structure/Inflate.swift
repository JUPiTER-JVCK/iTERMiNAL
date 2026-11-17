import Foundation

/// Decompresses deflate (RFC 1951), the compression inside ZIP entries, gzip and PNG, so that what a file
/// says about its compressed data (a CRC, a size) can be checked against the data itself.
///
/// It reads its input through a `ByteSource` a piece at a time and hands its output on a piece at a time,
/// so a check never holds a whole entry. It does not trust the data: every code is checked, a distance that
/// reaches back before the start is refused, and it stops at `limit` bytes of output, so a small hostile
/// entry that would expand to gigabytes costs no more than the limit.
///
/// Foundation only, so it is checked in CI against what zlib makes.
enum Inflate {
    enum Failure: Error, Equatable {
        /// The input ended before the last block did.
        case truncated
        /// A block of type 3, which does not exist.
        case badBlockType
        /// A stored block whose length and its complement disagree.
        case storedLength
        /// A table of code lengths that makes no code, or too many of them.
        case badCodeLengths
        /// Bits that are no code in the table in use.
        case badCode
        /// A copy from further back than the start of the output.
        case distanceTooFar(Int64)
        /// More output than the limit.
        case tooLarge(Int64)
        case cancelled
    }

    /// What one run found.
    struct Summary: Equatable {
        /// Bytes of output.
        var produced: Int64
        /// Bytes of input up to the end of the last block.
        var consumed: Int64
        var blocks: Int
    }

    /// Words for a failure.
    static func message(_ failure: Failure) -> String {
        switch failure {
        case .truncated: return "the compressed data ends before its last block does"
        case .badBlockType: return "a block has type 3, which does not exist"
        case .storedLength: return "a stored block's length and its check disagree"
        case .badCodeLengths: return "a block's table of codes is not a valid one"
        case .badCode: return "the bits are not a code in the block's table"
        case .distanceTooFar(let at): return "a copy reaches back before the start of the data, at output byte \(at)"
        case .tooLarge(let limit): return "it expands to more than \(FieldText.bytes(limit))"
        case .cancelled: return "stopped"
        }
    }

    // MARK: Entry points

    /// Decompresses the deflate stream in `range` of `source`, giving the output to `output` in pieces.
    static func inflate(_ source: ByteSource, range: Range<Int64>, limit: Int64, isCancelled: () -> Bool = { false },
                        output: @escaping (ArraySlice<UInt8>) -> Void) -> Result<Summary, Failure> {
        var input = BitInput(source: source, range: range)
        var state = Inflater(limit: limit, output: output)
        do {
            try state.run(&input, isCancelled: isCancelled)
            state.flush()
            return .success(Summary(produced: state.produced, consumed: input.consumedBytes, blocks: state.blocks))
        } catch let failure as Failure {
            state.flush()
            return .failure(failure)
        } catch {
            return .failure(.badCode)
        }
    }

    /// The whole output of `bytes`, for tests and small streams.
    static func inflate(_ bytes: [UInt8], limit: Int64 = 1 << 26) -> Result<[UInt8], Failure> {
        var result: [UInt8] = []
        let outcome = inflate(DataByteSource(bytes), range: 0..<Int64(bytes.count), limit: limit) { result.append(contentsOf: $0) }
        switch outcome {
        case .success: return .success(result)
        case .failure(let failure): return .failure(failure)
        }
    }

    // MARK: Tables

    static let lengthBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distanceBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
                                      4097, 6145, 8193, 12289, 16385, 24577]
    static let distanceExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    /// The order the lengths of the code-length code are written in.
    static let codeLengthOrder: [Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    static let fixedLiterals: Huffman = {
        var lengths = [UInt8](repeating: 8, count: 288)
        for symbol in 144..<256 { lengths[symbol] = 9 }
        for symbol in 256..<280 { lengths[symbol] = 7 }
        return Huffman(lengths: lengths)!
    }()
    static let fixedDistances = Huffman(lengths: [UInt8](repeating: 5, count: 32))!

    /// A canonical Huffman code as a lookup table: the next `bits` bits of input, first bit lowest, index an
    /// entry holding the symbol and how many of those bits its code is.
    struct Huffman {
        /// symbol << 4 | code length; 0 where no code begins with those bits.
        let table: [UInt16]
        let bits: Int

        /// Nil if the lengths make more codes than there is room for, or, as zlib has it, fewer: a code that leaves
        /// bit patterns unused is only allowed when it is a single one-bit code (`lone`), or no code at all.
        init?(lengths: [UInt8], allowsLone: Bool = true) {
            var count = [Int](repeating: 0, count: 16)
            for length in lengths {
                guard length <= 15 else { return nil }
                count[Int(length)] += 1
            }
            count[0] = 0
            var left = 1
            for length in 1...15 {
                left <<= 1
                left -= count[length]
                if left < 0 { return nil }
            }
            let maxBits = (1...15).last { count[$0] > 0 } ?? 0
            if left > 0, maxBits > 0, !(allowsLone && maxBits == 1) { return nil }
            var next = [Int](repeating: 0, count: 16)
            var code = 0
            for length in 1...15 {
                code = (code + count[length - 1]) << 1
                next[length] = code
            }
            var table = [UInt16](repeating: 0, count: 1 << maxBits)
            for (symbol, length) in lengths.enumerated() where length > 0 {
                let size = Int(length)
                let value = next[size]
                next[size] += 1
                var reversed = 0
                for bit in 0..<size where value & (1 << bit) != 0 { reversed |= 1 << (size - 1 - bit) }
                let entry = UInt16(symbol << 4 | size)
                var index = reversed
                while index < table.count {
                    table[index] = entry
                    index += 1 << size
                }
            }
            self.table = table
            bits = maxBits
        }
    }

    // MARK: Input

    /// Bits from a range of a source, first bit lowest. Past the end it gives zeros and remembers it did, so a
    /// read that used them is a truncation.
    struct BitInput {
        let source: ByteSource
        let start: Int64
        let end: Int64
        var next: Int64
        var chunk: [UInt8] = []
        var index = 0
        var buffer: UInt64 = 0
        var count = 0
        /// Zero bits added past the end of the input, at the top of `buffer`.
        var padding = 0

        init(source: ByteSource, range: Range<Int64>) {
            self.source = source
            start = max(0, range.lowerBound)
            next = start
            end = min(range.upperBound, source.count)
        }

        /// Bytes taken from the input that no bit has been used of yet are given back.
        var consumedBytes: Int64 {
            let pulled = next - start - Int64(chunk.count - index)
            return pulled - Int64(max(0, count - padding) / 8)
        }

        mutating func fill(_ wanted: Int) {
            while count < wanted {
                if index >= chunk.count {
                    if next < end {
                        chunk = source.read(next..<min(next + 65_536, end))
                        next += Int64(chunk.count)
                        index = 0
                    }
                    if chunk.isEmpty || index >= chunk.count {
                        padding += 8
                        count += 8
                        continue
                    }
                }
                buffer |= UInt64(chunk[index]) << UInt64(count)
                index += 1
                count += 8
            }
        }

        mutating func take(_ bits: Int) throws -> Int {
            guard bits > 0 else { return 0 }
            fill(bits)
            let value = Int(buffer & ((1 << UInt64(bits)) - 1))
            drop(bits)
            if count < padding { throw Failure.truncated }
            return value
        }

        mutating func drop(_ bits: Int) {
            buffer >>= UInt64(bits)
            count -= bits
        }

        mutating func decode(_ code: Huffman) throws -> Int {
            guard code.bits > 0 else { throw Failure.badCode }
            fill(code.bits)
            let entry = code.table[Int(buffer & ((1 << UInt64(code.bits)) - 1))]
            let length = Int(entry & 15)
            guard length > 0 else { throw Failure.badCode }
            drop(length)
            if count < padding { throw Failure.truncated }
            return Int(entry >> 4)
        }

        /// Skips to the next whole byte.
        mutating func align() {
            drop(count % 8)
        }
    }

    // MARK: Output

    struct Inflater {
        let limit: Int64
        let output: (ArraySlice<UInt8>) -> Void
        var window = [UInt8](repeating: 0, count: 32_768)
        var pending: [UInt8] = []
        var produced: Int64 = 0
        var blocks = 0

        init(limit: Int64, output: @escaping (ArraySlice<UInt8>) -> Void) {
            self.limit = limit
            self.output = output
            pending.reserveCapacity(65_536)
        }

        mutating func flush() {
            guard !pending.isEmpty else { return }
            output(pending[...])
            pending.removeAll(keepingCapacity: true)
        }

        mutating func emit(_ byte: UInt8) throws {
            guard produced < limit else { throw Failure.tooLarge(limit) }
            window[Int(produced & 32_767)] = byte
            produced += 1
            pending.append(byte)
            if pending.count >= 65_536 { flush() }
        }

        mutating func run(_ input: inout BitInput, isCancelled: () -> Bool) throws {
            var last = false
            while !last {
                if isCancelled() { throw Failure.cancelled }
                last = try input.take(1) == 1
                blocks += 1
                switch try input.take(2) {
                case 0:
                    input.align()
                    let length = try input.take(16)
                    let check = try input.take(16)
                    guard length == ~check & 0xFFFF else { throw Failure.storedLength }
                    for _ in 0..<length { try emit(UInt8(try input.take(8))) }
                case 1:
                    try codes(&input, literals: Inflate.fixedLiterals, distances: Inflate.fixedDistances, isCancelled: isCancelled)
                case 2:
                    let (literals, distances) = try dynamicTables(&input)
                    try codes(&input, literals: literals, distances: distances, isCancelled: isCancelled)
                default:
                    throw Failure.badBlockType
                }
            }
        }

        private func dynamicTables(_ input: inout BitInput) throws -> (Huffman, Huffman) {
            let literalCount = try input.take(5) + 257
            let distanceCount = try input.take(5) + 1
            let lengthCount = try input.take(4) + 4
            guard literalCount <= 286, distanceCount <= 30 else { throw Failure.badCodeLengths }
            var lengthLengths = [UInt8](repeating: 0, count: 19)
            for index in 0..<lengthCount { lengthLengths[Inflate.codeLengthOrder[index]] = UInt8(try input.take(3)) }
            guard let lengthCode = Huffman(lengths: lengthLengths, allowsLone: false), lengthCode.bits > 0 else { throw Failure.badCodeLengths }
            var lengths: [UInt8] = []
            let wanted = literalCount + distanceCount
            while lengths.count < wanted {
                let symbol = try input.decode(lengthCode)
                switch symbol {
                case 0...15:
                    lengths.append(UInt8(symbol))
                case 16:
                    guard let previous = lengths.last else { throw Failure.badCodeLengths }
                    let repeats = 3 + (try input.take(2))
                    guard lengths.count + repeats <= wanted else { throw Failure.badCodeLengths }
                    lengths += [UInt8](repeating: previous, count: repeats)
                case 17, 18:
                    let repeats = symbol == 17 ? 3 + (try input.take(3)) : 11 + (try input.take(7))
                    guard lengths.count + repeats <= wanted else { throw Failure.badCodeLengths }
                    lengths += [UInt8](repeating: 0, count: repeats)
                default:
                    throw Failure.badCodeLengths
                }
            }
            // A block with no end-of-block code could never end.
            guard lengths[256] > 0,
                  let literals = Huffman(lengths: Array(lengths[0..<literalCount])),
                  let distances = Huffman(lengths: Array(lengths[literalCount...])) else { throw Failure.badCodeLengths }
            return (literals, distances)
        }

        private mutating func codes(_ input: inout BitInput, literals: Huffman, distances: Huffman, isCancelled: () -> Bool) throws {
            var steps = 0
            while true {
                steps += 1
                if steps & 0xFFFF == 0, isCancelled() { throw Failure.cancelled }
                let symbol = try input.decode(literals)
                if symbol < 256 {
                    try emit(UInt8(symbol))
                    continue
                }
                if symbol == 256 { return }
                let lengthIndex = symbol - 257
                guard lengthIndex < Inflate.lengthBase.count else { throw Failure.badCode }
                let length = Inflate.lengthBase[lengthIndex] + (try input.take(Inflate.lengthExtra[lengthIndex]))
                let distanceSymbol = try input.decode(distances)
                guard distanceSymbol < Inflate.distanceBase.count else { throw Failure.badCode }
                let distance = Inflate.distanceBase[distanceSymbol] + (try input.take(Inflate.distanceExtra[distanceSymbol]))
                guard Int64(distance) <= produced else { throw Failure.distanceTooFar(produced) }
                for _ in 0..<length {
                    try emit(window[Int((produced - Int64(distance)) & 32_767)])
                }
            }
        }
    }
}
