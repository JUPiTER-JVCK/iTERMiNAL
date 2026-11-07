import Foundation

/// A manual page as the Cheatsheet shows it: read from `man` on this Mac, cleaned of
/// the control characters a terminal would have drawn as bold and underline, and cut
/// down to the parts that tell you how a program is called.
///
/// The manual pages on the Mac are the original, official text for the tools that ship
/// with it, and for the ones installed beside them. Reading them there, rather than
/// bundling a copy, keeps them the pages of the macOS that is actually installed, and
/// means nothing of Apple's is redistributed. Everything here is a pure function of
/// text, so it is checked in CI without a Mac.
enum ManPage {
    // MARK: Which names may be asked for

    /// Whether `name` can be handed to `man` as it is.
    ///
    /// `man` takes a name, a section, or a path to a file, and a name that starts with a
    /// dash is a flag. Only what a program is called is let through: letters, digits and
    /// `. _ + -`, up to 64 of them, not starting with `-` or `.`. A slash is refused
    /// because it would make `man` read a file at that path.
    static func isSafeName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 64 else { return false }
        guard let first = name.unicodeScalars.first, first != "-", first != "." else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (
                (scalar.value >= 0x30 && scalar.value <= 0x39)           // 0-9
                || (scalar.value >= 0x41 && scalar.value <= 0x5A)        // A-Z
                || (scalar.value >= 0x61 && scalar.value <= 0x7A)        // a-z
                || "._+-".unicodeScalars.contains(scalar)
            )
        }
    }

    /// The directories `man` is run with on its `PATH`: the one the app was given, then
    /// the two where Homebrew puts its commands, since `man` finds a command's manual
    /// page from the folders on the path. A GUI app is not given the shell's.
    static func searchPath(base: String?) -> String {
        var folders = (base ?? "").split(separator: ":").map(String.init)
        if folders.isEmpty { folders = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] }
        for extra in ["/opt/homebrew/bin", "/usr/local/bin"] where !folders.contains(extra) {
            folders.append(extra)
        }
        return folders.joined(separator: ":")
    }

    // MARK: Cleaning

    /// `raw` as plain text.
    ///
    /// `man` writes bold as the letter, a backspace, the letter again, and underline as
    /// an underscore, a backspace and the letter — what a printer once did by striking
    /// twice. Each backspace takes back the character before it, which leaves the one
    /// that followed. Escape sequences are dropped, line ends made `\n`, tabs spaces, and
    /// every other control character removed. Trailing spaces go, and runs of blank lines
    /// become one.
    static func clean(_ raw: String) -> String {
        let withoutEscapes = ContextSanitizer.stripANSI(raw)
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(withoutEscapes.unicodeScalars.count)
        var previousWasReturn = false
        for scalar in withoutEscapes.unicodeScalars {
            switch scalar.value {
            case 0x08:
                // Never takes back a line end.
                if let last = scalars.last, last != "\n" { scalars.removeLast() }
                previousWasReturn = false
            case 0x0D:
                scalars.append("\n")
                previousWasReturn = true
            case 0x0A:
                if !previousWasReturn { scalars.append("\n") }
                previousWasReturn = false
            case 0x09:
                scalars.append(contentsOf: "        ".unicodeScalars)
                previousWasReturn = false
            case 0x00...0x1F, 0x7F:
                previousWasReturn = false
            default:
                scalars.append(scalar)
                previousWasReturn = false
            }
        }

        var lines = String(String.UnicodeScalarView(scalars)).components(separatedBy: "\n")
        lines = lines.map { line in
            var trimmed = Substring(line)
            while let last = trimmed.last, last == " " { trimmed = trimmed.dropLast() }
            return String(trimmed)
        }
        var result: [String] = []
        for line in lines {
            if line.isEmpty, result.last?.isEmpty == true { continue }
            result.append(line)
        }
        while result.first?.isEmpty == true { result.removeFirst() }
        while result.last?.isEmpty == true { result.removeLast() }
        return result.joined(separator: "\n")
    }

    // MARK: Sections

    struct Section: Equatable {
        /// "SYNOPSIS", "COMMANDS", "SEE ALSO" …; empty for text with no heading.
        var title: String
        /// The lines under it, without the indent every one of them shares.
        var lines: [String]

        var text: String { lines.joined(separator: "\n") }
    }

    /// Whether `line` heads a section: unindented, in capitals, and not the page's title
    /// or footer line (which have lowercase letters or parentheses in them).
    static func isHeading(_ line: String) -> Bool {
        guard line.count >= 2, line.count <= 60, let first = line.unicodeScalars.first, first != " " else { return false }
        var sawLetter = false
        for scalar in line.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A: sawLetter = true            // A-Z
            case 0x30...0x39, 0x20: continue               // digits, space
            default:
                if "-&/,.'+".unicodeScalars.contains(scalar) { continue }
                return false                                // lowercase, parentheses, anything else
            }
        }
        return sawLetter && !line.hasSuffix(" ")
    }

    /// The sections of already-clean page text, in order. Text before the first heading
    /// is the page's title line and is left out.
    static func sections(_ clean: String) -> [Section] {
        var sections: [Section] = []
        var title: String?
        var body: [String] = []

        func finish() {
            guard let heading = title else { return }
            sections.append(Section(title: heading, lines: dedented(trimmed(body))))
        }

        for line in clean.components(separatedBy: "\n") {
            if isHeading(line) {
                finish()
                title = line
                body = []
            } else if title != nil {
                body.append(line)
            }
        }
        finish()
        return sections
    }

    private static func trimmed(_ lines: [String]) -> [String] {
        var lines = lines
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// `lines` with the indent they all share taken off.
    private static func dedented(_ lines: [String]) -> [String] {
        let indents = lines.filter { !$0.isEmpty }.map { $0.prefix(while: { $0 == " " }).count }
        guard let common = indents.min(), common > 0 else { return lines }
        return lines.map { $0.isEmpty ? $0 : String($0.dropFirst(common)) }
    }

    /// Whether `raw` is a manual page, and not something `man` said instead.
    ///
    /// `man` is not always honest in its exit status — a stripped-down system prints a notice
    /// about missing manual pages and succeeds — so a page is told by what it has: every one
    /// has a NAME, a SYNOPSIS or a DESCRIPTION under a heading of its own, and a message does not.
    static func looksLikePage(_ raw: String) -> Bool {
        let titles = Set(sections(clean(raw)).map(\.title))
        return !titles.isDisjoint(with: ["NAME", "SYNOPSIS", "DESCRIPTION"])
    }

    // MARK: The part worth showing

    struct Excerpt: Equatable {
        var sections: [Section]
        /// Whether something was left out to keep it short.
        var isTruncated: Bool
    }

    /// Where a program's commands and flags are listed, when a page has them under a
    /// heading of their own. Pages for the BSD tools that macOS ships often list their
    /// flags under DESCRIPTION instead, which is what is shown when none of these is there.
    static let referenceHeadings = ["COMMANDS", "SUBCOMMANDS", "OPTIONS", "FLAGS", "USAGE", "ARGUMENTS"]

    /// The synopsis, and the commands and options, of the page `raw` — or its first
    /// lines, when it has no headings to go by — kept to about `limit` characters.
    ///
    /// The synopsis is first because for a tool with subcommands it lists them all
    /// (`ipconfig getifaddr interface-name`, `ipconfig waitall`, …). Nil when `raw`
    /// has nothing in it.
    static func excerpt(fromRaw raw: String, limit: Int = 6_000) -> Excerpt? {
        let text = clean(raw)
        guard !text.isEmpty else { return nil }
        let all = sections(text)

        var chosen: [Section] = []
        if let synopsis = all.first(where: { $0.title == "SYNOPSIS" }) { chosen.append(synopsis) }
        let reference = all.filter { referenceHeadings.contains($0.title) }
        if reference.isEmpty {
            if let description = all.first(where: { $0.title == "DESCRIPTION" }) { chosen.append(description) }
        } else {
            chosen.append(contentsOf: reference)
        }
        if chosen.isEmpty {
            // No headings: the page as it is, from the top.
            chosen = [Section(title: "", lines: text.components(separatedBy: "\n"))]
        }
        return fit(chosen, limit: limit)
    }

    /// `sections` cut to about `limit` characters, at a line, with the rest dropped.
    private static func fit(_ sections: [Section], limit: Int) -> Excerpt {
        var kept: [Section] = []
        var used = 0
        var truncated = false
        for section in sections {
            if used >= limit {
                truncated = true
                break
            }
            used += section.title.count + 1
            var lines: [String] = []
            for line in section.lines {
                if used + line.count + 1 > limit {
                    truncated = true
                    // A page whose first line alone is over the limit still shows that line, cut.
                    if kept.isEmpty && lines.isEmpty { lines.append(String(line.prefix(limit))) }
                    break
                }
                lines.append(line)
                used += line.count + 1
            }
            let body = trimmed(lines)
            // A heading with nothing under it is not worth showing.
            if body.isEmpty && truncated && !kept.isEmpty { break }
            kept.append(Section(title: section.title, lines: body))
            if truncated { break }
        }
        return Excerpt(sections: kept, isTruncated: truncated)
    }
}
