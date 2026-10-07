import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// What one sitemap file lists: pages, and — for a sitemap *index* — further
/// sitemaps.
struct SitemapContents: Equatable {
    var urls: [String] = []
    var childSitemaps: [String] = []
    /// True when the file held more entries than `SitemapParser.maxEntries`
    /// and the rest were not read.
    var wasCapped = false
}

enum SitemapParser {
    /// A sitemap file may legally hold 50,000 URLs. Reading more than this
    /// from one file is not for this tool's benefit — it is a cap on what a
    /// hostile or broken file can make the app hold.
    static let maxEntries = 50_000

    /// Reads a `<urlset>` or a `<sitemapindex>`. Nil when the data is not XML
    /// at all, or is XML that is neither — HTML served in place of a sitemap
    /// (a soft-404 page) is the common case, and it must not be mistaken for
    /// an empty sitemap.
    ///
    /// SAX rather than a tree: the file can be large and only the `<loc>`
    /// values are wanted. External entities are not resolved.
    static func parse(_ data: Data) -> SitemapContents? {
        let handler = Handler()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = handler
        let completed = parser.parse()
        // A document that stopped at the entry cap is a success, not an error
        // — aborting the parse is how the cap is enforced.
        guard completed || handler.stoppedAtCap else { return nil }
        guard handler.sawRoot else { return nil }
        return handler.contents
    }

    private final class Handler: NSObject, XMLParserDelegate {
        var contents = SitemapContents()
        var sawRoot = false
        var stoppedAtCap = false

        /// Element names from the root down, so a `<loc>` is only believed
        /// where a sitemap puts one: directly inside a `<url>` or a
        /// `<sitemap>`. That excludes `<image:loc>`, `<video:content_loc>`
        /// and the like, which name media, not pages.
        private var stack: [String] = []
        private var text = ""
        private var isIndex = false

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            if stack.isEmpty {
                // Only these two roots are sitemaps. Anything else — an HTML
                // page, an RSS feed — is not one, however well-formed.
                guard elementName == "urlset" || elementName == "sitemapindex" else {
                    parser.abortParsing()
                    return
                }
                sawRoot = true
                isIndex = elementName == "sitemapindex"
            }
            stack.append(elementName)
            if elementName == "loc" { text = "" }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            // Character data arrives in pieces; entity references split it.
            if stack.last == "loc" { text += string }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            defer { if !stack.isEmpty { stack.removeLast() } }
            guard elementName == "loc", stack.count >= 2 else { return }
            let parent = stack[stack.count - 2]
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }

            if isIndex, parent == "sitemap" {
                contents.childSitemaps.append(value)
            } else if !isIndex, parent == "url" {
                contents.urls.append(value)
            }
            if contents.urls.count + contents.childSitemaps.count >= SitemapParser.maxEntries {
                contents.wasCapped = true
                stoppedAtCap = true
                parser.abortParsing()
            }
        }
    }
}
