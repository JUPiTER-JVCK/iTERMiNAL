import Foundation

/// What can be taken out of one response, whatever it is: a page, JSON, a feed,
/// a sitemap, a CSV file.
///
/// Only ever the response in hand. Nothing here makes a request, and a link
/// found in it is a line in a list, not something fetched.
struct ResponseExtraction: Equatable {
    /// "HTML page", "JSON", "RSS feed"…
    var kindLabel: String
    /// A page's lists, for HTML.
    var page: ExtractedPage?
    /// Records laid out as tables: a JSON array of objects, a CSV file, a feed's
    /// entries, a sitemap's pages.
    var tables: [PageTable]
    /// Addresses found in a response that is not a page.
    var links: ResultTable
    /// The query languages that make sense for it.
    var languages: [QueryLanguage]
    /// Why there is little to show, when there is.
    var note: String?
    var byteCount: Int

    var isEmpty: Bool {
        page == nil && tables.isEmpty && links.isEmpty
    }
}

enum ResponseExtractor {
    static func extract(body: Data, contentType: String?, url: String, kind: HTTPContentKind) -> ResponseExtraction {
        let base = URL(string: url) ?? URL(string: "https://invalid.example/")!
        var result = ResponseExtraction(
            kindLabel: "", page: nil, tables: [], links: ResultTable(columns: ["URL", "Type"]),
            languages: [], note: nil, byteCount: body.count
        )
        let mime = (contentType ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        let path = URL(string: url)?.path.lowercased() ?? ""

        switch kind {
        case .html:
            result.kindLabel = "HTML page"
            result.languages = [.css, .xpath, .regex]
            let text = HTTPResponseFormatter.decodedText(body, contentType: contentType)
            result.page = PageExtractor.extract(html: text, pageURL: url)
            return result

        case .json:
            result.languages = [.jsonPath, .regex]
            do {
                let value = try JSONValue.parseDocument(body)
                result.kindLabel = "JSON"
                result.tables = JSONTabulator.tables(in: value).map { PageTable(caption: $0.path, table: $0.table) }
                result.links = linkTable(JSONLinks.addresses(in: value, base: base))
                if result.tables.isEmpty { result.note = "There's no list of records in this JSON to lay out as a table. Use a query to take values out of it." }
            } catch {
                result.kindLabel = "JSON (unreadable)"
                result.note = "This isn't valid JSON: \(error.localizedDescription)"
            }
            return result

        case .xml:
            result.languages = [.css, .xpath, .regex]
            guard let (tree, complete) = XMLTree.parseWithStatus(body) else {
                result.kindLabel = "XML (unreadable)"
                result.languages = [.regex]
                result.note = "This couldn't be read as XML."
                return result
            }
            if !complete { result.note = "This XML has errors, so only the part before the first one could be read." }
            if let feed = FeedParser.parse(tree) {
                result.kindLabel = (feed.title.isEmpty ? "Feed" : "Feed: \(feed.title)") + " — \(feed.items.count) entries"
                result.tables = [PageTable(caption: "Entries", table: FeedParser.table(for: feed, base: base))]
            } else if let sitemap = SitemapTable.table(from: tree) {
                result.kindLabel = "Sitemap — \(sitemap.rows.count) addresses"
                result.tables = [PageTable(caption: "Addresses", table: sitemap)]
            } else {
                result.kindLabel = "XML"
                result.links = linkTable(addressesInText(HTTPResponseFormatter.decodedText(body, contentType: contentType)))
            }
            return result

        case .plainText, .other:
            // CSV and TSV arrive as text, or as their own media type.
            let text = HTTPResponseFormatter.decodedText(body, contentType: contentType)
            let wantsDelimited = mime.contains("csv") || mime.contains("tab-separated") || path.hasSuffix(".csv") || path.hasSuffix(".tsv")
            if let table = delimitedTable(text, forced: wantsDelimited, tab: mime.contains("tab-separated") || path.hasSuffix(".tsv")) {
                result.kindLabel = "Delimited text — \(table.rows.count) rows"
                result.tables = [PageTable(caption: "Rows", table: table)]
                result.languages = [.regex]
                result.links = linkTable(addressesInText(text))
                return result
            }
            if case .other = kind, !looksLikeText(body) {
                break
            }
            result.kindLabel = "Text"
            result.languages = [.regex]
            result.links = linkTable(addressesInText(text))
            if result.links.isEmpty { result.note = "Plain text with no addresses in it. Use a regular expression to pick things out." }
            return result

        case .binary:
            break
        }

        result.kindLabel = mime.isEmpty ? "Binary data" : "Binary data (\(mime))"
        result.note = "There is nothing to take out of this — it isn't text. Use Save to keep the file itself."
        return result
    }

    private static func looksLikeText(_ data: Data) -> Bool {
        let sample = data.prefix(2_000)
        guard !sample.isEmpty else { return true }
        let odd = sample.filter { $0 == 0 || ($0 < 0x09) || ($0 > 0x0D && $0 < 0x20) }.count
        return odd * 100 < sample.count
    }

    private static func delimitedTable(_ text: String, forced: Bool, tab: Bool) -> ResultTable? {
        if forced { return CSVParser.table(from: text, separator: tab ? "\t" : nil) }
        // Not declared as CSV: only when the lines clearly agree on a separator
        // and the text is not something else (markup, JSON).
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first != "<", first != "{", first != "[" else { return nil }
        guard let separator = CSVParser.detectSeparator(in: text, strict: true) else { return nil }
        let lineCount = trimmed.split(separator: "\n").count
        return lineCount >= 3 ? CSVParser.table(from: text, separator: separator) : nil
    }

    // MARK: Addresses

    private static let addressPattern = try! NSRegularExpression(pattern: #"https?://[^\s"'<>\\)\]},]+"#, options: [.caseInsensitive])

    /// Web addresses written out in `text`, once each, in order, without the
    /// punctuation a sentence puts after them.
    static func addressesInText(_ text: String, limit: Int = 5_000) -> [String] {
        let ns = text as NSString
        var seen = Set<String>()
        var out: [String] = []
        addressPattern.enumerateMatches(in: text, range: NSRange(location: 0, length: min(ns.length, 4_000_000))) { match, _, stop in
            guard let match else { return }
            var address = ns.substring(with: match.range)
            while let last = address.last, ".;:!?'\"".contains(last) { address.removeLast() }
            guard URL(string: address)?.host != nil, seen.insert(address).inserted else { return }
            out.append(address)
            if out.count >= limit { stop.pointee = true }
        }
        return out
    }

    private static func linkTable(_ addresses: [String]) -> ResultTable {
        var table = ResultTable(columns: ["URL", "Type"])
        for address in addresses.prefix(PageExtractor.maxRows) {
            let kind = AssetNaming.kind(ofURL: address)
            table.append([address, kind == .other ? "page" : kind.rawValue], url: address, canDownload: kind != .other)
        }
        table.truncated = addresses.count > PageExtractor.maxRows
        return table
    }
}

/// The addresses a JSON document holds.
enum JSONLinks {
    /// Every string that is an `http(s)` address, once each, in the order the
    /// document has them.
    static func addresses(in value: JSONValue, base: URL) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        func walk(_ node: JSONValue, depth: Int) {
            guard depth < 64, out.count < PageExtractor.maxRows else { return }
            switch node {
            case .string(let text):
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://"), !trimmed.contains(where: \.isWhitespace),
                      URL(string: trimmed)?.host != nil, seen.insert(trimmed).inserted else { return }
                out.append(trimmed)
            case .array(let items):
                for item in items { walk(item, depth: depth + 1) }
            case .object(let members):
                for member in members { walk(member.value, depth: depth + 1) }
            default:
                break
            }
        }
        walk(value, depth: 0)
        return out
    }
}
