import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// XML read into the same tree HTML is, so a CSS selector or an XPath works on
/// a feed, a sitemap or any other XML the way it does on a page.
///
/// Names are lower-cased and namespace prefixes are kept as part of the name
/// (`dc:creator` is a tag called "dc:creator"; in a selector, write
/// `dc\:creator`). External entities are never resolved, so a document cannot
/// make this read a file or call out to a server.
enum XMLTree {
    static let maxNodes = 500_000
    /// How deep elements may nest before the rest of the document is left unread.
    /// Nothing real is more than a dozen levels down, and everything that walks the
    /// tree does it with a call for each level, on a thread with half a megabyte
    /// of stack — a server can send a hundred thousand.
    static let maxDepth = 256
    /// The most attributes one element may have. Real documents have a handful; XML
    /// parsers check a tag's attributes against each other, so a hundred thousand
    /// in one tag held a thread for seventeen seconds, and a million would for
    /// hours. Ten thousand take a fifth of a second.
    static let maxAttributes = 10_000

    /// Whether any tag in `data` has more attributes than `maxAttributes`, counted
    /// as the `=` signs inside it. Read before the parser is, because it is the
    /// parser that takes the time.
    static func hasTagWithTooManyAttributes(_ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            var inTag = false
            var equals = 0
            for byte in bytes {
                switch byte {
                case UInt8(ascii: "<"):
                    inTag = true
                    equals = 0
                case UInt8(ascii: ">"):
                    inTag = false
                case UInt8(ascii: "="):
                    if inTag {
                        equals += 1
                        if equals > maxAttributes { return true }
                    }
                default:
                    break
                }
            }
            return false
        }
    }

    static func parse(_ data: Data) -> HTMLNode? {
        parseWithStatus(data)?.tree
    }

    /// The tree, and whether the whole document was read. A feed with one bad
    /// character in it is still a feed: what was read before the error is
    /// kept, and `complete` says the rest was not.
    static func parseWithStatus(_ data: Data) -> (tree: HTMLNode, complete: Bool)? {
        guard !hasTagWithTooManyAttributes(data) else { return nil }
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = builder
        let completed = parser.parse()
        guard builder.sawElement else { return nil }
        return (builder.root, completed && !builder.stoppedAtCap)
    }

    private final class Builder: NSObject, XMLParserDelegate {
        let root = HTMLNode(kind: .document)
        private var stack: [HTMLNode] = []
        private var count = 0
        private(set) var sawElement = false
        private(set) var stoppedAtCap = false

        private var current: HTMLNode { stack.last ?? root }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
        ) {
            count += 1
            if count > XMLTree.maxNodes || stack.count >= XMLTree.maxDepth {
                stoppedAtCap = true
                parser.abortParsing()
                return
            }
            sawElement = true
            // Sorted, so the same document always gives the same tree.
            let attributes = attributeDict.keys.sorted().map { HTMLAttribute(name: $0.lowercased(), value: attributeDict[$0] ?? "") }
            let node = HTMLNode(kind: .element, tag: elementName.lowercased(), attributes: attributes)
            node.parent = current
            current.children.append(node)
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            append(string)
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            append(String(decoding: CDATABlock, as: UTF8.self))
        }

        private func append(_ text: String) {
            guard !stack.isEmpty else { return }
            if let last = current.children.last, last.kind == .text {
                last.text += text
            } else {
                let node = HTMLNode(kind: .text, text: text)
                node.parent = current
                current.children.append(node)
            }
        }
    }
}

/// What an RSS, Atom or RDF feed says.
struct FeedDocument: Equatable {
    struct Item: Equatable {
        var title = ""
        var link = ""
        var date = ""
        var author = ""
        var summary = ""
        var enclosureURL = ""
        var enclosureType = ""
    }

    var title = ""
    var link = ""
    var items: [Item] = []
}

enum FeedParser {
    static let maxItems = 5_000

