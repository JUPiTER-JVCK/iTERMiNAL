import Foundation

/// The view every reverse engineer lives in: a byte offset, the bytes in hex,
/// and the printable ASCII beside them. Writes the two layouts the command line
/// tools print (`hexdump -C` and `xxd`) and reads those and plain hex back.
enum HexDump {
    enum Layout: String, CaseIterable, Identifiable {
        /// `hexdump -C`: single bytes, a gap after the eighth, ASCII in bars.
        case canonical
        /// `xxd`: a colon after the offset, bytes in pairs, ASCII after two spaces.
        case xxd

        var id: String { rawValue }
        var title: String { self == .canonical ? "hexdump -C" : "xxd" }
    }

    /// One printed row: where it starts, its bytes, and its text. The pieces
    /// are kept apart so the panel can colour each differently.
    struct Row: Equatable {
        let offset: Int
        let bytes: [UInt8]
        let ascii: String
    }

    static func rows(_ bytes: [UInt8], perLine: Int) -> [Row] {
        let width = max(1, perLine)
        return stride(from: 0, to: bytes.count, by: width).map { start in
            let chunk = Array(bytes[start..<min(start + width, bytes.count)])
            return Row(offset: start, bytes: chunk, ascii: asciiText(chunk))
        }
    }

    /// The printable ASCII of `bytes`, with `.` for the rest.
    static func asciiText(_ bytes: [UInt8]) -> String {
        String(bytes.map { $0 >= 0x20 && $0 <= 0x7E ? Character(UnicodeScalar($0)) : "." })
    }

    static func format(
        _ bytes: [UInt8],
        layout: Layout = .canonical,
        perLine: Int = 16,
        uppercase: Bool = false
    ) -> String {
        let width = max(1, perLine)
        let digits = Array(uppercase ? "0123456789ABCDEF" : "0123456789abcdef")
        func hex(_ byte: UInt8) -> String { String([digits[Int(byte >> 4)], digits[Int(byte & 15)]]) }
        func offsetText(_ offset: Int) -> String {
            let text = String(offset, radix: 16, uppercase: uppercase)
            return String(repeating: "0", count: max(0, 8 - text.count)) + text
        }
        var lines: [String] = []
        for row in rows(bytes, perLine: width) {
            switch layout {
            case .canonical:
                var hexPart = ""
                for index in 0..<width {
                    if index < row.bytes.count {
                        hexPart += hex(row.bytes[index]) + " "
                    } else {
                        hexPart += "   "
                    }
                    if index == 7 && width > 8 { hexPart += " " }
                }
                lines.append(offsetText(row.offset) + "  " + hexPart + " |" + row.ascii + "|")
            case .xxd:
                var hexPart = ""
                for index in 0..<width {
                    if index < row.bytes.count {
                        hexPart += hex(row.bytes[index])
                    } else {
                        hexPart += "  "
                    }
                    if index % 2 == 1 || index == width - 1 { hexPart += " " }
                }
                lines.append(offsetText(row.offset) + ": " + hexPart + " " + row.ascii)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The bytes in a dump: `hexdump -C`, `xxd`, or hex with or without an
    /// offset column. The ASCII column is ignored. Text that is not hex ends the
    /// bytes on its line, so a line that only holds words contributes nothing.
    static func parse(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        let lines = text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" })
        var sawOffset = false
        for (number, rawLine) in lines.enumerated() {
            var line = String(rawLine)
            if let bar = line.firstIndex(of: "|") { line = String(line[..<bar]) }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "*" || trimmed.isEmpty { continue }

            var body = trimmed
            var hadColon = false
            if let colon = body.firstIndex(of: ":"), body[..<colon].allSatisfy({ $0.isHexDigit }), !body[..<colon].isEmpty {
                hadColon = true
                sawOffset = true
                body = String(body[body.index(after: colon)...])
            }
            if hadColon {
                // xxd: the text column starts after two spaces, once the one after the colon is skipped.
                let rest = body.drop(while: { $0 == " " })
                if let cut = rest.range(of: "  ") { body = String(rest[..<cut.lowerBound]) } else { body = String(rest) }
            }
            var tokens = body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if !hadColon, tokens.count >= 2, tokens[0].count >= 4, tokens[0].allSatisfy({ $0.isHexDigit }),
               tokens.dropFirst().allSatisfy({ $0.count <= 2 || !$0.allSatisfy({ $0.isHexDigit }) }) {
                tokens.removeFirst()
                sawOffset = true
            } else if !hadColon, tokens.count == 1, sawOffset, number == lines.count - 1,
                      tokens[0].count >= 6, tokens[0].allSatisfy({ $0.isHexDigit }) {
                // The closing offset `hexdump -C` prints, with nothing after it.
                tokens.removeAll()
            }
            for token in tokens {
                var digits = token
                if digits.hasPrefix("0x") || digits.hasPrefix("0X") { digits.removeFirst(2) }
                guard !digits.isEmpty, digits.count % 2 == 0, digits.allSatisfy({ $0.isHexDigit }) else { break }
                let chars = Array(digits)
                var index = 0
                while index < chars.count {
                    bytes.append(UInt8(String(chars[index...(index + 1)]), radix: 16) ?? 0)
                    index += 2
                }
            }
        }
        return bytes
    }
}
