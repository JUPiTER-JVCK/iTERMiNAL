import Foundation

/// Hashes and checksums the Byte Tools can compute, all written in plain Swift
/// so they work on any bytes without a framework and can be checked against
/// published test vectors.
enum DigestAlgorithm: String, CaseIterable, Identifiable {
    case md5, sha1, sha224, sha256, sha384, sha512
    case crc32, crc32c, crc16arc, crc16ccitt, crc16xmodem, crc16modbus, crc8, adler32, fnv1a32, fnv1a64

    var id: String { rawValue }

    var title: String {
        switch self {
        case .md5: return "MD5"
        case .sha1: return "SHA-1"
        case .sha224: return "SHA-224"
        case .sha256: return "SHA-256"
        case .sha384: return "SHA-384"
        case .sha512: return "SHA-512"
        case .crc32: return "CRC-32"
        case .crc32c: return "CRC-32C"
        case .crc16arc: return "CRC-16/ARC"
        case .crc16ccitt: return "CRC-16/CCITT-FALSE"
        case .crc16xmodem: return "CRC-16/XMODEM"
        case .crc16modbus: return "CRC-16/MODBUS"
        case .crc8: return "CRC-8"
        case .adler32: return "Adler-32"
        case .fnv1a32: return "FNV-1a 32"
        case .fnv1a64: return "FNV-1a 64"
        }
    }

    /// A cryptographic hash, as opposed to a checksum that only catches accidents.
    var isCryptographic: Bool {
        switch self {
        case .md5, .sha1, .sha224, .sha256, .sha384, .sha512: return true
        default: return false
        }
    }

    /// A caution to show beside the result, or nil when there is none.
    var caution: String? {
        switch self {
        case .md5: return "Broken: collisions can be made on purpose. Fine for spotting accidents, not for security."
        case .sha1: return "Broken: collisions have been demonstrated. Do not use it where an attacker chooses the input."
        case .crc32, .crc32c, .crc16arc, .crc16ccitt, .crc16xmodem, .crc16modbus, .crc8, .adler32, .fnv1a32, .fnv1a64:
            return "A checksum, not a security hash: anyone can change data and fix the check value."
        default: return nil
        }
    }

    /// The block size HMAC needs, for the algorithms it is defined over.
    private var hmacBlockSize: Int? {
        switch self {
        case .md5, .sha1, .sha224, .sha256: return 64
        case .sha384, .sha512: return 128
        default: return nil
        }
    }

    var supportsHMAC: Bool { hmacBlockSize != nil }

    func digest(_ bytes: [UInt8]) -> [UInt8] {
        switch self {
        case .md5: return MD5.hash(bytes)
        case .sha1: return SHA1.hash(bytes)
        case .sha224: return SHA256Family.hash(bytes, is224: true)
        case .sha256: return SHA256Family.hash(bytes, is224: false)
        case .sha384: return SHA512Family.hash(bytes, is384: true)
        case .sha512: return SHA512Family.hash(bytes, is384: false)
        case .crc32: return DigestAlgorithm.bigEndian(UInt64(CRC32.checksum(bytes)), 4)
        case .crc32c: return DigestAlgorithm.bigEndian(UInt64(CRCEngine.crc32c.checksum(bytes)), 4)
        case .crc16arc: return DigestAlgorithm.bigEndian(UInt64(CRCEngine.crc16arc.checksum(bytes)), 2)
        case .crc16ccitt: return DigestAlgorithm.bigEndian(UInt64(CRCEngine.crc16ccitt.checksum(bytes)), 2)
        case .crc16xmodem: return DigestAlgorithm.bigEndian(UInt64(CRCEngine.crc16xmodem.checksum(bytes)), 2)
        case .crc16modbus: return DigestAlgorithm.bigEndian(UInt64(CRCEngine.crc16modbus.checksum(bytes)), 2)
        case .crc8: return DigestAlgorithm.bigEndian(UInt64(CRCEngine.crc8.checksum(bytes)), 1)
        case .adler32:
            var a: UInt32 = 1
            var b: UInt32 = 0
            for byte in bytes {
                a = (a + UInt32(byte)) % 65521
                b = (b + a) % 65521
            }
            return DigestAlgorithm.bigEndian(UInt64(b << 16 | a), 4)
        case .fnv1a32:
            var hash: UInt32 = 0x811C9DC5
            for byte in bytes { hash = (hash ^ UInt32(byte)) &* 0x0100_0193 }
            return DigestAlgorithm.bigEndian(UInt64(hash), 4)
        case .fnv1a64:
            var hash: UInt64 = 0xCBF2_9CE4_8422_2325
            for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
            return DigestAlgorithm.bigEndian(hash, 8)
        }
    }

