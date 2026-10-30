import Foundation

/// The parts of the RFB protocol (VNC) that are plain bytes: the messages this
/// app sends, the headers it reads, how a key becomes a keysym. Foundation
/// only, so every one is checked off a Mac; `RFBClient` is what talks to a
/// server.
///
/// Everything read from a server is untrusted. Sizes are bounded here before
/// anything is allocated from them, and a rectangle that does not fit inside the
/// framebuffer is refused — a server that lies about either must not be able to
/// make the app allocate without limit or write outside its own memory.
enum RFB {
    /// A side of the framebuffer can be no more than this, and the whole of it no
    /// more than `maxPixels` (8K UHD): 132 MB at four bytes a pixel.
    static let maxDimension = 16384
    static let maxPixels = 33_177_600
    /// The name a server gives its desktop, and text it puts on the clipboard,
    /// are bounded; the clipboard text is read past and dropped.
    static let maxNameLength = 4096
    static let maxCutTextLength = 1 << 20

    // MARK: Big-endian numbers

    static func u16(_ bytes: [UInt8], _ offset: Int) -> Int {
        (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
    }

    static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }

    static func be16(_ value: Int) -> [UInt8] {
        [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    static func be32(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    // MARK: Version

    struct Version: Equatable {
        var major: Int
        var minor: Int
    }

    /// `RFB 003.008\n`, 12 bytes.
    static func parseVersion(_ bytes: [UInt8]) -> Version? {
        guard bytes.count == 12,
              Array(bytes[0..<4]) == Array("RFB ".utf8),
              bytes[7] == UInt8(ascii: "."), bytes[11] == 0x0A else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            let digits = bytes[range]
            guard digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
            return Int(String(decoding: digits, as: UTF8.self))
        }
        guard let major = number(4..<7), let minor = number(8..<11) else { return nil }
        return Version(major: major, minor: minor)
    }

    /// What to answer a server that says `server`: the newest of 3.3, 3.7 and
    /// 3.8 that it can speak. Nil for anything that is not version 3.
    static func clientVersion(for server: Version) -> Version? {
        guard server.major == 3 else { return nil }
        if server.minor >= 8 { return Version(major: 3, minor: 8) }
        if server.minor == 7 { return Version(major: 3, minor: 7) }
        // 3.4 to 3.6 were never released as such, and are read as 3.3.
        return Version(major: 3, minor: 3)
    }

    static func versionBytes(_ version: Version) -> [UInt8] {
        func three(_ value: Int) -> String {
            let text = String(value)
            return String(repeating: "0", count: max(0, 3 - text.count)) + text
        }
        return Array("RFB \(three(version.major)).\(three(version.minor))\n".utf8)
    }

    // MARK: Security

    static let securityNone: UInt8 = 1
    static let securityVNC: UInt8 = 2

    /// What this client can do: no authentication, or the classic VNC password.
    /// None is preferred when a server offers both — it has nothing to ask for.
    static func chooseSecurity(from offered: [UInt8]) -> UInt8? {
        if offered.contains(securityNone) { return securityNone }
        if offered.contains(securityVNC) { return securityVNC }
        return nil
    }

    /// A sentence for a server that offers nothing this client can use.
    static func unsupportedSecurityMessage(_ offered: [UInt8]) -> String {
        func name(_ type: UInt8) -> String {
            switch type {
            case 5: return "RealVNC (5)"
            case 16: return "Tight (16)"
            case 18: return "TLS (18)"
            case 19: return "VeNCrypt (19)"
            case 30: return "Apple Remote Desktop (30)"
            default: return "type \(type)"
            }
        }
        let list = offered.isEmpty ? "nothing" : offered.map(name).joined(separator: ", ")
        var text = "This server offers \(list), and the built-in viewer only does no authentication or a VNC password."
        if offered.contains(30) {
            text += " macOS Screen Sharing uses Apple's own sign-in by default. In System Settings → General → Sharing → Screen Sharing (ⓘ), turn on “VNC viewers may control screen with password”, or open this service with the system app."
        }
        return text
    }

    // MARK: Messages this client sends

    /// 32 bits a pixel, true colour, little-endian, red in bits 16-23 — so a
    /// pixel is the bytes blue, green, red, unused: what a Core Graphics bitmap
    /// of the `noneSkipFirst` / `byteOrder32Little` kind holds, and a row of a
    /// raw rectangle can be copied into it as it is.
    static func setPixelFormat() -> [UInt8] {
        [0, 0, 0, 0,
         32, 24, 0, 1,
         0, 255, 0, 255, 0, 255,
         16, 8, 0,
         0, 0, 0]
    }

    static let encodingRaw: Int32 = 0
    static let encodingCopyRect: Int32 = 1
    static let encodingDesktopSize: Int32 = -223

    static func setEncodings(_ encodings: [Int32]) -> [UInt8] {
        var bytes: [UInt8] = [2, 0] + be16(encodings.count)
        for encoding in encodings { bytes += be32(UInt32(bitPattern: encoding)) }
        return bytes
    }

    static func framebufferUpdateRequest(incremental: Bool, x: Int, y: Int, width: Int, height: Int) -> [UInt8] {
        [3, incremental ? 1 : 0] + be16(x) + be16(y) + be16(width) + be16(height)
    }

    static func keyEvent(down: Bool, keysym: UInt32) -> [UInt8] {
        [4, down ? 1 : 0, 0, 0] + be32(keysym)
    }

    /// `buttons` is a mask: bit 0 left, 1 middle, 2 right, 3 wheel up, 4 wheel down.
    static func pointerEvent(buttons: UInt8, x: Int, y: Int) -> [UInt8] {
        [5, buttons] + be16(x) + be16(y)
    }

    // MARK: Headers this client reads

    struct ServerInit: Equatable {
        var width: Int
        var height: Int
        var nameLength: Int
    }

    /// The first 24 bytes of ServerInit: size, the server's pixel format (which
    /// this client replaces with its own, so it is not kept) and the name's length.
    static func parseServerInit(_ bytes: [UInt8]) -> ServerInit? {
        guard bytes.count == 24 else { return nil }
        let width = u16(bytes, 0)
        let height = u16(bytes, 2)
        let nameLength = Int(u32(bytes, 20))
        guard isUsableSize(width: width, height: height), nameLength <= maxNameLength else { return nil }
        return ServerInit(width: width, height: height, nameLength: nameLength)
    }

    static func isUsableSize(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= maxDimension && height <= maxDimension
            && width * height <= maxPixels
    }

    struct Rect: Equatable {
        var x: Int
        var y: Int
        var width: Int
        var height: Int
        var encoding: Int32
    }

    /// A rectangle's 12-byte header.
    static func parseRect(_ bytes: [UInt8]) -> Rect? {
        guard bytes.count == 12 else { return nil }
        return Rect(
            x: u16(bytes, 0), y: u16(bytes, 2), width: u16(bytes, 4), height: u16(bytes, 6),
            encoding: Int32(bitPattern: u32(bytes, 8))
        )
    }

    /// Whether a rectangle lies wholly inside a framebuffer of this size. The
    /// arithmetic cannot overflow: every number is at most 65535.
    static func rectFits(_ rect: Rect, width: Int, height: Int) -> Bool {
        rect.x + rect.width <= width && rect.y + rect.height <= height
    }

    // MARK: Keys

    static let shiftKeysym: UInt32 = 0xFFE1
    static let controlKeysym: UInt32 = 0xFFE3
    static let altKeysym: UInt32 = 0xFFE9
    static let superKeysym: UInt32 = 0xFFEB

    /// The keysym for a key that has no character of its own, by macOS's key code.
    static func specialKeysym(forKeyCode code: UInt16) -> UInt32? {
        switch code {
        case 36, 76: return 0xFF0D   // Return, keypad Enter
        case 48: return 0xFF09       // Tab
        case 51: return 0xFF08       // Backspace
        case 53: return 0xFF1B       // Escape
        case 117: return 0xFFFF      // Forward delete
        case 115: return 0xFF50      // Home
        case 119: return 0xFF57      // End
        case 116: return 0xFF55      // Page up
        case 121: return 0xFF56      // Page down
        case 123: return 0xFF51      // Left
        case 126: return 0xFF52      // Up
        case 124: return 0xFF53      // Right
        case 125: return 0xFF54      // Down
        case 122: return 0xFFBE      // F1
        case 120: return 0xFFBF
        case 99: return 0xFFC0
        case 118: return 0xFFC1
        case 96: return 0xFFC2
        case 97: return 0xFFC3
        case 98: return 0xFFC4
        case 100: return 0xFFC5
        case 101: return 0xFFC6
        case 109: return 0xFFC7
        case 103: return 0xFFC8
        case 111: return 0xFFC9      // F12
        default: return nil
        }
    }

    /// The keysym for a character: Latin-1 stands for itself, anything else is
    /// the Unicode code point with `0x01000000` added, as X11 defines.
    static func keysym(forCharacter scalar: Unicode.Scalar) -> UInt32? {
        let value = scalar.value
        // Control characters, and the private-use range macOS uses for arrow
        // and function keys, are not text.
        if value < 0x20 || value == 0x7F || (0xF700...0xF8FF).contains(value) { return nil }
        if value <= 0xFF { return value }
        return 0x0100_0000 + value
    }
}
