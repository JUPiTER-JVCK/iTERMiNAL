import Foundation
import CommonCrypto

/// The one piece of VNC's classic sign-in: the server sends 16 random bytes and
/// the client answers with them encrypted, DES, under the password. The
/// password itself is never sent.
///
/// Weak by modern standards (DES, a password cut to eight characters, and a
/// challenge anyone watching the connection can also see), which is why the
/// viewer says so and offers to carry the connection through SSH. It is also
/// what a server that asks for a "VNC password" requires.
///
/// Not Foundation-only: DES is CommonCrypto's, and writing it out by hand would
/// mean typing its tables from memory. The macOS run of the input-logic check
/// compiles this and tests it against the standard DES test vector.
enum RFBAuth {
    /// VNC's quirk: each byte of the key has its bits in the opposite order to
    /// the one DES expects.
    static func reversedBits(_ byte: UInt8) -> UInt8 {
        var input = byte
        var output: UInt8 = 0
        for _ in 0..<8 {
            output = (output << 1) | (input & 1)
            input >>= 1
        }
        return output
    }

    /// The first eight bytes of the password, padded with zeros, bit-reversed.
    static func key(forPassword password: String) -> [UInt8] {
        var bytes = Array(password.utf8.prefix(8))
        while bytes.count < 8 { bytes.append(0) }
        return bytes.map(reversedBits)
    }

    /// One block, DES in ECB mode with an eight-byte key. Nil if CommonCrypto
    /// refuses, which it does not for these sizes.
    static func desEncrypt(block: [UInt8], key: [UInt8]) -> [UInt8]? {
        guard block.count == 8, key.count == 8 else { return nil }
        var output = [UInt8](repeating: 0, count: 8 + kCCBlockSizeDES)
        var written = 0
        let status = CCCrypt(
            CCOperation(kCCEncrypt),
            CCAlgorithm(kCCAlgorithmDES),
            CCOptions(kCCOptionECBMode),
            key, kCCKeySizeDES,
            nil,
            block, 8,
            &output, output.count,
            &written
        )
        guard status == CCCryptorStatus(kCCSuccess), written >= 8 else { return nil }
        return Array(output.prefix(8))
    }

    /// The 16 bytes to send back for a 16-byte challenge.
    static func response(challenge: [UInt8], password: String) -> [UInt8]? {
        guard challenge.count == 16 else { return nil }
        let key = key(forPassword: password)
        guard let first = desEncrypt(block: Array(challenge[0..<8]), key: key),
              let second = desEncrypt(block: Array(challenge[8..<16]), key: key) else { return nil }
        return first + second
    }
}
