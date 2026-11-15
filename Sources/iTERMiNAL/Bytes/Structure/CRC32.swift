import Foundation

/// The CRC-32 that PNG, zip and gzip use (polynomial 0xEDB88320, reflected), made in
/// steps so a chunk of any size can be checked without holding it.
///
///     var crc = CRC32()
///     crc.update(typeBytes)
///     crc.update(dataBytes)
///     crc.value   // what the file should hold
struct CRC32 {
    private var state: UInt32 = 0xFFFF_FFFF

    var value: UInt32 { ~state }

    mutating func update(_ bytes: [UInt8]) {
        update(bytes[...])
    }

    mutating func update(_ bytes: ArraySlice<UInt8>) {
        var crc = state
        for byte in bytes {
            crc = CRC32.table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        state = crc
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc = CRC32()
        crc.update(bytes)
        return crc.value
    }

    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
        }
        return value
    }
}
