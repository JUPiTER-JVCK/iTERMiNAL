import Foundation

/// What a terminal does with something dropped on it, and what may reach the
/// shell from it. Foundation only, so those rules are checked off a Mac;
/// `InstrumentedTerminalView` reads the pasteboard and sends the result.
///
/// A drop is typed the way a paste is, never run: nothing here ends a line
/// with Return, and anything a terminal would act on rather than show is
/// removed first.
enum TerminalDrop {
    /// What a particular terminal takes.
    enum Policy: Equatable {
        /// A bundled tool draws its own screen, so nothing is typed into it.
        case nothing
        /// A remote session: text means the same there, but a path on this
        /// Mac does not.
        case textOnly
        case filesAndText
    }

    /// The most files typed from one drop, and the most text, in bytes. A
    /// folder of thousands of files, or a whole log, would otherwise be typed
    /// into a prompt in one go.
    static let maxPaths = 100
    static let maxTextBytes = 64 * 1024

    /// Bracketed paste's start and end markers (`ESC [ 200 ~`, `ESC [ 201 ~`).
    static let pasteStart: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
    static let pasteEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]

    /// The paths as words for a command line: each one quoted, separated by
    /// spaces, with a space after the last so the next word can be typed
    /// straight away. nil when there is nothing to type or any path cannot be
    /// typed safely — the whole drop is refused rather than part of it.
    ///
    /// A path must be absolute, so it cannot start with a dash and be read as
    /// an option, and free of control characters: a newline in a file name
    /// would end the line early and run what follows.
    static func typedPaths(_ paths: [String]) -> String? {
        guard !paths.isEmpty, paths.count <= maxPaths else { return nil }
        var words: [String] = []
        for path in paths {
            guard path.hasPrefix("/"), !EditorCommand.hasControlCharacter(path) else { return nil }
            words.append(EditorCommand.quote(path))
        }
        return words.joined(separator: " ") + " "
    }

    /// The bytes to send for dropped text, or nil to refuse it.
    ///
    /// - Control characters other than Tab and line breaks are removed. An
    ///   Escape in the text could otherwise end a bracketed paste early with
    ///   its own `ESC [ 201 ~` and let what follows be read as typed.
    /// - Line breaks become Return, as a terminal's own paste makes them.
    /// - With bracketed paste on, the shell is told it is a paste and keeps
    ///   the lines apart. With it off, each line would run as it arrived, so
    ///   a trailing line break is dropped and any other is refused.
    /// - Text that is only a UUID is refused: the sidebar drags a tab as its
    ///   id, and letting go of one over a terminal would type it.
    static func textPayload(_ text: String, bracketedPasteMode: Bool) -> [UInt8]? {
        var cleaned = sanitized(text)
        if !bracketedPasteMode {
            while cleaned.hasSuffix("\r") { cleaned.removeLast() }
            if cleaned.contains("\r") { return nil }
        }
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, UUID(uuidString: trimmed) == nil else { return nil }
        let body = Array(cleaned.utf8)
        guard body.count <= maxTextBytes else { return nil }
        return bracketedPasteMode ? pasteStart + body + pasteEnd : body
    }

    /// `text` with every control character removed except Tab, and each kind
    /// of line break (CR, LF, CRLF) made a single CR.
    static func sanitized(_ text: String) -> String {
        // Spelled with a `UInt8` so it is the initialiser that cannot fail; a
        // bare integer literal could pick one of the failable ones.
        let carriageReturn = Unicode.Scalar(UInt8(0x0D))
        var out = String.UnicodeScalarView()
        var previousWasCarriageReturn = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0D:
                out.append(carriageReturn)
                previousWasCarriageReturn = true
                continue
            case 0x0A:
                // The LF of a CRLF has already been written as a CR.
                if !previousWasCarriageReturn { out.append(carriageReturn) }
            case 0x09:
                out.append(scalar)
            case 0x00..<0x20, 0x7F, 0x80..<0xA0:
                break
            default:
                out.append(scalar)
            }
            previousWasCarriageReturn = false
        }
        return String(out)
    }
}
