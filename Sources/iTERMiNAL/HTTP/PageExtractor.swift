import Foundation

/// A table that was on the page.
struct PageTable: Equatable {
    var caption: String?
    var table: ResultTable
}

/// What a page says about itself and points to, sorted into lists.
///
/// Everything here was *declared* by the page: an address is in the list
/// because the markup contains it. Nothing is guessed from a naming convention,
/// requested to see what comes back, or followed to find more — the lists are
/// what the one page, already fetched, holds.
struct ExtractedPage: Equatable {
    var pageURL: String
    var baseURL: String
    var title: String?
    var summary: String?
    var language: String?
    var canonicalURL: String?
    var siteName: String?
    var author: String?
    var published: String?
    var previewImage: String?
    var charset: String?

    var links: ResultTable
    var images: ResultTable
    var media: ResultTable
    var files: ResultTable
    var headings: ResultTable
    var tables: [PageTable]
    var meta: ResultTable
    var structured: ResultTable
    var structuredJSON: [String]
    var resources: ResultTable
    var forms: ResultTable
    var feeds: ResultTable

    /// The reading part of the page.
    var text: String
    var markdown: String
    /// Where the reading came from: "article", "main", "div", "body"…
    var textSource: String

    var elementCount: Int
    /// Links to a place further down the same page — counted, not listed.
    var anchorCount: Int
    /// Images written into the markup as `data:` addresses — counted, not listed.
    var inlineDataCount: Int
}

enum PageExtractor {
    /// Rows beyond this are not kept; the list says it was cut.
    static let maxRows = 5_000
    static let maxCell = 300
    static let maxTables = 100
    static let maxTableRows = 2_000

    static func extract(html: String, pageURL: String) -> ExtractedPage {
        extract(document: HTMLParser.parse(html), pageURL: pageURL)
    }

    static func extract(document: HTMLNode, pageURL: String) -> ExtractedPage {
        let pageBase = URL(string: pageURL) ?? URL(string: "https://invalid.example/")!
        let elements = document.descendantElements()

        // A <base href> changes what every relative address means.
        var base = pageBase
        if let element = elements.first(where: { $0.tag == "base" && $0.attribute("href") != nil }),
           let resolved = PageURLs.resolve(element.attribute("href") ?? "", against: pageBase),
           case .web = resolved.scheme, let url = URL(string: resolved.url) {
            base = url
        }

        var collector = Collector(pageURL: pageBase, base: base)
        for node in elements { collector.visit(node) }
        collector.visitStructuredData(elements)

        let reading = ReadableText.extract(from: document, baseURL: base)
        return collector.page(elementCount: elements.count, reading: reading)
    }

    // MARK: Collecting

    /// A table of rows with an address each, where a repeated address is one
    /// row that remembers how often it came up, instead of many.
    private struct Unique {
        var table: ResultTable
        private var index: [String: Int] = [:]
        private let limit: Int

        init(_ columns: [String], limit: Int = PageExtractor.maxRows) {
            table = ResultTable(columns: columns)
            self.limit = limit
        }

        /// Adds a row for `key`, or lets `merge` fold the new cells into the one
        /// already there.
        mutating func add(
            key: String, cells: [String], url: String?, canDownload: Bool = true,
            merge: (inout [String], [String]) -> Void = { _, _ in }
        ) {
            if let existing = index[key] {
                merge(&table.rows[existing].cells, cells)
                return
            }
            guard table.rows.count < limit else {
                table.truncated = true
                return
            }
            index[key] = table.rows.count
            table.append(cells.map { String($0.prefix(PageExtractor.maxCell)) }, url: url, canDownload: canDownload)
        }
    }

    private struct Collector {
        let pageURL: URL
        let base: URL

