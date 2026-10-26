import Foundation

/// Delimited text — CSV, TSV, and the semicolon- and pipe-separated cousins —
/// read into a table.
///
/// RFC 4180's rules: a field may be quoted, a quoted field may hold the
/// separator, line breaks and doubled quotes, and rows end at CRLF or LF.
/// Real files are looser than that, so rows of different lengths are padded
/// instead of refused and a stray quote is kept as text.
enum CSVParser {
    static let maxRows = 5_000
    static let maxColumns = 100

    /// The separator that best explains the first lines: the one that appears
    /// the same number of times (more than zero) on them. A file declared to be
    /// CSV may have the odd short row, so by default three lines in four have to
    /// agree; text that only *looks* delimited has to agree on every line, or
    /// ordinary prose with commas in it would turn into a table.
    static func detectSeparator(in text: String, strict: Bool = false) -> Character? {
        let lines = text.split(separator: "\n", maxSplits: 12, omittingEmptySubsequences: true).prefix(10).map(String.init)
        guard lines.count >= 2 else { return nil }
        var best: (separator: Character, count: Int)?
        for candidate in [",", ";", "\t", "|"] as [Character] {
            // Counted outside quotes.
            let counts = lines.map { line -> Int in
                var inQuotes = false
                var count = 0
                for character in line {
                    if character == "\"" { inQuotes.toggle() } else if character == candidate, !inQuotes { count += 1 }
                }
                return count
            }
            // The most common non-zero count, and how many lines have it.
            let tally = Dictionary(grouping: counts.filter { $0 > 0 }, by: { $0 })
            guard let (count, matching) = tally.max(by: { $0.value.count < $1.value.count || ($0.value.count == $1.value.count && $0.key < $1.key) }) else { continue }
            let agreeing = matching.count
            let needed = strict ? lines.count : Int((Double(lines.count) * 0.75).rounded(.up))
            guard agreeing >= needed else { continue }
            if best == nil || count > best!.count { best = (candidate, count) }
        }
        return best?.separator
    }

    /// Rows of fields.
    static func parse(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var fieldStarted = false
        let characters = Array(text.unicodeScalars)
        let sep = separator.unicodeScalars.first!
        var i = 0
        if characters.first == "\u{FEFF}" { i = 1 }

        func endField() {
            row.append(field)
            field = ""
            fieldStarted = false
        }
        func endRow() {
            endField()
            // A blank line is not a row of one empty field.
            if !(row.count == 1 && row[0].isEmpty) { rows.append(Array(row.prefix(maxColumns))) }
            row = []
        }

        while i < characters.count, rows.count < maxRows + 1 {
            let scalar = characters[i]
            if inQuotes {
                if scalar == "\"" {
                    if i + 1 < characters.count, characters[i + 1] == "\"" {
                        field.unicodeScalars.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.unicodeScalars.append(scalar)
                }
            } else if scalar == "\"", !fieldStarted {
                inQuotes = true
                fieldStarted = true
            } else if scalar == sep {
                endField()
            } else if scalar == "\n" {
                endRow()
            } else if scalar == "\r" {
                if i + 1 < characters.count, characters[i + 1] == "\n" { i += 1 }
                endRow()
            } else {
                field.unicodeScalars.append(scalar)
                fieldStarted = true
            }
            i += 1
        }
        if !field.isEmpty || fieldStarted || !row.isEmpty { endRow() }
        return rows
    }

    /// The text as a table, first row as the headings.
    static func table(from text: String, separator: Character? = nil) -> ResultTable? {
        guard let separator = separator ?? detectSeparator(in: text) else { return nil }
        var rows = parse(text, separator: separator)
        guard rows.count >= 2 else { return nil }
        let truncated = rows.count > maxRows + 1
        if truncated { rows = Array(rows.prefix(maxRows + 1)) }
        let width = rows.map(\.count).max() ?? 0
        guard width >= 2 else { return nil }
        let header = rows[0].enumerated().map { $0.element.isEmpty ? "Column \($0.offset + 1)" : $0.element }
            + (rows[0].count < width ? (rows[0].count..<width).map { "Column \($0 + 1)" } : [])
        var table = ResultTable(columns: header, truncated: truncated)
        for row in rows.dropFirst() {
            let url = row.first { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
            table.append(row, url: url, canDownload: url != nil && AssetNaming.kind(ofURL: url ?? "") != .other)
        }
        return table
    }
}
