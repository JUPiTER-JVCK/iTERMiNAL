import Foundation

struct HTMLAttribute: Equatable {
    let name: String
    let value: String
}

/// One node of a parsed page: the document itself, an element, a run of text,
/// or a comment.
///
/// A class because a tree has to be walked up as well as down — a selector asks
/// for a node's parent and its earlier siblings — and the parent link is
/// `unowned(unsafe)`: children are owned by their parent, so a parent is alive
/// whenever the tree is, and a reference-counted back-link on every one of a
/// large page's hundreds of thousands of nodes costs more than it protects.
/// A node is only valid while the document it came from is.
final class HTMLNode {
    enum Kind {
        case document, element, text, comment
    }

    let kind: Kind
    /// Lower-cased. Empty for anything that is not an element.
    let tag: String
    let attributes: [HTMLAttribute]
    /// What a text or comment node says, with character references decoded.
    var text: String
    unowned(unsafe) var parent: HTMLNode?
    var children: [HTMLNode] = []

    init(kind: Kind, tag: String = "", attributes: [HTMLAttribute] = [], text: String = "") {
        self.kind = kind
        self.tag = tag
        self.attributes = attributes
        self.text = text
    }

    var isElement: Bool { kind == .element }

    /// The value of an attribute (names are lower-case), if the element has it.
    func attribute(_ name: String) -> String? {
        for attribute in attributes where attribute.name == name { return attribute.value }
        return nil
    }

    func hasAttribute(_ name: String) -> Bool {
        attributes.contains { $0.name == name }
    }

    var id: String? {
        guard let value = attribute("id"), !value.isEmpty else { return nil }
        return value
    }

    var classNames: [String] {
        guard let value = attribute("class") else { return [] }
        return value.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\u{0C}" }).map(String.init)
    }

    var elementChildren: [HTMLNode] {
        children.filter { $0.kind == .element }
    }

    /// This node and everything below it that is an element, in document order.
    func descendantElements(includingSelf: Bool = false) -> [HTMLNode] {
        var found: [HTMLNode] = []
        var stack: [HTMLNode] = includingSelf ? [self] : children.reversed()
        while let node = stack.popLast() {
            guard node.kind == .element else { continue }
            found.append(node)
            stack.append(contentsOf: node.children.reversed())
        }
        return found
    }

    /// Elements whose text is not text a reader sees.
    static let invisibleTags: Set<String> = ["script", "style", "template", "noscript", "head", "svg", "math"]

    /// All the text below this node, as written: nothing collapsed or trimmed.
    /// Descendants that hold no visible text (scripts, styles, the head) are
    /// skipped; the node itself never is, so `<title>`'s own text is its text.
    func rawText() -> String {
        var out = ""
        var stack: [HTMLNode] = children.reversed()
        while let node = stack.popLast() {
            switch node.kind {
            case .text:
                out += node.text
            case .element:
                if !Self.invisibleTags.contains(node.tag) { stack.append(contentsOf: node.children.reversed()) }
            default:
                break
            }
        }
        return out
    }

    /// `rawText()` the way a person reads it: runs of whitespace are one space,
    /// and the ends are trimmed.
    func collapsedText() -> String {
        HTMLNode.collapseWhitespace(rawText())
    }