    /// Nil unless the document is a feed.
    static func parse(_ root: HTMLNode) -> FeedDocument? {
        guard let top = root.children.first(where: { $0.kind == .element }) else { return nil }
        var feed = FeedDocument()

        func firstChild(_ node: HTMLNode, _ tag: String) -> HTMLNode? {
            node.children.first { $0.kind == .element && $0.tag == tag }
        }
        func text(_ node: HTMLNode?, _ tag: String) -> String {
            guard let node, let child = firstChild(node, tag) else { return "" }
            return HTMLNode.collapseWhitespace(child.rawText())
        }

        switch top.tag {
        case "rss", "rdf:rdf":
            let channel = firstChild(top, "channel") ?? top
            feed.title = text(channel, "title")
            feed.link = text(channel, "link")
            // RSS 1.0 puts items beside the channel, RSS 2.0 inside it.
            let holder = top.tag == "rss" ? channel : top
            for item in holder.children where item.kind == .element && item.tag == "item" && feed.items.count < maxItems {
                var entry = FeedDocument.Item()
                entry.title = text(item, "title")
                entry.link = text(item, "link")
                if entry.link.isEmpty, let guid = firstChild(item, "guid"), guid.attribute("ispermalink") != "false" {
                    entry.link = HTMLNode.collapseWhitespace(guid.rawText())
                }
                entry.date = [text(item, "pubdate"), text(item, "dc:date")].first { !$0.isEmpty } ?? ""
                entry.author = [text(item, "dc:creator"), text(item, "author")].first { !$0.isEmpty } ?? ""
                entry.summary = String(HTMLNode.collapseWhitespace(HTMLParser.parse(text(item, "description")).rawText()).prefix(300))
                if let enclosure = firstChild(item, "enclosure") {
                    entry.enclosureURL = enclosure.attribute("url") ?? ""
                    entry.enclosureType = enclosure.attribute("type") ?? ""
                }
                feed.items.append(entry)
            }
        case "feed":
            feed.title = text(top, "title")
            feed.link = atomLink(top)
            for item in top.children where item.kind == .element && item.tag == "entry" && feed.items.count < maxItems {
                var entry = FeedDocument.Item()
                entry.title = text(item, "title")
                entry.link = atomLink(item)
                entry.date = [text(item, "updated"), text(item, "published")].first { !$0.isEmpty } ?? ""
                entry.author = text(firstChild(item, "author"), "name")
                let summary = text(item, "summary").isEmpty ? text(item, "content") : text(item, "summary")
                entry.summary = String(HTMLNode.collapseWhitespace(HTMLParser.parse(summary).rawText()).prefix(300))
                if let enclosure = item.children.first(where: { $0.kind == .element && $0.tag == "link" && $0.attribute("rel") == "enclosure" }) {
                    entry.enclosureURL = enclosure.attribute("href") ?? ""
                    entry.enclosureType = enclosure.attribute("type") ?? ""
                }
                feed.items.append(entry)
            }
        default:
            return nil
        }
        return feed
    }

    /// The `alternate` link, or the first that is not for editing or `self`.
    private static func atomLink(_ node: HTMLNode) -> String {
        let links = node.children.filter { $0.kind == .element && $0.tag == "link" }
        let preferred = links.first { ($0.attribute("rel") ?? "alternate") == "alternate" } ?? links.first
        return preferred?.attribute("href") ?? ""
    }

    /// A feed as a table: one row per entry, the entry's page as its address.
    static func table(for feed: FeedDocument, base: URL) -> ResultTable {
        var table = ResultTable(columns: ["Title", "Link", "Date", "Author", "Summary", "Attachment"], truncated: feed.items.count >= maxItems)
        for item in feed.items {
            let link = PageURLs.resolve(item.link, against: base).flatMap { resolved -> String? in
                if case .web = resolved.scheme { return resolved.url }
                return nil
            }
            let attachment = PageURLs.resolve(item.enclosureURL, against: base).flatMap { resolved -> String? in
                if case .web = resolved.scheme { return resolved.url }
                return nil
            }
            table.append(
                [item.title, link ?? item.link, item.date, item.author, item.summary, attachment ?? ""],
                url: attachment ?? link,
                canDownload: attachment != nil
            )
        }
        return table
    }
}

/// `<urlset>` as a table, with what the sitemap says about each page. The
/// explorer's `SitemapParser` keeps only the addresses; a person looking at one
/// wants the dates too.
enum SitemapTable {
    static func table(from root: HTMLNode) -> ResultTable? {
        guard let top = root.children.first(where: { $0.kind == .element }), top.tag == "urlset" || top.tag == "sitemapindex" else { return nil }
        let childTag = top.tag == "urlset" ? "url" : "sitemap"
        var table = ResultTable(columns: ["URL", "Last modified", "Change", "Priority"])
        for entry in top.children where entry.kind == .element && entry.tag == childTag {
            func value(_ tag: String) -> String {
                guard let child = entry.children.first(where: { $0.kind == .element && $0.tag == tag }) else { return "" }
                return HTMLNode.collapseWhitespace(child.rawText())
            }
            let loc = value("loc")
            guard !loc.isEmpty else { continue }
            if table.rows.count >= CSVParser.maxRows { table.truncated = true; break }
            table.append([loc, value("lastmod"), value("changefreq"), value("priority")], url: loc, canDownload: false)
        }
        return table
    }
}
