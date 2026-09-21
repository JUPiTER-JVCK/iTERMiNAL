import Foundation

/// Strips terminal control sequences and caps payload size before anything
/// leaves the machine for an assistant endpoint.
enum ContextSanitizer {
    /// Rough upper bound for recent terminal output sent with a prompt.
    static let recentOutputLimit = 6_000

    /// Removes CSI / OSC / other ESC sequences so the model sees plain text.
    static func stripANSI(_ text: String) -> String {
        // ESC … [ … letter  |  ESC ] … BEL/ST  |  lone ESC + one more byte
        //
        // `\x{…}`, not `\u{…}`. This is a raw string, so Swift hands the
        // escape to ICU untouched, and ICU's brace form is `\x{hhhh}` — it
        // reads `\u` as requiring exactly four bare hex digits. The `\u{001B}`
        // spelling made the pattern fail to compile, `try?` gave nil, and the
        // guard below returned the text unsanitised: every escape sequence,
        // OSC title and cwd report on screen went to the endpoint verbatim,
        // silently, on every platform.
        let pattern = #"\x{001B}\[[0-9;?]*[ -/]*[@-~]|\x{001B}\][^\x{0007}\x{001B}]*(?:\x{0007}|\x{001B}\\)|\x{001B}."#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            // Unreachable with a literal pattern, but a silent pass-through is
            // the one outcome this type exists to prevent: send nothing rather
            // than send raw screen contents.
            assertionFailure("ContextSanitizer pattern failed to compile")
            return ""
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    /// Strip ANSI, then keep the trailing `limit` characters (recent output).
    static func sanitizeRecentOutput(_ text: String, limit: Int = recentOutputLimit) -> String {
        let plain = stripANSI(text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard plain.count > limit else { return plain }
        let start = plain.index(plain.endIndex, offsetBy: -limit)
        return "\u{2026}" + String(plain[start...])
    }
}
