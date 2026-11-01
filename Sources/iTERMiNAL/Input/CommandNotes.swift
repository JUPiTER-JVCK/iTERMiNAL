import Foundation

/// Short, plain notes about a command line typed in the composer, shown before
/// Return is pressed. Foundation only, so what they say and when they stay
/// quiet is checked off a Mac.
///
/// Advice, not a gate: nothing here stops a command, and no note does not mean
/// safe. It reads the text for the dangers `CommandRisk` knows, and for a quote
/// or bracket left open, which makes the shell wait for more rather than run.
enum CommandNotes {
    /// Past this many characters the line is a paste, not a command being
    /// typed, and is left alone.
    static let maxLength = 2_000

    /// Open-quote and open-bracket notes first, since they decide whether the
    /// line runs at all; then the dangers in it.
    static func notes(for line: String) -> [String] {
        guard !line.isEmpty, line.utf16.count <= maxLength else { return [] }
        var found = syntaxNotes(for: line)
        for warning in CommandRisk.warnings(for: line) where !found.contains(warning) {
            found.append(warning)
        }
        return found
    }

    static func syntaxNotes(for line: String) -> [String] {
        let scanned = AutoPairing.scan(line)
        var found: [String] = []
        switch scanned.state {
        case .single, .double, .backtick:
            found.append("A quote is still open, so the shell will wait for the rest instead of running this.")
        case .none, .comment:
            break
        }
        // A bracket inside a quote does not count, so only look when no quote
        // is left open: the note above already says the line is unfinished.
        // Said as what was found and no more: whether an open bracket makes a
        // shell wait or refuse depends on the shell and on which bracket.
        if scanned.state == .none, !scanned.open.isEmpty {
            found.append("A bracket is still open.")
        }
        if scanned.endsWithBackslash {
            found.append("Ends with a backslash, so the shell will wait for the next line.")
        }
        return found
    }
}
