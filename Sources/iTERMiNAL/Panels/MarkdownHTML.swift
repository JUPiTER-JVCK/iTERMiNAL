import Foundation

/// Markdown to HTML, for showing a README or a notes file without trusting it.
/// Foundation only, so what it does with hostile input is checked off a Mac.
///
/// The one rule: **every character of the output is either escaped text or part
/// of a tag this file wrote itself.** There is no raw HTML pass-through (a tag in
/// the source is shown as the text it is), no `<img>` (a README's badges would
/// otherwise fetch from wherever they like, and tell them who is reading), and a
/// link is only made for `http`, `https`, `mailto` or a `#fragment` — any other
/// address, `javascript:` and `data:` and a relative path included, becomes a
/// span that shows the address on hover and goes nowhere. The page that wraps it
/// also forbids scripts, fetches and frames in its own policy, and the view that
/// shows it turns scripting off: three layers, any one of which would do.
///
/// Supported: headings (# and underlined), paragraphs, emphasis, strong,
/// strikethrough, code spans, fenced and indented code, block quotes, bulleted,
/// numbered and task lists with nesting, tables, rules, links and autolinks, and
/// images as a caption. Not: reference links, footnotes, raw HTML. What it does
/// not know is shown as text, never dropped.
enum MarkdownHTML {
    /// Characters of source read; the rest is dropped.
    static let maxInput = 1_000_000
    /// Nested quotes and lists; deeper than this is shown as plain text.
    static let maxDepth = 10
    /// Characters of one paragraph parsed for markup; a longer one is plain text.
    static let maxInline = 20_000
    static let maxOpeners = 200
    static let maxTableRows = 2000
    static let maxTableColumns = 50
    private static let maxLinkTextDepth = 3
    /// How far a `[` looks for its `]`, and a backtick run for its partner.
    private static let bracketWindow = 1000
    private static let codeSpanWindow = 5000

    // MARK: Entry points

    /// Whether a file name ends in an extension Markdown files are given.
    static func isMarkdownFile(named name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["md", "markdown", "mdown", "mkd", "mkdn", "mdwn"].contains(ext)
    }

    /// The HTML for the body: no page around it.
    static func render(_ markdown: String) -> String {
        var used: [String: Int] = [:]
        return renderBlocks(splitLines(markdown), depth: 0, tight: false, used: &used)
    }

    /// A whole page: the policy, the style, and the document.
    static func page(_ markdown: String, title: String) -> String {
        let head = [
            "<meta charset=\"utf-8\">",
            "<meta http-equiv=\"Content-Security-Policy\" content=\"\(contentSecurityPolicy)\">",
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
            "<title>\(escape(title))</title>",
            "<style>\(style)</style>",
        ].joined()
        return "<!doctype html><html><head>" + head + "</head><body><article>" + render(markdown) + "</article></body></html>"
    }

    /// No scripts, no fetches of any kind, no frames: only the page's own style.
    static let contentSecurityPolicy = "default-src 'none'; style-src 'unsafe-inline'"

