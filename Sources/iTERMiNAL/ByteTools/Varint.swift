import Foundation

/// Variable-length integers (LEB128, as Protocol Buffers, WebAssembly and DWARF
/// write them) and ZigZag, which folds negative numbers into small positive
/// ones so they stay short.
///
/// Each byte carries seven bits of the number, lowest group first, and its top
/// bit says whether another byte follows.
enum Varint {
    /// A varint can be at most ten bytes for 64 bits of number.
    static let maxLength = 10

    static func encode(_ value: UInt64) -> [UInt8] {
        var rest = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(rest & 0x7F)
            rest >>= 7
            if rest != 0 { byte |= 0x80 }
            out.append(byte)
        } while rest != 0
        return out
    }

    /// One varint starting at `start`: the number and how many bytes it took,
    /// or nil if the bytes end in the middle of it or it runs past ten bytes.
    static func decode(_ bytes: [UInt8], at start: Int = 0) -> (value: UInt64, length: Int)? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var index = start
        while index < bytes.count, index - start < maxLength {
            let byte = bytes[index]
            let payload = UInt64(byte & 0x7F)
            if shift == 63 && payload > 1 { return nil }
            value |= payload << shift
            index += 1
            if byte & 0x80 == 0 { return (value, index - start) }
            shift += 7
        }
        return nil
    }

    /// Every varint in `bytes`, one after another, and how many bytes at the
    /// end could not be read as one.
    static func decodeAll(_ bytes: [UInt8]) -> (values: [UInt64], leftover: Int) {
        var values: [UInt64] = []
        var index = 0
        while index < bytes.count, let next = decode(bytes, at: index) {
            values.append(next.value)
            index += next.length
        }
        return (values, bytes.count - index)
    }

    /// One byte of a varint, taken apart for display.
    struct Group: Equatable {
        let byte: UInt8
        /// The seven bits of the number this byte carries.
        let payload: UInt8
        /// Whether the top bit says another byte follows.
        let continues: Bool
    }

    static func groups(_ bytes: [UInt8]) -> [Group] {
        bytes.map { Group(byte: $0, payload: $0 & 0x7F, continues: $0 & 0x80 != 0) }
    }

    // MARK: ZigZag

    static func zigzag(_ value: Int64) -> UInt64 {
        UInt64(bitPattern: (value << 1) ^ (value >> 63))
    }

    static func unzigzag(_ value: UInt64) -> Int64 {
        Int64(bitPattern: value >> 1) ^ -Int64(bitPattern: value & 1)
    }
}
