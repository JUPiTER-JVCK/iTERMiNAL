import Foundation

/// A way of asking a response for something: the languages a scraper is used to.
enum QueryLanguage: String, CaseIterable, Identifiable {
    case css = "CSS"
    case xpath = "XPath"
    case jsonPath = "JSONPath"
    case regex = "Regex"

    var id: String { rawValue }

    var placeholder: String {
        switch self {
        case .css: return "a.title::attr(href)   ·   h2   ·   ul > li:first-child"
        case .xpath: return "//a[@class='title']/@href   ·   //h2/text()"
        case .jsonPath: return "$.data[*].name   ·   $..price   ·   $.items[?(@.stock > 0)]"
        case .regex: return "[\\w.+-]+@[\\w-]+\\.[\\w.]+   ·   (\\d{4})-(\\d{2})-(\\d{2})"
        }
    }

    var summary: String {
        switch self {
        case .css: return "Selectors, as in Scrapy and jQuery. End with ::text, ::html or ::attr(name) to say what to take."
        case .xpath: return "Paths with predicates, as in Scrapy. text() and @attributes give text; elements give what the output says."
        case .jsonPath: return "Paths into the JSON: $.a.b, [0], [*], .. for any depth, [?(@.x > 1)] to filter."
        case .regex: return "A regular expression over the response as text. Each capture group is a column."
        }
    }
}

/// What to take from each element a CSS selector or an XPath finds.
enum QueryOutput: Equatable, Hashable {
    case text
    case html
    case attribute(String)

    var label: String {
        switch self {
        case .text: return "Text"
        case .html: return "HTML"
        case .attribute(let name): return "@\(name)"
        }
    }
}

/// A response, read the ways a query might need it — as HTML, as XML, as JSON,
/// as text — each only when asked, and then kept.
final class QueryDocument {
    let body: Data
    let contentType: String?
    let url: String
    let baseURL: URL

    init(body: Data, contentType: String?, url: String) {
        self.body = body
        self.contentType = contentType
        self.url = url
        baseURL = URL(string: url) ?? URL(string: "https://invalid.example/")!
    }

    lazy var text: String = HTTPResponseFormatter.decodedText(body, contentType: contentType)
    lazy var html: HTMLNode = HTMLParser.parse(text)
    lazy var xml: HTMLNode? = XMLTree.parse(body)
    lazy var json: Result<JSONValue, JSONValue.ParseError> = {
        do { return .success(try JSONValue.parseDocument(body)) } catch let error as JSONValue.ParseError { return .failure(error) } catch {
            return .failure(JSONValue.ParseError(message: error.localizedDescription, position: 0))
        }
    }()

    /// The tree a CSS selector or an XPath should run on: the XML tree for
    /// XML, which keeps `<link>` an ordinary element, and the HTML tree for
    /// everything else.
    var tree: HTMLNode {
        let kind = (contentType ?? "").lowercased()
        if kind.contains("xml"), !kind.contains("html"), let xml { return xml }
        return html
    }
}

struct QueryError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

struct QueryOutcome: Equatable {
    var table: ResultTable
    /// Something worth saying about the run: it was cut short, or found nothing
    /// for a reason a person could act on.
    var note: String?
}

enum QueryRunner {
    /// How many steps a CSS selector may take over a page before the query is
    /// given up. A variable only so the logic check can make it small.
    static var cssStepLimit = CSSSelector.defaultStepLimit

    static let maxRows = 5_000
    /// Cells hold at most this much. The row still says it found more.
    static let maxCell = 20_000
    /// A regular expression is stopped after this long.
    static let regexTimeLimit: TimeInterval = 3

