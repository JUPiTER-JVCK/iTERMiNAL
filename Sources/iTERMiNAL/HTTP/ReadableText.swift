import Foundation

/// The reading part of a page — what an article says, without the menus, the
/// footer and the cookie notice — as plain text and as Markdown.
///
/// This is the same job a reader mode does, and it is approximate in the same
/// way: it finds the part of the page with the most running prose, drops the
/// parts that look like furniture, and writes what is left. A page whose words
/// are put there by scripts has none to find, and comes out empty; a page that
/// is mostly a list of links has no prose and comes out as the biggest block.
enum ReadableText {
    /// Output beyond this many characters is cut, with a note.
    static let maxCharacters = 400_000

    struct Output: Equatable {
        var text: String
        var markdown: String
        /// The element the reading was taken from, as a short description,
        /// for saying where it came from.
        var source: String
    }

    static func extract(from document: HTMLNode, baseURL: URL) -> Output {
        let (root, source) = chooseRoot(in: document)
        let plain = Renderer(markdown: false, baseURL: baseURL).render(root)
        let marked = Renderer(markdown: true, baseURL: baseURL).render(root)
        return Output(text: capped(plain), markdown: capped(marked), source: source)
    }

    private static func capped(_ text: String) -> String {
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(maxCharacters)) + "\n\n… cut at \(maxCharacters) characters"
    }

    // MARK: Finding the content

    private struct Stats {
        var total = 0
        var linked = 0
    }

    /// Text length below every element, and how much of it is link text.
    private static func measure(_ document: HTMLNode) -> [ObjectIdentifier: Stats] {
        var order: [HTMLNode] = []
        var stack: [HTMLNode] = [document]
        while let node = stack.popLast() {
            order.append(node)
            stack.append(contentsOf: node.children)
        }
        var stats: [ObjectIdentifier: Stats] = [:]
        for node in order.reversed() {
            var mine = Stats()
            switch node.kind {
            case .text:
                mine.total = HTMLNode.collapseWhitespace(node.text).count
                if let parent = node.parent, parent.closest("a") != nil { mine.linked = mine.total }
            case .element where HTMLNode.invisibleTags.contains(node.tag):
                break
            default:
                for child in node.children {
                    if let childStats = stats[ObjectIdentifier(child)] {
                        mine.total += childStats.total
                        mine.linked += childStats.linked
                    }
                }
            }
            stats[ObjectIdentifier(node)] = mine
        }
        return stats
    }

    private static func chooseRoot(in document: HTMLNode) -> (HTMLNode, String) {
        let stats = measure(document)
        func length(_ node: HTMLNode) -> Int { stats[ObjectIdentifier(node)]?.total ?? 0 }
        let elements = document.descendantElements()

        // One `<article>` or `<main>` with real text in it says what it is.
        let articles = elements.filter { $0.tag == "article" && length($0) >= 250 }
        if articles.count == 1 { return (articles[0], "article") }
        let mains = elements.filter { ($0.tag == "main" || $0.attribute("role") == "main") && length($0) >= 250 }
        if mains.count == 1 { return (mains[0], "main") }

        // Otherwise the parent of the most prose.
        var scores: [ObjectIdentifier: (node: HTMLNode, score: Double)] = [:]
        func add(_ node: HTMLNode?, _ amount: Double) {
            guard let node, node.kind == .element, node.tag != "html" else { return }
            let key = ObjectIdentifier(node)
            scores[key] = (node, (scores[key]?.score ?? 0) + amount)
        }
        for element in elements where ["p", "pre", "blockquote"].contains(element.tag) {
            let count = length(element)
            guard count >= 25 else { continue }
            let commas = Double(element.rawText().filter { $0 == "," }.count)
            let score = 1 + commas + min(Double(count) / 100, 3)
            add(element.parent, score)
            add(element.parent?.parent, score / 2)
        }
        var best: (node: HTMLNode, score: Double)?
        for (_, entry) in scores {
            let stat = stats[ObjectIdentifier(entry.node)] ?? Stats()
            let density = stat.total == 0 ? 1 : Double(stat.linked) / Double(stat.total)
            let adjusted = entry.score * (1 - density)
            if best == nil || adjusted > best!.score { best = (entry.node, adjusted) }
        }
        if let best, length(best.node) >= 140 { return (best.node, best.node.tag) }
        let body = elements.first { $0.tag == "body" } ?? document
        return (body, "body")
    }

    // MARK: Writing it

    private static let blockTags: Set<String> = [
        "address", "article", "aside", "blockquote", "body", "center", "dd", "details", "dir", "div", "dl",
        "dt", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6",
        "header", "hgroup", "hr", "html", "li", "main", "menu", "nav", "ol", "p", "pre", "section",
        "summary", "table", "tbody", "td", "tfoot", "th", "thead", "tr", "ul",
    ]

    /// Parts that are the page's furniture, not its reading.
    private static let furnitureTags: Set<String> = ["nav", "footer", "aside", "form", "button", "select", "dialog", "menu"]

    private static let furniturePattern = try! NSRegularExpression(
        pattern: #"(?:^|[\s_-])(?:comments?|sidebar|share|sharing|social|promo|advert|advertisement|ads?|cookies?|banner|popup|modal|newsletter|subscribe|breadcrumbs?|related|footer|toolbar|skip-link)(?:$|[\s_-])"#,
        options: [.caseInsensitive]
    )

    private final class Renderer {
        let markdown: Bool
        let baseURL: URL
        private var blocks: [String] = []
        private var run = ""

        init(markdown: Bool, baseURL: URL) {
            self.markdown = markdown
            self.baseURL = baseURL
        }

        func render(_ root: HTMLNode) -> String {
            walk(root, isRoot: true, quote: "", listDepth: 0)
            flush(quote: "")
            let joined = blocks.joined(separator: "\n\n")
            // Never more than one blank line in a row.
            var out = joined
            while out.contains("\n\n\n") { out = out.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
            return out.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // MARK: Blocks

        private func isFurniture(_ node: HTMLNode) -> Bool {
            if node.hasAttribute("hidden") || node.attribute("aria-hidden") == "true" { return true }
            if ReadableText.furnitureTags.contains(node.tag) { return true }
            let label = ((node.attribute("class") ?? "") + " " + (node.id ?? "")).trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty, !["article", "main", "body", "html"].contains(node.tag) else { return false }
            return ReadableText.furniturePattern.firstMatch(in: label, range: NSRange(location: 0, length: (label as NSString).length)) != nil
        }

        private func walk(_ node: HTMLNode, isRoot: Bool, quote: String, listDepth: Int) {
            for child in node.children {
                switch child.kind {
                case .text:
                    run += child.text
                case .element:
                    element(child, quote: quote, listDepth: listDepth)
                default:
                    break
                }
            }
            _ = isRoot
        }

        /// Ends the paragraph being built, if there is one.
        private func flush(quote: String) {
            let text = collapseKeepingBreaks(run).trimmingCharacters(in: .whitespacesAndNewlines)
            run = ""
            guard !text.isEmpty else { return }
            blocks.append(prefixLines(text, with: quote))
        }

        private func prefixLines(_ text: String, with quote: String) -> String {
            guard !quote.isEmpty else { return text }
            return text.split(separator: "\n", omittingEmptySubsequences: false).map { quote + $0 }.joined(separator: "\n")
        }

        private func collapseKeepingBreaks(_ text: String) -> String {
            text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { HTMLNode.collapseWhitespace(String($0)) }
                .joined(separator: "\n")
        }

        private func element(_ node: HTMLNode, quote: String, listDepth: Int) {
            let tag = node.tag
            if HTMLNode.invisibleTags.contains(tag) { return }
            if isFurniture(node) { return }

            switch tag {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                flush(quote: quote)
                let text = inline(node)
                if !text.isEmpty {
                    let level = Int(String(tag.dropFirst())) ?? 1
                    blocks.append(prefixLines(markdown ? String(repeating: "#", count: level) + " " + text : text, with: quote))
                }
            case "hr":
                flush(quote: quote)
                if markdown { blocks.append(prefixLines("---", with: quote)) }
            case "br":
                run += "\n"
            case "pre":
                flush(quote: quote)
                let code = node.rawText().trimmingCharacters(in: CharacterSet.newlines)
                if !code.isEmpty {
                    blocks.append(prefixLines(markdown ? "```\n" + code + "\n```" : code, with: quote))
                }
            case "blockquote":
                flush(quote: quote)
                walk(node, isRoot: false, quote: quote + (markdown ? "> " : ""), listDepth: listDepth)
                flush(quote: quote + (markdown ? "> " : ""))
            case "ul", "ol":
                flush(quote: quote)
                list(node, ordered: tag == "ol", quote: quote, depth: listDepth)
            case "table":
                flush(quote: quote)
                table(node, quote: quote)
            case "img":
                run += image(node)
            case "figcaption":
                flush(quote: quote)
                let text = inline(node)
                if !text.isEmpty { blocks.append(prefixLines(markdown ? "*" + text + "*" : text, with: quote)) }
            default:
                if ReadableText.blockTags.contains(tag) {
                    flush(quote: quote)
                    walk(node, isRoot: false, quote: quote, listDepth: listDepth)
                    flush(quote: quote)
                } else {
                    run += inlineElement(node)
                }
            }
        }

        // MARK: Lists

        private func list(_ node: HTMLNode, ordered: Bool, quote: String, depth: Int) {
            var number = 1
            for item in node.children where item.kind == .element && item.tag == "li" {
                let marker = ordered ? "\(number)." : (markdown ? "-" : "•")
                number += 1
                // The item's own text, and any lists inside it afterwards.
                var own = ""
                var nested: [HTMLNode] = []
                for child in item.children {
                    switch child.kind {
                    case .text: own += child.text
                    case .element:
                        if child.tag == "ul" || child.tag == "ol" { nested.append(child) } else if !HTMLNode.invisibleTags.contains(child.tag) {
                            own += ReadableText.blockTags.contains(child.tag) ? " " + inline(child) + " " : inlineElement(child)
                        }
                    default: break
                    }
                }
                let text = HTMLNode.collapseWhitespace(own)
                let indent = String(repeating: "  ", count: depth)
                if !text.isEmpty { blocks.append(prefixLines(indent + marker + " " + text, with: quote)) }
                for child in nested { list(child, ordered: child.tag == "ol", quote: quote, depth: depth + 1) }
            }
            // A list is tight: its items sit on consecutive lines.
            mergeTrailingListItems()
        }

        /// Joins the list items just written into one block, so a list reads
        /// as a list and not as paragraphs.
        private func mergeTrailingListItems() {
            var items: [String] = []
            while let last = blocks.last, isListItem(last) {
                items.insert(blocks.removeLast(), at: 0)
            }
            if !items.isEmpty { blocks.append(items.joined(separator: "\n")) }
        }

        private func isListItem(_ block: String) -> Bool {
            let trimmed = block.drop(while: { $0 == " " || $0 == ">" })
            return trimmed.hasPrefix("- ") || trimmed.hasPrefix("• ")
                || trimmed.range(of: #"^\d+\. "#, options: .regularExpression) != nil
        }

        // MARK: Tables

        private func table(_ node: HTMLNode, quote: String) {
            var rows: [[String]] = []
            for row in node.descendantElements() where row.tag == "tr" && row.closest("table") === node {
                let cells = row.elementChildren.filter { $0.tag == "td" || $0.tag == "th" }.map { inline($0).replacingOccurrences(of: "\n", with: " ") }
                if !cells.isEmpty { rows.append(cells) }
            }
            guard !rows.isEmpty else { return }
            let width = rows.map(\.count).max() ?? 0
            let padded = rows.map { $0 + Array(repeating: "", count: width - $0.count) }
            if markdown {
                var lines = ["| " + padded[0].map(escapePipes).joined(separator: " | ") + " |"]
                lines.append("| " + padded[0].map { _ in "---" }.joined(separator: " | ") + " |")
                for row in padded.dropFirst() { lines.append("| " + row.map(escapePipes).joined(separator: " | ") + " |") }
                blocks.append(prefixLines(lines.joined(separator: "\n"), with: quote))
            } else {
                blocks.append(prefixLines(padded.map { $0.joined(separator: "\t") }.joined(separator: "\n"), with: quote))
            }
        }

        private func escapePipes(_ text: String) -> String {
            text.replacingOccurrences(of: "|", with: "\\|")
        }

        // MARK: Inline

        /// A node's content on one line (or several, where it has `<br>`).
        private func inline(_ node: HTMLNode) -> String {
            var out = ""
            for child in node.children {
                switch child.kind {
                case .text: out += child.text
                case .element:
                    if HTMLNode.invisibleTags.contains(child.tag) || isFurniture(child) { continue }
                    out += child.tag == "br" ? "\n" : (child.tag == "img" ? image(child) : inlineElement(child))
                default: break
                }
            }
            return collapseKeepingBreaks(out).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func inlineElement(_ node: HTMLNode) -> String {
            let inner = inline(node)
            guard !inner.isEmpty else { return node.tag == "a" ? "" : "" }
            switch node.tag {
            case "a":
                guard markdown, let href = node.attribute("href"),
                      let resolved = PageURLs.resolve(href, against: baseURL), !resolved.isAnchor else { return inner }
                return "[\(inner)](\(resolved.url))"
            case "strong", "b":
                return markdown ? "**\(inner)**" : inner
            case "em", "i":
                return markdown ? "*\(inner)*" : inner
            case "code", "kbd", "samp", "tt":
                return markdown ? "`\(inner)`" : inner
            case "del", "s", "strike":
                return markdown ? "~~\(inner)~~" : inner
            default:
                return " " + inner + " "
            }
        }

        private func image(_ node: HTMLNode) -> String {
            let alt = HTMLNode.collapseWhitespace(node.attribute("alt") ?? "")
            guard markdown else { return alt.isEmpty ? "" : alt }
            guard let src = node.attribute("src") ?? node.attribute("data-src"),
                  let resolved = PageURLs.resolve(src, against: baseURL), case .web = resolved.scheme, !resolved.isAnchor else {
                return alt
            }
            return "![\(alt)](\(resolved.url))"
        }
    }
}
