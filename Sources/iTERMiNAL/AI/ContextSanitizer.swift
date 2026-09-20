import Foundation

/// Strips terminal control sequences and caps payload size before anything
/// leaves the machine for an assistant endpoint.
enum ContextSanitizer {
    /// Rough upper bound for recent terminal output sent with a prompt.
    static let recentOutputLimit = 6_000

    /// Removes CSI / OSC / other ESC sequences so the model sees plain text.
    static func stripANSI(_ text: String) -> String {
        // ESC … [ … letter  |  ESC ] … BEL/ST  |  lone ESC + one more byte
        let pattern = #"\u{001B}\[[0-9;?]*[ -/]*[@-~]|\u{001B}\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\)|\u{001B}."#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
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