        var links = Unique(["Text", "URL", "Site", "Rel", "×"])
        var images = Unique(["URL", "Alt", "Size", "Where"])
        var media = Unique(["URL", "Kind", "Type", "Watch page"])
        var files = Unique(["Name", "URL", "Type", "Link text"])
        var resources = Unique(["URL", "Kind", "Details"])
        var feeds = Unique(["Title", "URL", "Type"])
        var headings = ResultTable(columns: ["Level", "Heading", "ID"])
        var forms = ResultTable(columns: ["Method", "Action", "Fields"])
        var meta = ResultTable(columns: ["Group", "Name", "Value"])
        var structured = ResultTable(columns: ["Type", "Name", "URL", "From"])
        var structuredJSON: [String] = []
        var tables: [PageTable] = []

        var title: String?
        var language: String?
        var canonical: String?
        var charset: String?
        var anchorCount = 0
        var inlineDataCount = 0
        var metaValues: [String: String] = [:]

        init(pageURL: URL, base: URL) {
            self.pageURL = pageURL
            self.base = base
        }

        // MARK: Visiting

        mutating func visit(_ node: HTMLNode) {
            switch node.tag {
            case "html": language = node.attribute("lang").flatMap(nonEmpty)
            case "title": if title == nil { title = nonEmpty(node.collapsedText()) }
            case "a", "area": anchor(node)
            case "img": image(node)
            case "source": source(node)
            case "video": video(node)
            case "audio": if let src = node.attribute("src") { addMedia(src, kind: "audio", type: node.attribute("type") ?? "", place: "audio") }
            case "track": track(node)
            case "iframe": if let src = node.attribute("src") { embed(src, kind: "embed", type: "iframe", title: node.attribute("title")) }
            case "embed": if let src = node.attribute("src") { embed(src, kind: "embed", type: node.attribute("type") ?? "embed", title: nil) }
            case "object": if let data = node.attribute("data") { embed(data, kind: "object", type: node.attribute("type") ?? "object", title: nil) }
            case "input":
                if node.attribute("type")?.lowercased() == "image", let src = node.attribute("src") {
                    addImage(src, alt: node.attribute("alt"), size: dimensions(node), place: "input")
                }
            case "link": link(node)
            case "meta": metaTag(node)
            case "script": script(node)
            case "h1", "h2", "h3", "h4", "h5", "h6": heading(node)
            case "form": form(node)
            case "table": table(node)
            default: break
            }
            // A `background-image: url(…)` is as much a picture as an <img>.
            if let style = node.attribute("style") {
                for address in PageURLs.cssURLs(in: style) { addImage(address, alt: nil, size: "", place: "style") }
            }
        }

