import Foundation

/// The ways a selection can be copied out of the panel, for pasting into a
/// terminal, a source file, a notebook or a chat. Foundation only, so what each
/// one writes is checked.
enum ByteExportFormat: String, CaseIterable, Equatable {
    case spacedHex, hex, cArray, pythonBytes, base64, text

    var title: String {
        switch self {
        case .spacedHex: return "Hex, spaced"
        case .hex: return "Hex"
        case .cArray: return "C array"
        case .pythonBytes: return "Python bytes"
        case .base64: return "Base64"
        case .text: return "Text"
        }
    }
}

enum ByteExport {
    /// The most that is copied in one go: past this a paste is a mistake, not a
    /// choice, and building the string would be the slow part.
    static let maxBytes = 16 * 1024 * 1024

    /// `bytes` written as `format`. The caller keeps to `maxBytes`.
    static func string(_ bytes: [UInt8], as format: ByteExportFormat) -> String {
        switch format {
        case .spacedHex:
            return hexString(bytes, separator: " ")
        case .hex:
            return hexString(bytes, separator: "")
        case .cArray:
            return cArray(bytes)
        case .pythonBytes:
            return "b\"" + bytes.map { "\\x" + ByteRadix.hex.cell($0).lowercased() }.joined() + "\""
        case .base64:
            return Data(bytes).base64EncodedString()
        case .text:
            return String(decoding: bytes.map(HexGeometry.textByte), as: UTF8.self)
        }
    }

    private static func hexString(_ bytes: [UInt8], separator: String) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 3)
        for (index, byte) in bytes.enumerated() {
            if index > 0, !separator.isEmpty { out.append(contentsOf: Array(separator.utf8)) }
            ByteRadix.hex.append(byte, to: &out)
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// `unsigned char data[] = { 0x48, 0x65, ... };`, twelve to a line.
    private static func cArray(_ bytes: [UInt8]) -> String {
        guard !bytes.isEmpty else { return "unsigned char data[] = {};" }
        var lines: [String] = []
        for start in stride(from: 0, to: bytes.count, by: 12) {
            let row = bytes[start..<min(start + 12, bytes.count)]
            lines.append("    " + row.map { "0x" + ByteRadix.hex.cell($0) }.joined(separator: ", "))
        }
        return "unsigned char data[] = {\n" + lines.joined(separator: ",\n") + "\n};"
    }
}
