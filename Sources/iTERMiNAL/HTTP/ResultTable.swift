import Foundation

/// A list of things found on a page, as rows under column headings.
///
/// Links, images, headings, a table from the page, what a selector matched: they
/// are all lists of rows with a few columns, and one shape for them is what lets
/// one view list them, filter them, and hand them to the same exporters.
struct ResultTable: Equatable {
    struct Row: Equatable, Identifiable {
        let id: Int
        var cells: [String]
        /// The address this row is about, when it has one — what Copy and Open
        /// work on. Only ever something the page itself named.
        var url: String?
        /// Whether that address is a file that can be saved. A web page, a
        /// `mailto:` link and an embedded player have an address and no file.
        var canDownload = true
    }

    var columns: [String]
    var rows: [Row]
    /// More was found than is listed.
    var truncated = false

    init(columns: [String], rows: [Row] = [], truncated: Bool = false) {
        self.columns = columns
        self.rows = rows
        self.truncated = truncated
    }

    var isEmpty: Bool { rows.isEmpty }

    /// Adds a row, numbering it. `cells` is padded or cut to the columns.
    mutating func append(_ cells: [String], url: String? = nil, canDownload: Bool = true) {
        var fitted = cells
        if fitted.count < columns.count { fitted += Array(repeating: "", count: columns.count - fitted.count) }
        if fitted.count > columns.count { fitted = Array(fitted.prefix(columns.count)) }
        rows.append(Row(id: rows.count, cells: fitted, url: url, canDownload: canDownload))
    }

    /// Rows with any cell containing `text`, ignoring case. An empty filter is
    /// everything.
    func filtered(by text: String) -> [Row] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return rows }
        return rows.filter { row in
            row.cells.contains { $0.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// The distinct addresses of `rows`, in order.
    static func urls(in rows: [Row]) -> [String] {
        var seen = Set<String>()
        return rows.compactMap(\.url).filter { seen.insert($0).inserted }
    }

    /// The distinct addresses among `rows` that are files, in order.
    static func downloadURLs(in rows: [Row]) -> [String] {
        urls(in: rows.filter(\.canDownload))
    }
}

/// Ways to take a list of rows out of the app.
enum ResultExport {
    enum Format: String, CaseIterable, Identifiable {
        case csv, tsv, json, markdown, urls

        var id: String { rawValue }

        var label: String {
            switch self {
            case .csv: return "CSV"
            case .tsv: return "TSV"
            case .json: return "JSON"
            case .markdown: return "Markdown table"
            case .urls: return "URL list"
            }
        }

        var fileExtension: String {
            switch self {
            case .csv: return "csv"
            case .tsv: return "tsv"
            case .json: return "json"
            case .markdown: return "md"
            case .urls: return "txt"
            }
        }
    }

    static func render(_ rows: [ResultTable.Row], columns: [String], as format: Format) -> String {
        switch format {
        case .csv: return delimited(rows, columns: columns, separator: ",")
        case .tsv: return delimited(rows, columns: columns, separator: "\t")
        case .json: return json(rows, columns: columns)
        case .markdown: return markdown(rows, columns: columns)
        case .urls: return ResultTable.urls(in: rows).joined(separator: "\n") + "\n"
        }
    }

    // MARK: Delimited

    /// RFC 4180: a field with a separator, a quote or a line break is quoted,
    /// quotes doubled, rows ended with CRLF.
    ///
    /// Cells go through `spreadsheetSafe` first. What is in them came from a
    /// web page, and a spreadsheet will run a cell that starts with `=` as a
    /// formula — a page could put `=HYPERLINK(…)` in a link's text and have it
    /// act when someone opens the export.
    static func delimited(_ rows: [ResultTable.Row], columns: [String], separator: Character) -> String {
        func field(_ value: String) -> String {
            let text = spreadsheetSafe(value)
            let needsQuotes = text.contains(separator) || text.contains("\"") || text.contains("\n") || text.contains("\r")
            return needsQuotes ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
        }
        var lines = [columns.map(field).joined(separator: String(separator))]
        for row in rows { lines.append(row.cells.map(field).joined(separator: String(separator))) }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// A leading apostrophe on anything a spreadsheet would take for a formula,
    /// which is what OWASP recommends and what every spreadsheet reads as "this
    /// is text". Plain numbers, which start with `-` or `+` legitimately, are
    /// left alone.
    static func spreadsheetSafe(_ value: String) -> String {
        guard let first = value.unicodeScalars.first else { return value }
        switch first {
        case "=", "@", "\t", "\r":
            return "'" + value
        case "+", "-":
            return isPlainNumber(value) ? value : "'" + value
        default:
            return value
        }
    }

    private static func isPlainNumber(_ value: String) -> Bool {
        value.range(of: #"^[+-]?\d[\d.,]*(?:[eE][+-]?\d+)?$"#, options: .regularExpression) != nil
    }

    // MARK: JSON

    /// An array of objects, keys in column order. Written by hand: building it
    /// with `JSONSerialization` would put the keys in alphabetical order.
    static func json(_ rows: [ResultTable.Row], columns: [String]) -> String {
        guard !rows.isEmpty else { return "[]\n" }
        var out = "[\n"
        for (index, row) in rows.enumerated() {
            let pairs = columns.indices.map { column in
                "\(quoted(columns[column])): \(quoted(column < row.cells.count ? row.cells[column] : ""))"
            }
            out += "  {" + pairs.joined(separator: ", ") + "}" + (index == rows.count - 1 ? "\n" : ",\n")
        }
        return out + "]\n"
    }

    /// `value` as a JSON string literal.
    static func quoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    // MARK: Markdown

    static func markdown(_ rows: [ResultTable.Row], columns: [String]) -> String {
        func cell(_ value: String) -> String {
            value.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
        }
        var lines = ["| " + columns.map(cell).joined(separator: " | ") + " |"]
        lines.append("| " + columns.map { _ in "---" }.joined(separator: " | ") + " |")
        for row in rows { lines.append("| " + row.cells.map(cell).joined(separator: " | ") + " |") }
        return lines.joined(separator: "\n") + "\n"
    }
}