        private func nonEmpty(_ value: String) -> String? {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        // MARK: Links, files

        private func linkText(_ node: HTMLNode) -> String {
            var text = node.collapsedText()
            if text.isEmpty { text = node.attribute("aria-label") ?? node.attribute("title") ?? "" }
            if text.isEmpty, let image = node.descendantElements().first(where: { $0.tag == "img" }) { text = image.attribute("alt") ?? "" }
            return HTMLNode.collapseWhitespace(text)
        }

        private mutating func anchor(_ node: HTMLNode) {
            guard let href = node.attribute("href"), let resolved = PageURLs.resolve(href, against: base) else { return }
            if resolved.isAnchor {
                anchorCount += 1
                return
            }
            let text = linkText(node)
            let rel = node.attribute("rel") ?? ""

            switch resolved.scheme {
            case .web:
                let kind = AssetNaming.kind(ofURL: resolved.url)
                let site = PageURLs.isSameSite(resolved.url, as: pageURL) ? "same site" : "external"
                let isFile = node.hasAttribute("download") || kind == .document || kind == .archive
                addLink(text: text, url: resolved.url, site: site, rel: rel, canDownload: isFile || kind == .image || kind == .video || kind == .audio)
                switch kind {
                case .image:
                    addImage(resolved.url, alt: text, size: "", place: "link")
                case .video, .audio:
                    addMedia(resolved.url, kind: kind.rawValue, type: "", place: "link")
                default:
                    if isFile { addFile(url: resolved.url, text: text) }
                }
            case .mailto:
                addLink(text: text, url: resolved.url, site: "email", rel: rel, canDownload: false)
            case .tel:
                addLink(text: text, url: resolved.url, site: "phone", rel: rel, canDownload: false)
            case .other(let scheme):
                addLink(text: text, url: resolved.url, site: scheme, rel: rel, canDownload: false)
            }
        }

        private mutating func addLink(text: String, url: String, site: String, rel: String, canDownload: Bool) {
            links.add(key: url, cells: [text, url, site, rel, "1"], url: url, canDownload: canDownload) { existing, _ in
                if existing[0].isEmpty { existing[0] = text }
                existing[4] = String((Int(existing[4]) ?? 1) + 1)
            }
        }

        private mutating func addFile(url: String, text: String) {
            let ext = AssetNaming.pathExtension(ofURL: url)
            let name = AssetNaming.fileName(for: url)
            files.add(key: url, cells: [name, url, ext.isEmpty ? "file" : ext.uppercased(), text], url: url)
        }

        // MARK: Images

        private func dimensions(_ node: HTMLNode) -> String {
            let width = node.attribute("width").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            let height = node.attribute("height").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            switch (width, height) {
            case let (w?, h?): return "\(w)×\(h)"
            case let (w?, nil): return "\(w) wide"
            case let (nil, h?): return "\(h) high"
            default: return ""
            }
        }

        private mutating func addImage(_ raw: String, alt: String?, size: String, place: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("data:") {
                inlineDataCount += 1
                return
            }
            guard let resolved = PageURLs.resolve(trimmed, against: base), case .web = resolved.scheme, !resolved.isAnchor else { return }
            let cleanAlt = alt.map(HTMLNode.collapseWhitespace) ?? ""
            images.add(key: resolved.url, cells: [resolved.url, cleanAlt, size, place], url: resolved.url) { existing, _ in
                if existing[1].isEmpty { existing[1] = cleanAlt }
                if existing[2].isEmpty { existing[2] = size }
            }
        }

        private mutating func image(_ node: HTMLNode) {
            let alt = node.attribute("alt")
            let size = dimensions(node)
            if let src = node.attribute("src") { addImage(src, alt: alt, size: size, place: "img") }
            for name in ["data-src", "data-lazy-src", "data-original", "data-lazy", "data-image"] {
                if let value = node.attribute(name) { addImage(value, alt: alt, size: size, place: "lazy") }
            }
            for name in ["srcset", "data-srcset"] {
                guard let value = node.attribute(name) else { continue }
                for candidate in PageURLs.parseSrcset(value) {
                    addImage(candidate.url, alt: alt, size: candidate.descriptor ?? size, place: "srcset")
                }
            }
        }

        // MARK: Media

        private mutating func source(_ node: HTMLNode) {
            let parent = node.parent?.tag ?? ""
            switch parent {
            case "picture":
                if let value = node.attribute("srcset") {
                    for candidate in PageURLs.parseSrcset(value) {
                        addImage(candidate.url, alt: nil, size: candidate.descriptor ?? "", place: "picture")
                    }
                }
            case "video", "audio":
                if let src = node.attribute("src") { addMedia(src, kind: parent, type: node.attribute("type") ?? "", place: "source") }
            default:
                break
            }
        }

        private mutating func video(_ node: HTMLNode) {
            if let src = node.attribute("src") { addMedia(src, kind: "video", type: node.attribute("type") ?? "", place: "video") }
            if let poster = node.attribute("poster") { addImage(poster, alt: nil, size: "", place: "poster") }
        }

        private mutating func track(_ node: HTMLNode) {
            guard let src = node.attribute("src") else { return }
            let kind = node.attribute("kind") ?? "subtitles"
            addMedia(src, kind: "captions", type: [kind, node.attribute("srclang") ?? ""].filter { !$0.isEmpty }.joined(separator: " "), place: "track")
        }

        private mutating func addMedia(_ raw: String, kind: String, type: String, place: String) {
            guard let resolved = PageURLs.resolve(raw, against: base), case .web = resolved.scheme, !resolved.isAnchor else { return }
            media.add(key: resolved.url, cells: [resolved.url, kind, type, ""], url: resolved.url)
        }

        private mutating func embed(_ raw: String, kind: String, type: String, title: String?) {
            guard let resolved = PageURLs.resolve(raw, against: base), case .web = resolved.scheme, !resolved.isAnchor else { return }
            let provider = EmbeddedPlayers.describe(resolved.url)
            // A player is a page that plays something, not a file: there is
            // nothing to save, so these are listed and not downloadable.
            media.add(
                key: resolved.url,
                cells: [resolved.url, kind, provider?.name ?? type, provider?.watchURL ?? ""],
                url: resolved.url,
                canDownload: false
            )
        }

        // MARK: <link> and <meta>

        private mutating func link(_ node: HTMLNode) {
            let rels = (node.attribute("rel") ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            guard !rels.isEmpty, let href = node.attribute("href"), !href.isEmpty,
                  let resolved = PageURLs.resolve(href, against: base) else { return }
            let url = resolved.url
            let type = node.attribute("type") ?? ""
            let relation = rels.joined(separator: " ")

            if rels.contains("stylesheet") {
                resources.add(key: url, cells: [url, "stylesheet", node.attribute("media") ?? ""], url: url)
            } else if rels.contains("preload") || rels.contains("modulepreload") || rels.contains("prefetch") {
                let kind = rels.first { ["preload", "modulepreload", "prefetch"].contains($0) } ?? "preload"
                resources.add(key: url, cells: [url, kind, node.attribute("as") ?? type], url: url)
            } else if rels.contains("preconnect") || rels.contains("dns-prefetch") {
                resources.add(key: url, cells: [url, relation, ""], url: url, canDownload: false)
            }

            if rels.contains("icon") || rels.contains("apple-touch-icon") || rels.contains("mask-icon") || rels.contains("image_src")
                || rels.contains("shortcut") && rels.contains("icon") {
                addImage(url, alt: nil, size: node.attribute("sizes") ?? "", place: "icon")
            }
            if rels.contains("canonical"), canonical == nil { canonical = url }

            if rels.contains("alternate") {
                let lowerType = type.lowercased()
                if lowerType.contains("rss") || lowerType.contains("atom") || lowerType.contains("feed+json") || lowerType.contains("feed") {
                    feeds.add(key: url, cells: [node.attribute("title") ?? "", url, type], url: url)
                }
            }
            let interesting: Set<String> = [
                "canonical", "alternate", "prev", "next", "first", "last", "author", "license", "me", "search",
                "shortlink", "amphtml", "manifest", "webmention", "pingback", "help", "up",
            ]
            if !rels.filter(interesting.contains).isEmpty {
                var name = relation
                if let language = node.attribute("hreflang") { name += " (\(language))" }
                meta.append(["link", name, url], url: url, canDownload: false)
            }
        }

        private static let socialPrefixes = ["og:", "twitter:", "article:", "fb:", "profile:", "book:", "music:", "video:"]

        private mutating func metaTag(_ node: HTMLNode) {
            if let charsetValue = node.attribute("charset"), !charsetValue.isEmpty {
                charset = charsetValue
                meta.append(["standard", "charset", charsetValue])
                return
            }
            let key = node.attribute("property") ?? node.attribute("name") ?? node.attribute("http-equiv") ?? node.attribute("itemprop")
            guard let key = key.flatMap(nonEmpty), let content = node.attribute("content") else { return }
            let lower = key.lowercased()
            let group: String
            if Self.socialPrefixes.contains(where: lower.hasPrefix) {
                group = lower.hasPrefix("twitter:") ? "twitter" : "social"
            } else if node.attribute("http-equiv") != nil {
                group = "http-equiv"
            } else {
                group = "standard"
            }
            meta.append([group, key, content])
            if metaValues[lower] == nil { metaValues[lower] = content }

            if lower == "http-equiv" || lower == "content-type", let range = content.lowercased().range(of: "charset=") {
                charset = String(content[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            if lower == "content-language", language == nil { language = nonEmpty(content) }

            switch lower {
            case "og:image", "og:image:url", "og:image:secure_url": addImage(content, alt: nil, size: "", place: "og:image")
            case "twitter:image", "twitter:image:src": addImage(content, alt: nil, size: "", place: "twitter:image")
            case "og:video", "og:video:url", "og:video:secure_url": addMedia(content, kind: "video", type: metaValues["og:video:type"] ?? "", place: "og:video")
            case "og:audio", "og:audio:url", "og:audio:secure_url": addMedia(content, kind: "audio", type: "", place: "og:audio")
            default: break
            }
        }

        // MARK: Scripts, structured data

        private mutating func script(_ node: HTMLNode) {
            let type = (node.attribute("type") ?? "").lowercased()
            if let src = node.attribute("src"), let resolved = PageURLs.resolve(src, against: base), case .web = resolved.scheme {
                var details: [String] = []
                if type == "module" { details.append("module") }
                if node.hasAttribute("async") { details.append("async") }
                if node.hasAttribute("defer") { details.append("defer") }
                if node.hasAttribute("integrity") { details.append("integrity") }
                resources.add(key: resolved.url, cells: [resolved.url, "script", details.joined(separator: ", ")], url: resolved.url)
                return
            }
            guard type.contains("ld+json") else { return }
            let json = node.rawText().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !json.isEmpty, json.utf8.count < 400_000,
                  let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else { return }
            if let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: pretty, encoding: .utf8), structuredJSON.count < 50 {
                structuredJSON.append(text)
            }
            for item in Self.jsonLDItems(object) where structured.rows.count < 500 {
                structured.append([
                    Self.jsonLDType(item["@type"]),
                    Self.jsonLDString(item["name"] ?? item["headline"] ?? item["title"]) ?? "",
                    Self.jsonLDString(item["url"] ?? item["@id"]) ?? "",
                    "JSON-LD",
                ])
            }
        }

        private static func jsonLDItems(_ object: Any) -> [[String: Any]] {
            if let array = object as? [Any] { return array.flatMap { jsonLDItems($0) } }
            guard let dictionary = object as? [String: Any] else { return [] }
            if let graph = dictionary["@graph"] as? [Any] { return graph.flatMap { jsonLDItems($0) } }
            return [dictionary]
        }

        private static func jsonLDType(_ value: Any?) -> String {
            if let text = value as? String { return text }
            if let list = value as? [Any] { return list.compactMap { $0 as? String }.joined(separator: ", ") }
            return ""
        }

        private static func jsonLDString(_ value: Any?) -> String? {
            if let text = value as? String { return text.isEmpty ? nil : text }
            if let dictionary = value as? [String: Any] { return jsonLDString(dictionary["name"] ?? dictionary["@id"] ?? dictionary["url"]) }
            if let list = value as? [Any] { return list.compactMap { jsonLDString($0) }.first }
            return nil
        }

        /// Microdata: `itemscope` elements, outermost first.
        mutating func visitStructuredData(_ elements: [HTMLNode]) {
            for node in elements where node.hasAttribute("itemscope") && structured.rows.count < 500 {
                // Only the outermost: an item inside another belongs to it.
                var ancestor = node.parent
                var nested = false
                while let current = ancestor {
                    if current.kind == .element, current.hasAttribute("itemscope") { nested = true; break }
                    ancestor = current.parent
                }
                guard !nested else { continue }
                let type = node.attribute("itemtype").map { value in
                    value.split(separator: "/").last.map(String.init) ?? value
                } ?? ""
                func property(_ name: String) -> String? {
                    guard let found = node.descendantElements().first(where: { $0.attribute("itemprop")?.split(separator: " ").contains(Substring(name)) == true }) else { return nil }
                    if let content = found.attribute("content") { return content }
                    if let href = found.attribute("href") ?? found.attribute("src") { return href }
                    return nonEmpty(found.collapsedText())
                }
                structured.append([type, property("name") ?? property("headline") ?? "", property("url") ?? "", "microdata"])
            }
        }

        // MARK: Headings, forms, tables

        private mutating func heading(_ node: HTMLNode) {
            let text = node.collapsedText()
            guard !text.isEmpty, headings.rows.count < PageExtractor.maxRows else { return }
            headings.append(["H\(node.tag.dropFirst())", String(text.prefix(PageExtractor.maxCell)), node.id ?? ""])
        }

        private mutating func form(_ node: HTMLNode) {
            let method = (node.attribute("method") ?? "get").uppercased()
            let action: String
            if let raw = node.attribute("action"), !raw.isEmpty {
                action = PageURLs.resolve(raw, against: base)?.url ?? raw
            } else {
                action = pageURL.absoluteString
            }
            var fields: [String] = []
            for field in node.descendantElements() where ["input", "select", "textarea", "button"].contains(field.tag) {
                guard let name = field.attribute("name"), !name.isEmpty else { continue }
                let type = field.tag == "input" ? (field.attribute("type") ?? "text").lowercased() : field.tag
                fields.append("\(name):\(type)")
            }
            forms.append([method, action, fields.joined(separator: ", ")], url: action, canDownload: false)
        }

        private mutating func table(_ node: HTMLNode) {
            guard tables.count < PageExtractor.maxTables else { return }
            var rows: [[String]] = []
            var headerRowCount = 0
            for row in node.descendantElements() where row.tag == "tr" && row.closest("table") === node {
                let cells = row.elementChildren.filter { $0.tag == "td" || $0.tag == "th" }
                guard !cells.isEmpty else { continue }
                var values: [String] = []
                for cell in cells {
                    values.append(String(cell.collapsedText().prefix(500)))
                    // A cell that spans columns leaves the columns it covers empty.
                    if let span = cell.attribute("colspan").flatMap({ Int($0) }), span > 1, span < 50 {
                        values.append(contentsOf: Array(repeating: "", count: span - 1))
                    }
                }
                if rows.isEmpty, cells.allSatisfy({ $0.tag == "th" }) { headerRowCount = 1 }
                rows.append(values)
                if rows.count >= PageExtractor.maxTableRows { break }
            }
            let width = rows.map(\.count).max() ?? 0
            // One row or one column is layout, not data.
            guard rows.count >= 2, width >= 2 else { return }
            let columns = headerRowCount == 1
                ? rows[0].enumerated().map { $0.element.isEmpty ? "Column \($0.offset + 1)" : $0.element } + (rows[0].count < width ? (rows[0].count..<width).map { "Column \($0 + 1)" } : [])
                : (1...width).map { "Column \($0)" }
            var table = ResultTable(columns: columns)
            for row in rows.dropFirst(headerRowCount) { table.append(row) }
            let caption = node.elementChildren.first { $0.tag == "caption" }.flatMap { nonEmpty($0.collapsedText()) }
            tables.append(PageTable(caption: caption, table: table))
        }

        // MARK: The result

        func page(elementCount: Int, reading: ReadableText.Output) -> ExtractedPage {
            func meta(_ keys: String...) -> String? {
                for key in keys { if let value = metaValues[key], !value.isEmpty { return value } }
                return nil
            }
            let firstHeading = headings.rows.first { $0.cells[0] == "H1" }?.cells[1]
            let resolvedPreview = (metaValues["og:image"] ?? metaValues["twitter:image"]).flatMap {
                PageURLs.resolve($0, against: base)?.url
            }
            return ExtractedPage(
                pageURL: pageURL.absoluteString,
                baseURL: base.absoluteString,
                title: title ?? meta("og:title", "twitter:title") ?? firstHeading,
                summary: meta("description", "og:description", "twitter:description"),
                language: language,
                canonicalURL: canonical,
                siteName: meta("og:site_name", "application-name"),
                author: meta("author", "article:author", "twitter:creator"),
                published: meta("article:published_time", "date", "datepublished", "dc.date", "og:updated_time"),
                previewImage: resolvedPreview,
                charset: charset,
                links: links.table,
                images: images.table,
                media: media.table,
                files: files.table,
                headings: headings,
                tables: tables,
                meta: self.meta,
                structured: structured,
                structuredJSON: structuredJSON,
                resources: resources.table,
                forms: forms,
                feeds: feeds.table,
                text: reading.text,
                markdown: reading.markdown,
                textSource: reading.source,
                elementCount: elementCount,
                anchorCount: anchorCount,
                inlineDataCount: inlineDataCount
            )
        }
    }
}

/// Recognising the players a page embeds, so a list of them can say "YouTube"
/// and point at the page that plays it instead of at an `/embed/` address.
enum EmbeddedPlayers {
    struct Player: Equatable {
        let name: String
        /// The page a person would open to watch or listen, when it can be worked
        /// out from the embed address without asking anyone.
        let watchURL: String?
    }

    static func describe(_ address: String) -> Player? {
        guard let components = URLComponents(string: address), let host = components.host?.lowercased() else { return nil }
        let path = components.path
        let query = components.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        func segment(after marker: String) -> String? {
            let parts = path.split(separator: "/").map(String.init)
            guard let index = parts.firstIndex(of: marker), index + 1 < parts.count else { return nil }
            return parts[index + 1]
        }

        if host.hasSuffix("youtube.com") || host.hasSuffix("youtube-nocookie.com") {
            if let id = segment(after: "embed"), id != "videoseries" { return Player(name: "YouTube", watchURL: "https://www.youtube.com/watch?v=\(id)") }
            if let list = value("list") { return Player(name: "YouTube", watchURL: "https://www.youtube.com/playlist?list=\(list)") }
            return Player(name: "YouTube", watchURL: nil)
        }
        if host == "player.vimeo.com" || host.hasSuffix("vimeo.com") {
            if let id = segment(after: "video") { return Player(name: "Vimeo", watchURL: "https://vimeo.com/\(id)") }
            return Player(name: "Vimeo", watchURL: nil)
        }
        if host.hasSuffix("dailymotion.com") {
            if let id = segment(after: "video") { return Player(name: "Dailymotion", watchURL: "https://www.dailymotion.com/video/\(id)") }
            return Player(name: "Dailymotion", watchURL: nil)
        }
        if host.hasSuffix("spotify.com") {
            let rest = path.replacingOccurrences(of: "/embed", with: "")
            return Player(name: "Spotify", watchURL: rest.isEmpty ? nil : "https://open.spotify.com" + rest)
        }
        if host.hasSuffix("soundcloud.com") { return Player(name: "SoundCloud", watchURL: value("url")) }
        if host.hasSuffix("twitch.tv") {
            if let video = value("video") { return Player(name: "Twitch", watchURL: "https://www.twitch.tv/videos/\(video.replacingOccurrences(of: "v", with: ""))") }
            if let channel = value("channel") { return Player(name: "Twitch", watchURL: "https://www.twitch.tv/\(channel)") }
            return Player(name: "Twitch", watchURL: nil)
        }
        if host.hasSuffix("facebook.com"), path.contains("/plugins/") { return Player(name: "Facebook", watchURL: value("href")) }
        if host.hasSuffix("google.com"), path.hasPrefix("/maps") { return Player(name: "Google Maps", watchURL: nil) }
        if host.hasSuffix("twitter.com") || host.hasSuffix("x.com") { return Player(name: "X", watchURL: nil) }
        return nil
    }
}