    static func run(
        _ language: QueryLanguage, query rawQuery: String, output: QueryOutput, ignoreCase: Bool = true,
        in document: QueryDocument
    ) throws -> QueryOutcome {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw QueryError(message: "Type a query first.") }
        switch language {
        case .css: return try runCSS(query, output: output, in: document)
        case .xpath: return try runXPath(query, output: output, in: document)
        case .jsonPath: return try runJSONPath(query, in: document)
        case .regex: return try runRegex(query, ignoreCase: ignoreCase, in: document)
        }
    }

    // MARK: CSS and XPath

    /// Splits `a.b::attr(href)` into the selector and what to take.
    static func splitPseudoElement(_ query: String, default fallback: QueryOutput) -> (selector: String, output: QueryOutput) {
        guard let range = query.range(of: "::", options: .backwards) else { return (query, fallback) }
        let selector = String(query[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        let tail = String(query[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        switch tail.lowercased() {
        case "text": return (selector, .text)
        case "html", "outer", "outerhtml": return (selector, .html)
        default:
            if tail.lowercased().hasPrefix("attr("), tail.hasSuffix(")") {
                let name = String(tail.dropFirst(5).dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: " \"'")).lowercased()
                if !name.isEmpty { return (selector, .attribute(name)) }
            }
            return (query, fallback)
        }
    }

    private static func runCSS(_ query: String, output: QueryOutput, in document: QueryDocument) throws -> QueryOutcome {
        let (selectorText, effective) = splitPseudoElement(query, default: output)
        let selector: CSSSelector
        do { selector = try CSSSelector.parse(selectorText, stepLimit: cssStepLimit) } catch { throw QueryError(message: "Selector: \(error.localizedDescription)") }
        let nodes = selector.select(in: document.tree, limit: maxRows + 1)
        if selector.exhausted {
            throw QueryError(message: "That selector takes too long on this page: it is trying every way of choosing the elements between its parts. Use fewer parts, or `>` between them.")
        }
        return nodeTable(nodes.map { XPathValue.node($0) }, output: effective, document: document)
    }

    private static func runXPath(_ query: String, output: QueryOutput, in document: QueryDocument) throws -> QueryOutcome {
        let path: XPath
        do { path = try XPath.parse(query) } catch { throw QueryError(message: "XPath: \(error.localizedDescription)") }
        let found = path.evaluate(from: document.tree, limit: maxRows + 1)
        return nodeTable(found, output: output, document: document)
    }

    /// Attributes whose value is an address, and so is shown in full.
    private static let addressAttributes: Set<String> = ["href", "src", "data-src", "poster", "action", "data", "cite", "srcset", "content"]

    private static func nodeTable(_ found: [XPathValue], output: QueryOutput, document: QueryDocument) -> QueryOutcome {
        var table = ResultTable(columns: ["#", "Result", "Element"])
        for (index, item) in found.prefix(maxRows).enumerated() {
            var value = ""
            var element = ""
            switch item {
            case .text(let text):
                value = text
            case .node(let node):
                element = describe(node)
                switch output {
                case .text: value = node.collapsedText()
                case .html: value = node.outerHTML()
                case .attribute(let name):
                    value = node.attribute(name) ?? ""
                    if addressAttributes.contains(name), name != "content" || value.hasPrefix("http") || value.hasPrefix("/"),
                       let resolved = PageURLs.resolve(value, against: document.baseURL), case .web = resolved.scheme, !resolved.isAnchor {
                        value = resolved.url
                    }
                }
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let cell = String(trimmed.prefix(maxCell))
            var url: String?
            if cell.hasPrefix("http://") || cell.hasPrefix("https://"), !cell.contains(where: \.isWhitespace) { url = cell }
            table.append(["\(index + 1)", cell, element], url: url, canDownload: url != nil && AssetNaming.kind(ofURL: url ?? "") != .other)
        }
        table.truncated = found.count > maxRows
        var note: String?
        if found.isEmpty {
            note = "Nothing matched."
        } else if case .attribute(let name) = output, table.rows.allSatisfy({ $0.cells[1].isEmpty }) {
            note = "It matched \(found.count), but none has a \"\(name)\" attribute."
        }
        return QueryOutcome(table: table, note: note)
    }

    /// `<a.nav#top>`, a short name for an element.
    private static func describe(_ node: HTMLNode) -> String {
        var name = "<" + node.tag
        if let id = node.id { name += "#" + id }
        for className in node.classNames.prefix(2) { name += "." + className }
        return name + ">"
    }

    // MARK: JSONPath

    private static func runJSONPath(_ query: String, in document: QueryDocument) throws -> QueryOutcome {
        let root: JSONValue
        switch document.json {
        case .success(let value): root = value
        case .failure(let error): throw QueryError(message: "This response isn't JSON: \(error.localizedDescription)")
        }
        let path: JSONPath
        do { path = try JSONPath.parse(query) } catch { throw QueryError(message: "JSONPath: \(error.localizedDescription)") }
        let matches = path.evaluate(root, limit: maxRows + 1)
        var table = ResultTable(columns: ["Path", "Value"])
        for match in matches.prefix(maxRows) {
            let text = String(match.value.cellText.prefix(maxCell))
            var url: String?
            if case .string(let string) = match.value, string.hasPrefix("http://") || string.hasPrefix("https://"), !string.contains(where: \.isWhitespace) { url = string }
            table.append([match.path, text], url: url, canDownload: url != nil && AssetNaming.kind(ofURL: url ?? "") != .other)
        }
        table.truncated = matches.count > maxRows
        return QueryOutcome(table: table, note: matches.isEmpty ? "Nothing matched." : nil)
    }

    // MARK: Regex

    private static func runRegex(_ query: String, ignoreCase: Bool, in document: QueryDocument) throws -> QueryOutcome {
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: query, options: ignoreCase ? [.caseInsensitive, .anchorsMatchLines] : [.anchorsMatchLines])
        } catch {
            throw QueryError(message: "Regex: that isn't a valid expression.")
        }
        let text = document.text
        let nsText = text as NSString
        let groups = regex.numberOfCaptureGroups
        var table = ResultTable(columns: ["#", "Match"] + (groups > 0 ? (1...groups).map { "Group \($0)" } : []))
        var count = 0
        var stoppedForTime = false
        let started = Date()
        // `reportProgress` is what lets a pattern that never matches be stopped:
        // without it the block only runs on a match, and a runaway one never gets there.
        regex.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(location: 0, length: nsText.length)) { match, flags, stop in
            if Date().timeIntervalSince(started) > regexTimeLimit {
                stoppedForTime = true
                stop.pointee = true
                return
            }
            guard let match, !flags.contains(.internalError) else { return }
            count += 1
            if count > maxRows {
                stop.pointee = true
                return
            }
            var cells = ["\(count)", String(nsText.substring(with: match.range).prefix(maxCell))]
            if groups > 0 {
                for group in 1...groups {
                    let range = match.range(at: group)
                    cells.append(range.location == NSNotFound ? "" : String(nsText.substring(with: range).prefix(maxCell)))
                }
            }
            let whole = cells[1]
            var url: String?
            if whole.hasPrefix("http://") || whole.hasPrefix("https://"), !whole.contains(where: \.isWhitespace) { url = whole }
            table.append(cells, url: url, canDownload: url != nil && AssetNaming.kind(ofURL: url ?? "") != .other)
        }
        table.truncated = count > maxRows
        var note: String?
        if stoppedForTime {
            note = "Stopped after \(Int(regexTimeLimit)) seconds: the expression is too slow on this response."
        } else if table.rows.isEmpty {
            note = "Nothing matched."
        }
        return QueryOutcome(table: table, note: note)
    }
}