    private static let style = #"""
    :root{color-scheme:light dark;--fg:#1f2328;--bg:#ffffff;--muted:#59636e;--rule:#d1d9e0;--code:#f6f8fa;--link:#0969da}
    @media(prefers-color-scheme:dark){:root{--fg:#e6edf3;--bg:#0d1117;--muted:#9198a1;--rule:#3d444d;--code:#161b22;--link:#4493f8}}
    body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.6 -apple-system,BlinkMacSystemFont,sans-serif}
    article{max-width:46em;margin:0 auto;padding:24px 28px 48px}
    h1,h2{border-bottom:1px solid var(--rule);padding-bottom:.3em}
    a{color:var(--link)}.link{color:var(--link);text-decoration:underline dotted}.image{color:var(--muted);font-style:italic}
    code{font:13px ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--code);padding:.15em .35em;border-radius:5px}
    pre{background:var(--code);padding:12px 14px;border-radius:8px;overflow:auto}pre code{background:none;padding:0}
    blockquote{margin:0;padding:0 1em;color:var(--muted);border-left:.25em solid var(--rule)}
    table{border-collapse:collapse}th,td{border:1px solid var(--rule);padding:6px 12px}
    hr{border:0;border-top:1px solid var(--rule)}.task{font-size:1.1em}
    """#

    // MARK: Text

    /// `&`, `<`, `>`, `"` and `'` made harmless. Used on every piece of text and
    /// every attribute value that reaches the output.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for c in text {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(c)
            }
        }
        return out
    }

    private static func isControl(_ c: Character) -> Bool {
        c.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    private static func isDigit(_ c: Character) -> Bool {
        guard let value = c.asciiValue else { return false }
        return value >= 0x30 && value <= 0x39
    }

    private static func isWord(_ c: Character) -> Bool {
        c.isLetter || c.isNumber
    }

    private static let asciiPunctuation = Set("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~")

    private static func stripSpaces(_ text: String) -> String {
        var sub = Substring(text)
        while sub.first == " " { sub = sub.dropFirst() }
        while sub.last == " " { sub = sub.dropLast() }
        return String(sub)
    }

    private static func leftStripSpaces(_ text: String) -> String {
        var sub = Substring(text)
        while sub.first == " " { sub = sub.dropFirst() }
        return String(sub)
    }

    private static func rightStripSpaces(_ text: String) -> String {
        var sub = Substring(text)
        while sub.last == " " { sub = sub.dropLast() }
        return String(sub)
    }

    // MARK: Lines

    private static func expandTabs(_ line: String) -> String {
        guard line.contains("\t") else { return line }
        var out = ""
        var column = 0
        for c in line {
            if c == "\t" {
                let width = 4 - (column % 4)
                out += String(repeating: " ", count: width)
                column += width
            } else {
                out.append(c)
                column += 1
            }
        }
        return out
    }

    private static func splitLines(_ markdown: String) -> [String] {
        var text = String(markdown.prefix(maxInput))
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{0}", with: "\u{FFFD}")
        return text.components(separatedBy: "\n").map(expandTabs)
    }

    private static func indentOf(_ line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " }
    }

    private static func dropping(_ line: String, _ count: Int) -> String {
        String(line.dropFirst(count))
    }

    // MARK: Block starts

    private struct Fence {
        let char: Character
        let length: Int
        let indent: Int
    }

    private static func fenceOpen(_ line: String) -> Fence? {
        let indent = indentOf(line)
        if indent > 3 { return nil }
        let rest = Array(dropping(line, indent))
        guard let first = rest.first, first == "`" || first == "~" else { return nil }
        var n = 0
        while n < rest.count && rest[n] == first { n += 1 }
        if n < 3 { return nil }
        if first == "`" && rest[n...].contains("`") { return nil }
        return Fence(char: first, length: n, indent: indent)
    }

    private static func fenceClose(_ line: String, _ char: Character, _ length: Int) -> Bool {
        if indentOf(line) > 3 { return false }
        let rest = stripSpaces(line)
        return rest.count >= length && rest.allSatisfy { $0 == char }
    }

    private static func atxHeading(_ line: String) -> (level: Int, text: String)? {
        let indent = indentOf(line)
        if indent > 3 { return nil }
        let rest = Array(dropping(line, indent))
        var n = 0
        while n < rest.count && rest[n] == "#" { n += 1 }
        if n < 1 || n > 6 { return nil }
        if n < rest.count && rest[n] != " " { return nil }
        var text = Array(stripSpaces(String(rest[n...])))
        var k = text.count
        while k > 0 && text[k - 1] == "#" { k -= 1 }
        if k < text.count && (k == 0 || text[k - 1] == " ") {
            text = Array(rightStripSpaces(String(text[..<k])))
        }
        return (n, String(text))
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let indent = indentOf(line)
        if indent > 3 { return false }
        let squeezed = dropping(line, indent).filter { $0 != " " }
        guard squeezed.count >= 3, let first = squeezed.first, first == "-" || first == "*" || first == "_" else { return false }
        return squeezed.allSatisfy { $0 == first }
    }

    /// 1 for `===`, 2 for `---`, 0 for neither.
    private static func setextLevel(_ line: String) -> Int {
        let indent = indentOf(line)
        if indent > 3 { return 0 }
        let rest = rightStripSpaces(dropping(line, indent))
        if rest.isEmpty { return 0 }
        if rest.allSatisfy({ $0 == "=" }) { return 1 }
        if rest.allSatisfy({ $0 == "-" }) { return 2 }
        return 0
    }

    private static func quoteContent(_ line: String) -> String? {
        let indent = indentOf(line)
        let chars = Array(line)
        if indent > 3 || indent >= chars.count || chars[indent] != ">" { return nil }
        var rest = String(chars[(indent + 1)...])
        if rest.hasPrefix(" ") { rest = dropping(rest, 1) }
        return rest
    }

    private struct ListMarker {
        /// `b-`, `b*`, `b+`, `o.` or `o)`: items of one list share it.
        let kind: String
        let number: Int
        /// The column the item's text starts at.
        let offset: Int
        let isEmpty: Bool
        var isBullet: Bool { kind.hasPrefix("b") }
    }

    private static func listMarker(_ line: String) -> ListMarker? {
        let indent = indentOf(line)
        if indent > 3 { return nil }
        let rest = Array(dropping(line, indent))
        guard let first = rest.first else { return nil }
        var number = 0
        let markerLength: Int
        let kind: String
        if first == "-" || first == "+" || first == "*" {
            markerLength = 1
            kind = "b" + String(first)
        } else if isDigit(first) {
            var n = 0
            while n < rest.count && isDigit(rest[n]) { n += 1 }
            if n > 9 || n >= rest.count || (rest[n] != "." && rest[n] != ")") { return nil }
            number = Int(String(rest[..<n])) ?? 0
            markerLength = n + 1
            kind = "o" + String(rest[n])
        } else {
            return nil
        }
        let after = Array(rest[markerLength...])
        if let firstAfter = after.first, firstAfter != " " { return nil }
        var spaces = 0
        while spaces < after.count && after[spaces] == " " { spaces += 1 }
        if after.allSatisfy({ $0 == " " }) {
            return ListMarker(kind: kind, number: number, offset: indent + markerLength + 1, isEmpty: true)
        }
        if spaces > 4 { spaces = 1 }
        return ListMarker(kind: kind, number: number, offset: indent + markerLength + spaces, isEmpty: false)
    }

    private static func interruptsParagraph(_ line: String) -> Bool {
        if isBlank(line) { return true }
        if fenceOpen(line) != nil || atxHeading(line) != nil || isHorizontalRule(line) || quoteContent(line) != nil {
            return true
        }
        if let marker = listMarker(line) {
            return !marker.isEmpty && (marker.isBullet || marker.number == 1)
        }
        return false
    }

    private static func splitCells(_ line: String) -> [String] {
        var s = Array(stripSpaces(line))
        if s.first == "|" { s.removeFirst() }
        var cells: [String] = []
        var current: [Character] = []
        var i = 0
        while i < s.count {
            let c = s[i]
            if c == "\\" && i + 1 < s.count && s[i + 1] == "|" {
                current.append("|")
                i += 2
                continue
            }
            if c == "|" {
                cells.append(String(current))
                current = []
                i += 1
                continue
            }
            current.append(c)
            i += 1
        }
        cells.append(String(current))
        if cells.count > 1, stripSpaces(cells[cells.count - 1]).isEmpty, rightStripSpaces(line).hasSuffix("|") {
            cells.removeLast()
        }
        return cells.map(stripSpaces)
    }

    /// `left`, `right`, `center` or empty for each column of a delimiter row, or
    /// nil when the cells are not one.
    private static func tableAlignments(_ cells: [String]) -> [String]? {
        var out: [String] = []
        for cell in cells {
            var body = Substring(cell)
            let left = body.first == ":"
            if left { body = body.dropFirst() }
            let right = body.last == ":"
            if right { body = body.dropLast() }
            if body.isEmpty || !body.allSatisfy({ $0 == "-" }) { return nil }
            out.append(left && right ? "center" : right ? "right" : left ? "left" : "")
        }
        return out
    }

    // MARK: Heading ids

    private static func plainText(ofHTML html: String) -> String {
        var out = ""
        var inTag = false
        for c in html {
            if c == "<" {
                inTag = true
            } else if c == ">" && inTag {
                inTag = false
            } else if !inTag {
                out.append(c)
            }
        }
        return out.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func slug(of text: String) -> String {
        var out = ""
        for c in text.lowercased() {
            if c.isLetter || c.isNumber || c == "-" || c == "_" {
                out.append(c)
            } else if c == " " {
                out += "-"
            }
        }
        return out
    }

    /// `usage`, then `usage-1`, `usage-2`… for the same heading again: the
    /// anchors a table of contents links to.
    private static func headingID(_ html: String, used: inout [String: Int]) -> String {
        var base = slug(of: plainText(ofHTML: html))
        if base.isEmpty { base = "section" }
        let seen = used[base, default: 0]
        used[base] = seen + 1
        return seen == 0 ? base : "\(base)-\(seen)"
    }

    // MARK: Blocks

    private static func paragraphHTML(_ lines: [String], tight: Bool) -> String {
        let text = rightStripSpaces(lines.map(leftStripSpaces).joined(separator: "\n"))
        let html = inline(text)
        return tight ? html : "<p>" + html + "</p>"
    }

    private static func renderBlocks(_ lines: [String], depth: Int, tight: Bool, used: inout [String: Int]) -> String {
        var out = ""
        var i = 0
        let n = lines.count
        while i < n {
            let line = lines[i]
            if isBlank(line) {
                i += 1
                continue
            }
            if depth > maxDepth {
                let plain = lines[i...].filter { !isBlank($0) }.map(stripSpaces).joined(separator: " ")
                out += "<p>" + escape(plain) + "</p>"
                break
            }

            if let fence = fenceOpen(line) {
                var body: [String] = []
                i += 1
                while i < n && !fenceClose(lines[i], fence.char, fence.length) {
                    body.append(dropping(lines[i], min(fence.indent, indentOf(lines[i]))))
                    i += 1
                }
                if i < n { i += 1 }
                out += "<pre><code>" + escape(body.joined(separator: "\n")) + "</code></pre>"
                continue
            }

            if let heading = atxHeading(line) {
                let html = inline(heading.text)
                let id = escape(headingID(html, used: &used))
                out += "<h\(heading.level) id=\"" + id + "\">" + html + "</h\(heading.level)>"
                i += 1
                continue
            }

            if isHorizontalRule(line) {
                out += "<hr>"
                i += 1
                continue
            }

            if quoteContent(line) != nil {
                var inner: [String] = []
                while i < n {
                    if let content = quoteContent(lines[i]) {
                        inner.append(content)
                        i += 1
                        continue
                    }
                    // A line that carries on the quote's paragraph without its own >.
                    if !isBlank(lines[i]), let last = inner.last, !isBlank(last), !interruptsParagraph(lines[i]) {
                        inner.append(lines[i])
                        i += 1
                        continue
                    }
                    break
                }
                out += "<blockquote>" + renderBlocks(inner, depth: depth + 1, tight: false, used: &used) + "</blockquote>"
                continue
            }

            if listMarker(line) != nil {
                let (html, next) = renderList(lines, from: i, depth: depth, used: &used)
                out += html
                i = next
                continue
            }

            // A table starts here: a header row, then a delimiter row of the same width.
            if line.contains("|") && i + 1 < n && indentOf(line) <= 3 {
                let header = splitCells(line)
                let next = lines[i + 1]
                if next.contains("-") && next.contains("|"),
                   let aligns = tableAlignments(splitCells(next)),
                   aligns.count == header.count, header.count <= maxTableColumns {
                    let (html, after) = renderTable(lines, from: i, header: header, aligns: aligns)
                    out += html
                    i = after
                    continue
                }
            }

            if indentOf(line) >= 4 {
                var body: [String] = []
                while i < n && (indentOf(lines[i]) >= 4 || isBlank(lines[i])) {
                    body.append(isBlank(lines[i]) ? "" : dropping(lines[i], 4))
                    i += 1
                }
                while body.last == "" { body.removeLast() }
                out += "<pre><code>" + escape(body.joined(separator: "\n")) + "</code></pre>"
                continue
            }

            // A paragraph, or a setext heading when an underline follows it.
            var paragraph = [line]
            i += 1
            var level = 0
            while i < n {
                level = setextLevel(lines[i])
                if level != 0 { break }
                if interruptsParagraph(lines[i]) { break }
                paragraph.append(lines[i])
                i += 1
            }
            if level != 0 && i < n {
                let html = inline(rightStripSpaces(paragraph.map(leftStripSpaces).joined(separator: "\n")))
                let id = escape(headingID(html, used: &used))
                out += "<h\(level) id=\"" + id + "\">" + html + "</h\(level)>"
                i += 1
                continue
            }
            out += paragraphHTML(paragraph, tight: tight)
        }
        return out
    }

    private static func renderList(_ lines: [String], from start: Int, depth: Int, used: inout [String: Int]) -> (String, Int) {
        guard let first = listMarker(lines[start]) else { return ("", start + 1) }
        let n = lines.count
        var items: [(number: Int, lines: [String])] = []
        var loose = false
        var j = start
        while j < n {
            if isHorizontalRule(lines[j]) { break }
            guard let marker = listMarker(lines[j]), marker.kind == first.kind else { break }
            let offset = marker.offset
            let chars = Array(lines[j])
            var item = [offset <= chars.count ? String(chars[offset...]) : ""]
            let number = marker.number
            j += 1
            var blanks = 0
            while j < n {
                let line = lines[j]
                if isBlank(line) {
                    blanks += 1
                    j += 1
                    continue
                }
                if indentOf(line) >= offset {
                    item.append(contentsOf: Array(repeating: "", count: blanks))
                    if blanks > 0 { loose = true }
                    blanks = 0
                    item.append(dropping(line, offset))
                    j += 1
                    continue
                }
                if blanks == 0, item[item.count - 1] != "", !interruptsParagraph(line), listMarker(line) == nil {
                    item.append(leftStripSpaces(line))
                    j += 1
                    continue
                }
                break
            }
            if blanks > 0, j < n, let nextMarker = listMarker(lines[j]), nextMarker.kind == first.kind, !isHorizontalRule(lines[j]) {
                loose = true
            }
            items.append((number, item))
        }

        var html = ""
        for entry in items {
            var item = entry.lines
            var task = ""
            let firstLine = item.first ?? ""
            if firstLine.hasPrefix("[ ] ") || firstLine.hasPrefix("[x] ") || firstLine.hasPrefix("[X] ")
                || firstLine == "[ ]" || firstLine == "[x]" || firstLine == "[X]" {
                let done = firstLine.dropFirst().first == "x" || firstLine.dropFirst().first == "X"
                task = "<span class=\"task\">" + (done ? "\u{2611}" : "\u{2610}") + "</span> "
                item[0] = dropping(firstLine, 4)
            }
            html += "<li>" + task + renderBlocks(item, depth: depth + 1, tight: !loose, used: &used) + "</li>"
        }
        let tag = first.isBullet ? "ul" : "ol"
        var startAttribute = ""
        if !first.isBullet, let firstItem = items.first, firstItem.number != 1 {
            startAttribute = " start=\"\(firstItem.number)\""
        }
        return ("<\(tag)\(startAttribute)>" + html + "</\(tag)>", j)
    }

    private static func renderTable(_ lines: [String], from start: Int, header: [String], aligns: [String]) -> (String, Int) {
        let n = lines.count
        func cell(_ tag: String, _ text: String, _ column: Int) -> String {
            let align = column < aligns.count ? aligns[column] : ""
            let style = align.isEmpty ? "" : " style=\"text-align:\(align)\""
            return "<\(tag)\(style)>\(inline(text))</\(tag)>"
        }
        var html = "<table><thead><tr>"
        for (column, text) in header.enumerated() { html += cell("th", text, column) }
        html += "</tr></thead>"
        var i = start + 2
        var rows = ""
        var rowCount = 0
        while i < n && !isBlank(lines[i]) && rowCount < maxTableRows {
            if interruptsParagraph(lines[i]) { break }
            var cells = splitCells(lines[i])
            while cells.count < header.count { cells.append("") }
            cells = Array(cells.prefix(header.count))
            rows += "<tr>"
            for (column, text) in cells.enumerated() { rows += cell("td", text, column) }
            rows += "</tr>"
            rowCount += 1
            i += 1
        }
        if rowCount > 0 { html += "<tbody>" + rows + "</tbody>" }
        html += "</table>"
        return (html, i)
    }

    // MARK: Links

    /// The address if it may be linked: http, https, mailto or a fragment, with
    /// nothing in it that is whitespace or a control character.
    static func safeHref(_ url: String) -> String? {
        if url.isEmpty || url.count > 2000 { return nil }
        if url.contains(where: { $0 == " " || isControl($0) }) { return nil }
        if url.hasPrefix("#") { return url }
        let lower = url.lowercased()
        if lower.hasPrefix("https://") && url.count > 8 { return url }
        if lower.hasPrefix("http://") && url.count > 7 { return url }
        if lower.hasPrefix("mailto:") && url.count > 7 { return url }
        return nil
    }

    private static func linkHTML(_ textHTML: String, url: String, title: String = "") -> String {
        guard let href = safeHref(url) else {
            let shown = !url.isEmpty && url.count <= 2000 && !url.contains(where: isControl)
            let titleAttribute = shown ? " title=\"\(escape(url))\"" : ""
            return "<span class=\"link\"\(titleAttribute)>\(textHTML)</span>"
        }
        let titleAttribute = title.isEmpty ? "" : " title=\"\(escape(title))\""
        return "<a href=\"\(escape(href))\"\(titleAttribute)>\(textHTML)</a>"
    }

    /// `chars[start]` is `(`. The address, the title and where the link ends.
    private static func parseLinkTail(_ chars: [Character], _ start: Int) -> (url: String, title: String, next: Int)? {
        let n = chars.count
        var j = start + 1
        while j < n && chars[j] == " " { j += 1 }
        var url: [Character] = []
        if j < n && chars[j] == "<" {
            j += 1
            while j < n && chars[j] != "<" && chars[j] != ">" && chars[j] != "\n" {
                url.append(chars[j])
                j += 1
            }
            if j >= n || chars[j] != ">" { return nil }
            j += 1
        } else {
            var depth = 0
            while j < n {
                let c = chars[j]
                if c == "\\" && j + 1 < n && asciiPunctuation.contains(chars[j + 1]) {
                    url.append(chars[j + 1])
                    j += 2
                    continue
                }
                if c == " " || c == "\n" { break }
                if c == "(" {
                    depth += 1
                } else if c == ")" {
                    if depth == 0 { break }
                    depth -= 1
                }
                url.append(c)
                j += 1
            }
        }
        while j < n && (chars[j] == " " || chars[j] == "\n") { j += 1 }
        var title: [Character] = []
        if j < n && (chars[j] == "\"" || chars[j] == "'" || chars[j] == "(") {
            let close: Character = chars[j] == "(" ? ")" : chars[j]
            j += 1
            while j < n && chars[j] != close {
                if chars[j] == "\\" && j + 1 < n && asciiPunctuation.contains(chars[j + 1]) {
                    title.append(chars[j + 1])
                    j += 2
                    continue
                }
                title.append(chars[j])
                j += 1
            }
            if j >= n { return nil }
            j += 1
            while j < n && (chars[j] == " " || chars[j] == "\n") { j += 1 }
        }
        if j >= n || chars[j] != ")" { return nil }
        return (String(url), String(title), j + 1)
    }

    /// `chars[start]` is `[`. The index of its `]`, or nil. Escapes and code
    /// spans are skipped, and it gives up after `bracketWindow` characters.
    private static func findBracketEnd(_ chars: [Character], _ start: Int) -> Int? {
        let n = min(chars.count, start + bracketWindow)
        var depth = 0
        var j = start
        while j < n {
            let c = chars[j]
            if c == "\\" && j + 1 < n {
                j += 2
                continue
            }
            if c == "`" {
                var k = j
                while k < n && chars[k] == "`" { k += 1 }
                let run = k - j
                var m = k
                var found = -1
                while m < n {
                    if chars[m] == "`" {
                        var e = m
                        while e < n && chars[e] == "`" { e += 1 }
                        if e - m == run {
                            found = e
                            break
                        }
                        m = e
                    } else {
                        m += 1
                    }
                }
                j = found != -1 ? found : k
                continue
            }
            if c == "[" {
                depth += 1
            } else if c == "]" {
                depth -= 1
                if depth == 0 { return j }
            }
            j += 1
        }
        return nil
    }

    // MARK: Inline

    private struct Opener {
        var char: Character
        var count: Int
        var position: Int
    }

    static func inline(_ text: String, linkDepth: Int = 0, allowLinks: Bool = true) -> String {
        if text.count > maxInline {
            return escape(text).replacingOccurrences(of: "\n", with: " ")
        }
        let chars = Array(text)
        let n = chars.count
        var out: [String] = []
        var openers: [Opener] = []
        var buffer: [Character] = []
        var i = 0

        func flush() {
            if !buffer.isEmpty {
                out.append(escape(String(buffer)))
                buffer.removeAll()
            }
        }

        while i < n {
            let c = chars[i]

            if c == "\\" && i + 1 < n {
                let next = chars[i + 1]
                if next == "\n" {
                    flush()
                    out.append("<br>")
                    i += 2
                    while i < n && chars[i] == " " { i += 1 }
                    continue
                }
                if asciiPunctuation.contains(next) {
                    buffer.append(next)
                    i += 2
                    continue
                }
                buffer.append(c)
                i += 1
                continue
            }

            if c == "\n" {
                // Two spaces before the break make it a hard one.
                var spaces = 0
                while buffer.last == " " {
                    buffer.removeLast()
                    spaces += 1
                }
                flush()
                out.append(spaces >= 2 ? "<br>" : " ")
                i += 1
                while i < n && chars[i] == " " { i += 1 }
                continue
            }

            if c == "`" {
                var k = i
                while k < n && chars[k] == "`" { k += 1 }
                let run = k - i
                var m = k
                var found = -1
                let limit = min(n, k + codeSpanWindow)
                while m < limit {
                    if chars[m] == "`" {
                        var e = m
                        while e < n && chars[e] == "`" { e += 1 }
                        if e - m == run {
                            found = m
                            break
                        }
                        m = e
                    } else {
                        m += 1
                    }
                }
                if found == -1 {
                    buffer.append(contentsOf: chars[i..<k])
                    i = k
                    continue
                }
                var content = String(chars[k..<found]).replacingOccurrences(of: "\n", with: " ")
                if content.count >= 2, content.hasPrefix(" "), content.hasSuffix(" "), !stripSpaces(content).isEmpty {
                    content = String(content.dropFirst().dropLast())
                }
                flush()
                out.append("<code>" + escape(content) + "</code>")
                i = found + run
                continue
            }

            if c == "!" && i + 1 < n && chars[i + 1] == "[" {
                if let end = findBracketEnd(chars, i + 1), end + 1 < n, chars[end + 1] == "(",
                   let tail = parseLinkTail(chars, end + 1) {
                    let alt = String(chars[(i + 2)..<end])
                    flush()
                    let caption = stripSpaces(alt).isEmpty ? "" : ": " + escape(alt)
                    out.append("<span class=\"image\">Image" + caption + "</span>")
                    i = tail.next
                    continue
                }
                buffer.append(c)
                i += 1
                continue
            }

            if c == "[" && allowLinks {
                if let end = findBracketEnd(chars, i), end + 1 < n, chars[end + 1] == "(",
                   let tail = parseLinkTail(chars, end + 1), linkDepth < maxLinkTextDepth {
                    let inner = inline(String(chars[(i + 1)..<end]), linkDepth: linkDepth + 1, allowLinks: false)
                    flush()
                    out.append(linkHTML(inner, url: tail.url, title: tail.title))
                    i = tail.next
                    continue
                }
                buffer.append(c)
                i += 1
                continue
            }

            if c == "<" {
                var k = i + 1
                while k < n && chars[k] != "<" && chars[k] != ">" && chars[k] != " " && chars[k] != "\n" { k += 1 }
                if k < n && chars[k] == ">" && k > i + 1 {
                    let target = String(chars[(i + 1)..<k])
                    let lower = target.lowercased()
                    if (lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:")),
                       safeHref(target) != nil {
                        flush()
                        out.append(linkHTML(escape(target), url: target))
                        i = k + 1
                        continue
                    }
                }
                buffer.append(c)
                i += 1
                continue
            }

            if c == "h" && allowLinks && startsBareURL(chars, i) {
                var k = i
                while k < n && chars[k] != " " && chars[k] != "\n" && chars[k] != "<" && chars[k] != ">" { k += 1 }
                var url = Array(chars[i..<k])
                // Trailing punctuation is not part of the address.
                while let last = url.last, ".,;:!?'\"*_~".contains(last) { url.removeLast() }
                let opens = url.filter { $0 == "(" }.count
                var closes = url.filter { $0 == ")" }.count
                while url.last == ")" && closes > opens {
                    url.removeLast()
                    closes -= 1
                }
                let target = String(url)
                if safeHref(target) != nil {
                    flush()
                    out.append(linkHTML(escape(target), url: target))
                    i += url.count
                    continue
                }
                buffer.append(c)
                i += 1
                continue
            }

            if c == "*" || c == "_" || c == "~" {
                var k = i
                while k < n && chars[k] == c { k += 1 }
                let run = k - i
                let before: Character = i > 0 ? chars[i - 1] : " "
                let after: Character = k < n ? chars[k] : " "
                var canOpen = after != " " && after != "\n"
                var canClose = before != " " && before != "\n"
                if c == "_" {
                    canOpen = canOpen && !isWord(before)
                    canClose = canClose && !isWord(after)
                }
                if c == "~" && run != 2 {
                    buffer.append(contentsOf: chars[i..<k])
                    i = k
                    continue
                }
                flush()
                var remaining = run
                if canClose {
                    while remaining > 0 {
                        guard let index = openers.lastIndex(where: { $0.char == c && $0.count > 0 }) else { break }
                        let opener = openers[index]
                        let use: Int
                        let tag: String
                        if c == "~" {
                            if opener.count < 2 || remaining < 2 { break }
                            use = 2
                            tag = "del"
                        } else {
                            use = (opener.count >= 2 && remaining >= 2) ? 2 : 1
                            tag = use == 2 ? "strong" : "em"
                        }
                        let inner = out[(opener.position + 1)...].joined()
                        out.removeSubrange((opener.position + 1)...)
                        out.append("<\(tag)>\(inner)</\(tag)>")
                        openers[index].count -= use
                        remaining -= use
                        openers.removeSubrange((index + 1)...)
                        if openers[index].count == 0 {
                            out.remove(at: opener.position)
                            openers.remove(at: index)
                        } else {
                            out[opener.position] = escape(String(repeating: String(c), count: openers[index].count))
                        }
                    }
                }
                if remaining > 0 {
                    out.append(escape(String(repeating: String(c), count: remaining)))
                    if canOpen && openers.count < maxOpeners {
                        openers.append(Opener(char: c, count: remaining, position: out.count - 1))
                    }
                }
                i = k
                continue
            }

            buffer.append(c)
            i += 1
        }
        flush()
        return out.joined()
    }

    /// `http://` or `https://` at `index`, after the start of a word.
    private static func startsBareURL(_ chars: [Character], _ index: Int) -> Bool {
        if index > 0 && !" \n(*_~".contains(chars[index - 1]) { return false }
        for scheme in ["http://", "https://"] {
            let letters = Array(scheme)
            if index + letters.count <= chars.count && Array(chars[index..<(index + letters.count)]) == letters { return true }
        }
        return false
    }
}