    static func collapseWhitespace(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            // U+00A0 is whitespace to a reader, though not to `isWhitespace`
            // on every platform.
            if scalar == "\u{A0}" || scalar.properties.isWhitespace {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out.append(" ") }
                pendingSpace = false
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// The markup below this node, rebuilt: enough to show what an element
    /// holds, not a byte-for-byte copy of the source.
    func innerHTML() -> String {
        var out = ""
        for child in children { child.serialize(into: &out) }
        return out
    }

    func outerHTML() -> String {
        var out = ""
        serialize(into: &out)
        return out
    }

    private func serialize(into out: inout String) {
        switch kind {
        case .document:
            for child in children { child.serialize(into: &out) }
        case .text:
            // Raw-text elements hold markup characters as themselves.
            if let parent, ["script", "style"].contains(parent.tag) {
                out += text
            } else {
                out += text.replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
            }
        case .comment:
            out += "<!--\(text)-->"
        case .element:
            out += "<\(tag)"
            for attribute in attributes {
                let value = attribute.value
                    .replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "\"", with: "&quot;")
                out += " \(attribute.name)=\"\(value)\""
            }
            out += ">"
            if !HTMLParser.voidTags.contains(tag) {
                for child in children { child.serialize(into: &out) }
                out += "</\(tag)>"
            }
        }
    }

    /// The nearest ancestor (or the node itself) that is an element called `tag`.
    func closest(_ tag: String) -> HTMLNode? {
        var node: HTMLNode? = self
        while let current = node {
            if current.kind == .element, current.tag == tag { return current }
            node = current.parent
        }
        return nil
    }
}

/// A tolerant HTML parser.
///
/// Real pages are not well-formed: tags go unclosed, `<p>` and `<li>` are
/// closed by whatever comes next, attributes lose their quotes. A browser
/// copes, and so does this — it never fails and never stops early, and what it
/// returns is a tree that a selector can walk. It is not the HTML5 algorithm:
/// there is no foster-parenting of misplaced table content and no
/// reconstruction of formatting elements, so a page broken in those ways comes
/// out shaped differently from how a browser would show it. For finding the
/// links, images and headings on a page that difference does not matter.
///
/// It works on UTF-8 bytes rather than `Character`s, which is what keeps a
/// multi-megabyte page quick.
enum HTMLParser {
    /// Past this many nodes the rest of the page is ignored.
    static let maxNodes = 1_500_000
    /// Deeper than this, an element is kept as a leaf instead of being opened.
    static let maxDepth = 400

    static func parse(_ html: String) -> HTMLNode {
        let builder = TreeBuilder(Array(html.utf8))
        return builder.run()
    }