    /// HMAC (RFC 2104) with this hash, or nil for one it is not defined over.
    func hmac(key: [UInt8], message: [UInt8]) -> [UInt8]? {
        guard let block = hmacBlockSize else { return nil }
        var keyBlock = key.count > block ? digest(key) : key
        keyBlock += [UInt8](repeating: 0, count: block - keyBlock.count)
        let inner = digest(keyBlock.map { $0 ^ 0x36 } + message)
        return digest(keyBlock.map { $0 ^ 0x5C } + inner)
    }

    private static func bigEndian(_ value: UInt64, _ count: Int) -> [UInt8] {
        (0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
    }
}

// MARK: - MD5

enum MD5 {
    private static let shifts: [UInt32] = [
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    ]

    /// floor(2^32 × |sin(i + 1)|), as RFC 1321 defines them.
    private static let constants: [UInt32] = (0..<64).map { UInt32(truncatingIfNeeded: Int64(abs(sin(Double($0 + 1))) * 4294967296.0)) }

    static func hash(_ message: [UInt8]) -> [UInt8] {
        var a0: UInt32 = 0x67452301
        var b0: UInt32 = 0xEFCDAB89
        var c0: UInt32 = 0x98BADCFE
        var d0: UInt32 = 0x10325476
        var data = message
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        let bitLength = UInt64(message.count) &* 8
        for i in 0..<8 { data.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(8 * i))) }
        for chunk in stride(from: 0, to: data.count, by: 64) {
            var m = [UInt32](repeating: 0, count: 16)
            for i in 0..<16 {
                let j = chunk + i * 4
                m[i] = UInt32(data[j]) | UInt32(data[j + 1]) << 8 | UInt32(data[j + 2]) << 16 | UInt32(data[j + 3]) << 24
            }
            var a = a0, b = b0, c = c0, d = d0
            for i in 0..<64 {
                var f: UInt32
                var g: Int
                switch i {
                case 0..<16: f = (b & c) | (~b & d); g = i
                case 16..<32: f = (d & b) | (~d & c); g = (5 * i + 1) % 16
                case 32..<48: f = b ^ c ^ d; g = (3 * i + 5) % 16
                default: f = c ^ (b | ~d); g = (7 * i) % 16
                }
                f = f &+ a &+ constants[i] &+ m[g]
                a = d
                d = c
                c = b
                b = b &+ ((f << shifts[i]) | (f >> (32 - shifts[i])))
            }
            a0 = a0 &+ a
            b0 = b0 &+ b
            c0 = c0 &+ c
            d0 = d0 &+ d
        }
        var out: [UInt8] = []
        for word in [a0, b0, c0, d0] {
            for i in 0..<4 { out.append(UInt8(truncatingIfNeeded: word >> UInt32(8 * i))) }
        }
        return out
    }
}

// MARK: - SHA-1

enum SHA1 {
    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
        var data = message
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        let bitLength = UInt64(message.count) &* 8
        for i in (0..<8).reversed() { data.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(8 * i))) }
        for chunk in stride(from: 0, to: data.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 80)
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(data[j]) << 24 | UInt32(data[j + 1]) << 16 | UInt32(data[j + 2]) << 8 | UInt32(data[j + 3])
            }
            for i in 16..<80 {
                let x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
                w[i] = (x << 1) | (x >> 31)
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4]
            for i in 0..<80 {
                let f: UInt32
                let k: UInt32
                switch i {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5A827999
                case 20..<40: f = b ^ c ^ d; k = 0x6ED9EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
                default: f = b ^ c ^ d; k = 0xCA62C1D6
                }
                let temp = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ w[i]
                e = d
                d = c
                c = (b << 30) | (b >> 2)
                b = a
                a = temp
            }
            h[0] = h[0] &+ a
            h[1] = h[1] &+ b
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
            h[4] = h[4] &+ e
        }
        return h.flatMap { word in (0..<4).reversed().map { UInt8(truncatingIfNeeded: word >> UInt32(8 * $0)) } }
    }
}

// MARK: - SHA-224 / SHA-256

enum SHA256Family {
    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

    static func hash(_ message: [UInt8], is224: Bool) -> [UInt8] {
        var h = is224 ? SHA2Constants.h224 : SHA2Constants.h256
        var data = message
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        let bitLength = UInt64(message.count) &* 8
        for i in (0..<8).reversed() { data.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(8 * i))) }
        let k = SHA2Constants.k256
        for chunk in stride(from: 0, to: data.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(data[j]) << 24 | UInt32(data[j + 1]) << 16 | UInt32(data[j + 2]) << 8 | UInt32(data[j + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g
                g = f
                f = e
                e = d &+ t1
                d = c
                c = b
                b = a
                a = t1 &+ t2
            }
            h[0] = h[0] &+ a
            h[1] = h[1] &+ b
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
            h[4] = h[4] &+ e
            h[5] = h[5] &+ f
            h[6] = h[6] &+ g
            h[7] = h[7] &+ hh
        }
        let words = is224 ? Array(h[0..<7]) : h
        return words.flatMap { word in (0..<4).reversed().map { UInt8(truncatingIfNeeded: word >> UInt32(8 * $0)) } }
    }
}

