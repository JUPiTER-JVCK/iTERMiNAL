import Foundation

/// What text selected in a terminal reads as, so the right-click menu can
/// offer something fitting: open a web address, or reveal, open and copy a file
/// that is really there. Foundation only, so the reading is checked off a Mac;
/// `TerminalSession` supplies the folder and the file check.
///
/// A path is only offered when it names something that exists. A selection is
/// whatever a person dragged across, and a menu that offered to reveal "and/or"
/// in Finder would be offering something that cannot happen.
enum TerminalSelection {
    enum Kind: Equatable {
        /// A web address, as it would be opened.
        case url(String)
        /// A file or folder that exists, as an absolute path.
        case path(String)
        /// Anything else.
        case text
    }

    /// A selection longer than this is not an address or a path.
    static let maxLength = 2_000

    /// - Parameters:
    ///   - directory: Where a relative path is looked up — the terminal's
    ///     folder — or nil when paths mean nothing here, as in a remote session.
    ///   - exists: Whether a path is there. A parameter so the reading can be
    ///     checked without a disk.
    static func classify(
        _ selection: String,
        directory: String?,
        home: String = NSHomeDirectory(),
        exists: (String) -> Bool
    ) -> Kind {
        let text = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf16.count <= maxLength,
              !text.contains("\n"), !text.contains("\r") else { return .text }

        // An address has no spaces in it, and may be wrapped in the punctuation
        // of the sentence it was printed in: "(https://example.com)."
        let framed = trimmingFraming(text)
        if !framed.contains(where: \.isWhitespace), let url = TerminalLinks.webURL(framed) {
            return .url(url.absoluteString)
        }

        guard let directory else { return .text }
        for candidate in pathCandidates(from: text) {
            if let resolved = resolve(candidate, directory: directory, home: home), exists(resolved) {
                return .path(resolved)
            }
        }
        return .text
    }

    // MARK: Reading

    private static let opening: Set<Character> = ["(", "[", "{", "<", "\"", "'", "`"]
    private static let closing: Set<Character> = [")", "]", "}", ">", "\"", "'", "`", ".", ",", ";", ":"]

    /// `text` without the brackets, quotes and sentence punctuation around it.
    private static func trimmingFraming(_ text: String) -> String {
        var characters = Substring(text)
        while let first = characters.first, opening.contains(first) { characters = characters.dropFirst() }
        while let last = characters.last, closing.contains(last) { characters = characters.dropLast() }
        return String(characters)
    }

    /// What a selection might be the name of, most literal first: as selected
    /// and unquoted, without a `:12:3` position after it (a compiler's way of
    /// saying where), and without trailing punctuation.
    private static func pathCandidates(from text: String) -> [String] {
        var found: [String] = []
        func add(_ candidate: String) {
            if !candidate.isEmpty, !found.contains(candidate) { found.append(candidate) }
        }
        var unquoted = Substring(text)
        while let first = unquoted.first, opening.contains(first) { unquoted = unquoted.dropFirst() }
        while let last = unquoted.last, [")", "]", "}", ">", "\"", "'", "`"].contains(last) {
            unquoted = unquoted.dropLast()
        }
        let base = String(unquoted)
        add(base)
        let withoutPosition = removingPosition(from: base)
        add(withoutPosition)
        add(trimmingFraming(withoutPosition))
        return found
    }

    /// `path:12`, `path:12:3` or `path:12:3:` without the position.
    private static func removingPosition(from text: String) -> String {
        guard let range = text.range(of: #":\d+(:\d+)?:?$"#, options: .regularExpression) else { return text }
        return String(text[text.startIndex..<range.lowerBound])
    }

    /// An absolute, tidy path for a candidate — `~` and `~/…` from the home
    /// folder, a relative one from `directory` — or nil when it has anything in
    /// it a terminal would act on.
    private static func resolve(_ candidate: String, directory: String, home: String) -> String? {
        guard !EditorCommand.hasControlCharacter(candidate) else { return nil }
        let path: String
        if candidate == "~" {
            path = home
        } else if candidate.hasPrefix("~/") {
            path = home + "/" + String(candidate.dropFirst(2))
        } else if candidate.hasPrefix("/") {
            path = candidate
        } else {
            path = directory + "/" + candidate
        }
        return tidy(path)
    }

    /// `path` with `.` and `..` and doubled or trailing slashes worked out by
    /// the text alone. Not `standardizingPath`, which asks the disk about
    /// symbolic links: the folder a shell reports is the one it was told to go
    /// to, and this must give the same answer wherever it is run.
    private static func tidy(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".":
                continue
            case "..":
                if !parts.isEmpty { parts.removeLast() }
            default:
                parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }
}