    /// Elements that cannot have content, and so are never closed.
    static let voidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
        "param", "source", "track", "wbr", "command", "keygen", "frame", "basefont",
    ]

    /// Elements whose content is text up to the matching end tag, with markup
    /// characters meaning nothing.
    fileprivate static let rawTextTags: Set<String> = ["script", "style"]
    /// The same, but character references still apply.
    fileprivate static let escapableRawTextTags: Set<String> = ["textarea", "title"]

    /// A new one of these ends an open paragraph.
    fileprivate static let closesParagraph: Set<String> = [
        "address", "article", "aside", "blockquote", "details", "div", "dl", "fieldset",
        "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6",
        "header", "hgroup", "hr", "main", "menu", "nav", "ol", "p", "pre", "section",
        "table", "ul",
    ]

    /// Where looking for an open paragraph, list item, cell… stops.
    fileprivate static let paragraphBoundaries: Set<String> = [
        "table", "td", "th", "caption", "button", "object", "template", "html", "marquee", "applet",
    ]

    /// What may sit in `<head>`; anything else ends it.
    fileprivate static let headTags: Set<String> = [
        "title", "meta", "link", "script", "style", "base", "noscript", "template", "head", "html",
    ]

    /// Elements that hold only other elements, so whitespace between their
    /// children is formatting and not content.
    fileprivate static let whitespaceInsensitive: Set<String> = [
        "html", "head", "table", "thead", "tbody", "tfoot", "tr", "ul", "ol", "select",
        "dl", "colgroup", "optgroup", "datalist", "menu",
    ]

    // MARK: The builder

    private final class TreeBuilder {
        private let b: [UInt8]
        private let n: Int
        private var i = 0
        private let root = HTMLNode(kind: .document)
        private var stack: [HTMLNode]
        private var nodeCount = 0
        /// Inside `<svg>` or `<math>`, where `<path/>` really is self-closing.
        private var foreignDepth = 0

        init(_ bytes: [UInt8]) {
            b = bytes
            n = bytes.count
            stack = [root]
        }

        // Byte constants.
        private let lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">"), slash = UInt8(ascii: "/")
        private let bang = UInt8(ascii: "!"), question = UInt8(ascii: "?"), eq = UInt8(ascii: "=")
        private let dq = UInt8(ascii: "\""), sq = UInt8(ascii: "'"), dash = UInt8(ascii: "-")

        private func isSpace(_ c: UInt8) -> Bool {
            c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C
        }

        private func isAlpha(_ c: UInt8) -> Bool {
            (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
        }

        private func isNameByte(_ c: UInt8) -> Bool {
            isAlpha(c) || (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x5F || c == 0x3A || c == 0x2E
        }

        private func lowercased(_ bytes: ArraySlice<UInt8>) -> String {
            var copy = Array(bytes)
            for index in copy.indices where copy[index] >= 0x41 && copy[index] <= 0x5A { copy[index] += 0x20 }
            return String(decoding: copy, as: UTF8.self)
        }

        private var current: HTMLNode { stack[stack.count - 1] }

        func run() -> HTMLNode {
            while i < n, nodeCount < HTMLParser.maxNodes {
                if b[i] == lt, i + 1 < n {
                    let next = b[i + 1]
                    if next == bang {
                        markupDeclaration()
                        continue
                    }
                    if next == slash {
                        if endTag() { continue }
                    } else if isAlpha(next) {
                        startTag()
                        continue
                    } else if next == question {
                        // `<?xml …?>`: a processing instruction, which HTML reads as a comment.
                        skipPast(gt)
                        continue
                    }
                }
                textRun()
            }
            return root
        }

        // MARK: Text

        /// Text up to the next thing that is really markup. A `<` that does not
        /// start a tag, a comment or a declaration is just a less-than sign.
        private func textRun() {
            let start = i
            var j = i
            if b[j] == lt { j += 1 }
            while j < n {
                if b[j] == lt, j + 1 < n {
                    let next = b[j + 1]
                    if isAlpha(next) || next == slash || next == bang || next == question { break }
                }
                j += 1
            }
            i = j
            appendText(HTMLEntities.decode(b[start..<j], inAttribute: false))
        }

        private func appendText(_ bytes: [UInt8]) {
            guard !bytes.isEmpty else { return }
            let text = String(decoding: bytes, as: UTF8.self)
            // Formatting between the children of a list or a table is not content.
            if HTMLParser.whitespaceInsensitive.contains(current.tag),
               text.unicodeScalars.allSatisfy({ $0.properties.isWhitespace }) {
                return
            }
            if let last = current.children.last, last.kind == .text {
                last.text += text
                return
            }
            let node = HTMLNode(kind: .text, text: text)
            attach(node)
        }

        private func attach(_ node: HTMLNode) {
            node.parent = current
            current.children.append(node)
            nodeCount += 1
        }

        // MARK: `<!…>`

        private func markupDeclaration() {
            // `<!--` … `-->`
            if i + 3 < n, b[i + 2] == dash, b[i + 3] == dash {
                let start = i + 4
                var j = start
                while j + 2 < n, !(b[j] == dash && b[j + 1] == dash && b[j + 2] == gt) { j += 1 }
                let end = (j + 2 < n) ? j : n
                let node = HTMLNode(kind: .comment, text: String(decoding: b[start..<min(end, n)], as: UTF8.self))
                attach(node)
                i = min(end + 3, n)
                return
            }
            // `<![CDATA[ … ]]>`: text, in the foreign content that uses it.
            if i + 8 < n, b[i + 2] == UInt8(ascii: "["), String(decoding: b[(i + 3)..<(i + 9)], as: UTF8.self) == "CDATA[" {
                let start = i + 9
                var j = start
                while j + 2 < n, !(b[j] == UInt8(ascii: "]") && b[j + 1] == UInt8(ascii: "]") && b[j + 2] == gt) { j += 1 }
                let end = (j + 2 < n) ? j : n
                appendText(Array(b[start..<min(end, n)]))
                i = min(end + 3, n)
                return
            }
            // `<!DOCTYPE …>` and anything else of the kind: skipped.
            skipPast(gt)
        }

        private func skipPast(_ byte: UInt8) {
            while i < n, b[i] != byte { i += 1 }
            i = min(i + 1, n)
        }

        // MARK: Start tags

        private func startTag() {
            var j = i + 1
            let nameStart = j
            while j < n, !isSpace(b[j]), b[j] != slash, b[j] != gt { j += 1 }
            let name = lowercased(b[nameStart..<j])

            var attributes: [HTMLAttribute] = []
            var selfClosing = false
            scan: while j < n {
                while j < n, isSpace(b[j]) { j += 1 }
                guard j < n else { break }
                if b[j] == gt {
                    j += 1
                    break scan
                }
                if b[j] == slash {
                    if j + 1 < n, b[j + 1] == gt {
                        selfClosing = true
                        j += 2
                        break scan
                    }
                    j += 1
                    continue
                }
                // An attribute name runs to a space, `=`, `>` or `/>`.
                let attributeStart = j
                if b[j] == eq { j += 1 }   // a stray `=` starts a name, as in HTML5
                while j < n, !isSpace(b[j]), b[j] != eq, b[j] != gt,
                      !(b[j] == slash && j + 1 < n && b[j + 1] == gt) { j += 1 }
                let attributeName = lowercased(b[attributeStart..<j])
                var k = j
                while k < n, isSpace(b[k]) { k += 1 }
                var value: [UInt8] = []
                if k < n, b[k] == eq {
                    k += 1
                    while k < n, isSpace(b[k]) { k += 1 }
                    if k < n, b[k] == dq || b[k] == sq {
                        let quote = b[k]
                        k += 1
                        let valueStart = k
                        while k < n, b[k] != quote { k += 1 }
                        value = HTMLEntities.decode(b[valueStart..<k], inAttribute: true)
                        k = min(k + 1, n)
                    } else {
                        let valueStart = k
                        while k < n, !isSpace(b[k]), b[k] != gt { k += 1 }
                        value = HTMLEntities.decode(b[valueStart..<k], inAttribute: true)
                    }
                    j = k
                }
                // The first of a repeated attribute wins, as in a browser.
                if !attributeName.isEmpty, !attributes.contains(where: { $0.name == attributeName }) {
                    attributes.append(HTMLAttribute(name: attributeName, value: String(decoding: value, as: UTF8.self)))
                }
            }
            i = j
            open(name, attributes, selfClosing: selfClosing)
        }

        private func open(_ name: String, _ attributes: [HTMLAttribute], selfClosing: Bool) {
            impliedEnd(before: name)
            let node = HTMLNode(kind: .element, tag: name, attributes: attributes)
            attach(node)

            if HTMLParser.voidTags.contains(name) { return }
            if selfClosing, foreignDepth > 0 || name == "svg" || name == "math" { return }

            if HTMLParser.rawTextTags.contains(name) || HTMLParser.escapableRawTextTags.contains(name) {
                rawText(of: node, decoding: HTMLParser.escapableRawTextTags.contains(name))
                return
            }
            guard stack.count < HTMLParser.maxDepth else { return }
            stack.append(node)
            if name == "svg" || name == "math" { foreignDepth += 1 }
        }

        /// The content of `<script>`, `<style>`, `<textarea>`, `<title>`: bytes up
        /// to the matching end tag, however much it looks like markup.
        private func rawText(of element: HTMLNode, decoding: Bool) {
            let target = Array(element.tag.utf8)
            var j = i
            var contentEnd = n
            var resume = n
            while j < n {
                guard b[j] == lt, j + 1 < n, b[j + 1] == slash else { j += 1; continue }
                var k = j + 2
                var matched = true
                for expected in target {
                    guard k < n else { matched = false; break }
                    var c = b[k]
                    if c >= 0x41 && c <= 0x5A { c += 0x20 }
                    if c != expected { matched = false; break }
                    k += 1
                }
                if matched, k >= n || isSpace(b[k]) || b[k] == slash || b[k] == gt {
                    contentEnd = j
                    while k < n, b[k] != gt { k += 1 }
                    resume = min(k + 1, n)
                    break
                }
                j += 1
            }
            if contentEnd > i {
                let bytes = decoding ? HTMLEntities.decode(b[i..<contentEnd], inAttribute: false) : Array(b[i..<contentEnd])
                let node = HTMLNode(kind: .text, text: String(decoding: bytes, as: UTF8.self))
                node.parent = element
                element.children.append(node)
                nodeCount += 1
            }
            i = resume
        }

        // MARK: End tags

        private func endTag() -> Bool {
            var j = i + 2
            let nameStart = j
            while j < n, isNameByte(b[j]) { j += 1 }
            guard j > nameStart else {
                // `</>` or `</ x>`: a bogus comment, dropped.
                skipPast(gt)
                return true
            }
            let name = lowercased(b[nameStart..<j])
            while j < n, b[j] != gt { j += 1 }
            i = min(j + 1, n)
            closeElement(name)
            return true
        }

        private func closeElement(_ name: String) {
            var k = stack.count - 1
            while k > 0 {
                if stack[k].tag == name {
                    pop(to: k)
                    return
                }
                k -= 1
            }
            // `</br>` is a line break to a browser.
            if name == "br" { attach(HTMLNode(kind: .element, tag: "br")) }
        }

        /// Closes the element at `index` and everything opened inside it.
        private func pop(to index: Int) {
            while stack.count > index {
                let node = stack.removeLast()
                if node.tag == "svg" || node.tag == "math" { foreignDepth = max(0, foreignDepth - 1) }
            }
        }

        // MARK: What a start tag closes

        private func impliedEnd(before name: String) {
            // Anything but a head element ends the head: `<head>` is so often
            // left open that waiting for `</head>` would put the page inside it.
            if !HTMLParser.headTags.contains(name), let head = stack.lastIndex(where: { $0.tag == "head" }) {
                pop(to: head)
            }
            if HTMLParser.closesParagraph.contains(name) {
                closeOpen(["p"], stoppingAt: HTMLParser.paragraphBoundaries)
            }
            switch name {
            case "li":
                closeOpen(["li"], stoppingAt: ["ul", "ol", "menu"])
            case "dt", "dd":
                closeOpen(["dt", "dd"], stoppingAt: ["dl"])
            // Closing the outer element closes the cells and rows inside it, so
            // each of these names only the outermost thing it ends.
            case "tr":
                closeOpen(["tr"], stoppingAt: ["table", "thead", "tbody", "tfoot"])
            case "td", "th":
                closeOpen(["td", "th"], stoppingAt: ["tr", "table"])
            case "thead", "tbody", "tfoot":
                closeOpen(["thead", "tbody", "tfoot"], stoppingAt: ["table"])
            case "option":
                closeOpen(["option"], stoppingAt: ["select", "datalist", "optgroup"])
            case "optgroup":
                closeOpen(["option", "optgroup"], stoppingAt: ["select"])
            default:
                break
            }
        }

        /// Looks down the open elements for one of `names`, and closes it and
        /// what is above it — unless a boundary comes first.
        private func closeOpen(_ names: Set<String>, stoppingAt boundaries: Set<String>) {
            var k = stack.count - 1
            while k > 0 {
                let tag = stack[k].tag
                if names.contains(tag) {
                    pop(to: k)
                    return
                }
                if boundaries.contains(tag) { return }
                k -= 1
            }
        }
    }
}