// MARK: - SHA-384 / SHA-512

enum SHA512Family {
    private static func rotr(_ x: UInt64, _ n: UInt64) -> UInt64 { (x >> n) | (x << (64 - n)) }

    static func hash(_ message: [UInt8], is384: Bool) -> [UInt8] {
        var h = is384 ? SHA2Constants.h384 : SHA2Constants.h512
        var data = message
        data.append(0x80)
        while data.count % 128 != 112 { data.append(0) }
        // A 128-bit length: the high half is zero for any input that fits in memory.
        data.append(contentsOf: [UInt8](repeating: 0, count: 8))
        let bitLength = UInt64(message.count) &* 8
        for i in (0..<8).reversed() { data.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(8 * i))) }
        let k = SHA2Constants.k512
        for chunk in stride(from: 0, to: data.count, by: 128) {
            var w = [UInt64](repeating: 0, count: 80)
            for i in 0..<16 {
                var word: UInt64 = 0
                for j in 0..<8 { word = word << 8 | UInt64(data[chunk + i * 8 + j]) }
                w[i] = word
            }
            for i in 16..<80 {
                let s0 = rotr(w[i - 15], 1) ^ rotr(w[i - 15], 8) ^ (w[i - 15] >> 7)
                let s1 = rotr(w[i - 2], 19) ^ rotr(w[i - 2], 61) ^ (w[i - 2] >> 6)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for i in 0..<80 {
                let s1 = rotr(e, 14) ^ rotr(e, 18) ^ rotr(e, 41)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 28) ^ rotr(a, 34) ^ rotr(a, 39)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                hh = g
                g = f
                f = e
                e = d &+ t1
                d = c
                c = b
                b = a
                a = t1 &+ t2
            }
            h[0] = h[0] &+ a
            h[1] = h[1] &+ b
            h[2] = h[2] &+ c
            h[3] = h[3] &+ d
            h[4] = h[4] &+ e
            h[5] = h[5] &+ f
            h[6] = h[6] &+ g
            h[7] = h[7] &+ hh
        }
        let words = is384 ? Array(h[0..<6]) : h
        return words.flatMap { word in (0..<8).reversed().map { UInt8(truncatingIfNeeded: word >> UInt64(8 * $0)) } }
    }
}

// MARK: - CRC

/// A table-driven CRC of any width up to 32 bits, described the way the
/// standard catalogue describes them.
struct CRCEngine {
    let width: Int
    let polynomial: UInt32
    let initial: UInt32
    let reflectIn: Bool
    let reflectOut: Bool
    let xorOut: UInt32

    static let crc8 = CRCEngine(width: 8, polynomial: 0x07, initial: 0, reflectIn: false, reflectOut: false, xorOut: 0)
    static let crc16arc = CRCEngine(width: 16, polynomial: 0x8005, initial: 0, reflectIn: true, reflectOut: true, xorOut: 0)
    static let crc16ccitt = CRCEngine(width: 16, polynomial: 0x1021, initial: 0xFFFF, reflectIn: false, reflectOut: false, xorOut: 0)
    static let crc16xmodem = CRCEngine(width: 16, polynomial: 0x1021, initial: 0, reflectIn: false, reflectOut: false, xorOut: 0)
    static let crc16modbus = CRCEngine(width: 16, polynomial: 0x8005, initial: 0xFFFF, reflectIn: true, reflectOut: true, xorOut: 0)
    static let crc32c = CRCEngine(width: 32, polynomial: 0x1EDC6F41, initial: 0xFFFF_FFFF, reflectIn: true, reflectOut: true, xorOut: 0xFFFF_FFFF)

    private static func reflect(_ value: UInt32, _ bits: Int) -> UInt32 {
        var result: UInt32 = 0
        for i in 0..<bits where value >> UInt32(i) & 1 == 1 { result |= 1 << UInt32(bits - 1 - i) }
        return result
    }

    func checksum(_ bytes: [UInt8]) -> UInt32 {
        let top = UInt32(1) << UInt32(width - 1)
        let mask: UInt32 = width == 32 ? 0xFFFF_FFFF : (UInt32(1) << UInt32(width)) - 1
        var crc = initial & mask
        for byte in bytes {
            let input = reflectIn ? UInt32(CRCEngine.reflect(UInt32(byte), 8)) : UInt32(byte)
            crc ^= input << UInt32(width - 8)
            for _ in 0..<8 {
                crc = crc & top != 0 ? (crc << 1) ^ polynomial : crc << 1
                crc &= mask
            }
        }
        if reflectOut { crc = CRCEngine.reflect(crc, width) }
        return (crc ^ xorOut) & mask
    }
}
