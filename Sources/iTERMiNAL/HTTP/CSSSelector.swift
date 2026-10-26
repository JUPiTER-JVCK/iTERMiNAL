import Foundation

/// A selector that could not be read, and where.
struct CSSSelectorError: LocalizedError, Equatable {
    let message: String
    /// Offset in the text, in characters.
    let position: Int

    var errorDescription: String? { "\(message) (at character \(position + 1))" }
}

/// CSS selectors over a parsed page: the subset that finding things on a page
/// needs, and a few the web scrapers add.
///
/// - Type, `*`, `#id`, `.class`.
/// - Attributes: `[a]`, `[a=v]`, `[a~=v]`, `[a|=v]`, `[a^=v]`, `[a$=v]`,
///   `[a*=v]`, with an `i` flag for case-insensitive.
/// - Combinators: descendant, `>`, `+`, `~`; lists with `,`.
/// - `:first-child` `:last-child` `:only-child`, the same `-of-type`, the
///   `:nth-` family with `An+B`/`odd`/`even`, `:empty`, `:root`, `:not(…)`,
///   `:has(…)`.
/// - `:contains("text")`, which is not CSS but is what jQuery and Scrapy users
///   reach for to find an element by what it says.
///
/// Not here: `:hover` and the other states that need a browser, namespaces,
/// and `:is`/`:where`.
struct CSSSelector {
    fileprivate let groups: [Complex]

    /// A selector can be written, or a page built, so that matching takes longer
    /// than anyone will wait: `.x div div div div div div div div` on a page
    /// nested a few hundred deep tries every way of choosing the ancestors, and
    /// a typed selector is never the page's to choose, but the page is. Matching
    /// counts its steps and gives up past `stepLimit`; what it found by then is
    /// not the answer, and `exhausted` says so. A few seconds of work in a
    /// release build, and far more than anything people write needs.
    static let defaultStepLimit = 20_000_000

    let stepLimit: Int

    private final class Budget {
        var steps = 0
        var exhausted = false
    }

    private let budget = Budget()

    /// Whether the last `select` stopped for lack of steps rather than because
    /// it had looked everywhere.
    var exhausted: Bool { budget.exhausted }

    static func parse(_ text: String, stepLimit: Int = defaultStepLimit) throws -> CSSSelector {
        var parser = SelectorParser(Array(text))
        let groups = try parser.parseList(topLevel: true)
        return CSSSelector(groups: groups, stepLimit: stepLimit)
    }

    /// Whether `node` is matched by any of the selector's comma-separated parts.
    func matches(_ node: HTMLNode) -> Bool {
        guard node.kind == .element else { return false }
        return groups.contains { match(node, $0, $0.parts.count - 1) }
    }

    /// Every element under `root` (not `root` itself) that matches, in document
    /// order, up to `limit`.
    func select(in root: HTMLNode, limit: Int = Int.max) -> [HTMLNode] {
        budget.steps = 0
        budget.exhausted = false
        var found: [HTMLNode] = []
        var stack: [HTMLNode] = root.children.reversed()
        while let node = stack.popLast() {
            if budget.exhausted { break }
            guard node.kind == .element else { continue }
            if matches(node) {
                found.append(node)
                if found.count >= limit { break }
            }
            stack.append(contentsOf: node.children.reversed())
        }
        return found
    }

    // MARK: Model

    fileprivate enum Combinator {
        case descendant, child, adjacent, sibling
    }

    fileprivate enum AttributeOperator {
        case exists, equals, word, dash, prefix, suffix, substring
    }

    fileprivate struct AttributeCondition {
        let name: String
        let op: AttributeOperator
        let value: String
        let ignoreCase: Bool
    }

    fileprivate struct Nth {
        let a: Int
        let b: Int

        /// Whether the 1-based `position` is one of `a·n + b` for some n ≥ 0.
        func matches(_ position: Int) -> Bool {
            if a == 0 { return position == b }
            let difference = position - b
            return difference % a == 0 && difference / a >= 0
        }
    }

    fileprivate indirect enum Pseudo {
        case firstChild, lastChild, onlyChild
        case firstOfType, lastOfType, onlyOfType
        case nthChild(Nth), nthLastChild(Nth), nthOfType(Nth), nthLastOfType(Nth)
        case empty, root
        case not([Compound])
        case has([Complex])
        case contains(String)
    }

    fileprivate struct Compound {
        var tag: String?
        /// `*` was written. It matches everything, but it is something.
        var universal = false
        var id: String?
        var classes: [String] = []
        var attributes: [AttributeCondition] = []
        var pseudos: [Pseudo] = []

        var isEmpty: Bool {
            tag == nil && !universal && id == nil && classes.isEmpty && attributes.isEmpty && pseudos.isEmpty
        }
    }

    fileprivate struct Part {
        /// How this part relates to the one before it.
        let combinator: Combinator
        let compound: Compound
    }

    fileprivate struct Complex {
        var parts: [Part]
    }

    // MARK: Matching

    private func match(_ node: HTMLNode, _ complex: Complex, _ index: Int) -> Bool {
        budget.steps += 1
        if budget.steps > stepLimit { budget.exhausted = true }
        if budget.exhausted { return false }
        let part = complex.parts[index]
        guard matches(node, part.compound) else { return false }
        guard index > 0 else { return true }
        switch part.combinator {
        case .descendant:
            var ancestor = node.parent
            while let candidate = ancestor {
                if candidate.kind == .element, match(candidate, complex, index - 1) { return true }
                ancestor = candidate.parent
            }
            return false
        case .child:
            guard let parent = node.parent, parent.kind == .element else { return false }
            return match(parent, complex, index - 1)
        case .adjacent:
            guard let previous = previousElement(of: node) else { return false }
            return match(previous, complex, index - 1)
        case .sibling:
            var sibling = previousElement(of: node)
            while let candidate = sibling {
                if match(candidate, complex, index - 1) { return true }
                sibling = previousElement(of: candidate)
            }
            return false
        }
    }

    private func previousElement(of node: HTMLNode) -> HTMLNode? {
        guard let parent = node.parent else { return nil }
        // Finding it walks the siblings, and `a ~ a ~ a` walks them over and over.
        budget.steps += parent.children.count
        var previous: HTMLNode?
        for child in parent.children {
            if child === node { return previous }
            if child.kind == .element { previous = child }
        }
        return nil
    }

    private func matches(_ node: HTMLNode, _ compound: Compound) -> Bool {
        if let tag = compound.tag, tag != node.tag { return false }
        if let id = compound.id, node.attribute("id") != id { return false }
        if !compound.classes.isEmpty {
            let names = node.classNames
            for required in compound.classes where !names.contains(required) { return false }
        }
        for condition in compound.attributes where !matches(node, condition) { return false }
        // Pseudo-classes last: some of them read the whole subtree.
        for pseudo in compound.pseudos where !matches(node, pseudo) { return false }
        return true
    }

    private func matches(_ node: HTMLNode, _ condition: AttributeCondition) -> Bool {
        guard var actual = node.attribute(condition.name) else { return false }
        var expected = condition.value
        if condition.op == .exists { return true }
        if condition.ignoreCase {
            actual = actual.lowercased()
            expected = expected.lowercased()
        }
        switch condition.op {
        case .exists: return true
        case .equals: return actual == expected
        case .word:
            return !expected.isEmpty && !expected.contains(where: \.isWhitespace)
                && actual.split(whereSeparator: \.isWhitespace).contains { $0 == expected }
        case .dash: return actual == expected || actual.hasPrefix(expected + "-")
        case .prefix: return !expected.isEmpty && actual.hasPrefix(expected)
        case .suffix: return !expected.isEmpty && actual.hasSuffix(expected)
        case .substring: return !expected.isEmpty && actual.contains(expected)
        }
    }

    private func siblings(of node: HTMLNode, sameType: Bool) -> [HTMLNode] {
        guard let parent = node.parent else { return [node] }
        budget.steps += parent.children.count
        return parent.children.filter { $0.kind == .element && (!sameType || $0.tag == node.tag) }
    }

    private func matches(_ node: HTMLNode, _ pseudo: Pseudo) -> Bool {
        switch pseudo {
        case .firstChild: return siblings(of: node, sameType: false).first === node
        case .lastChild: return siblings(of: node, sameType: false).last === node
        case .onlyChild: return siblings(of: node, sameType: false).count == 1
        case .firstOfType: return siblings(of: node, sameType: true).first === node
        case .lastOfType: return siblings(of: node, sameType: true).last === node
        case .onlyOfType: return siblings(of: node, sameType: true).count == 1
        case .nthChild(let nth):
            return position(of: node, in: siblings(of: node, sameType: false), fromEnd: false).map(nth.matches) ?? false
        case .nthLastChild(let nth):
            return position(of: node, in: siblings(of: node, sameType: false), fromEnd: true).map(nth.matches) ?? false
        case .nthOfType(let nth):
            return position(of: node, in: siblings(of: node, sameType: true), fromEnd: false).map(nth.matches) ?? false
        case .nthLastOfType(let nth):
            return position(of: node, in: siblings(of: node, sameType: true), fromEnd: true).map(nth.matches) ?? false
        case .empty:
            return node.children.allSatisfy { child in
                switch child.kind {
                case .element: return false
                case .text: return child.text.allSatisfy(\.isWhitespace)
                default: return true
                }
            }
        case .root:
            guard let parent = node.parent else { return false }
            return parent.kind == .document && parent.children.filter { $0.kind == .element }.count == 1
                || node.tag == "html"
        case .not(let compounds):
            return !compounds.contains { matches(node, $0) }
        case .has(let complexes):
            let below = node.descendantElements()
            // Looking at each of them is work too, and `:has` inside `:has` multiplies it.
            budget.steps += below.count
            return below.contains { candidate in
                complexes.contains { match(candidate, $0, $0.parts.count - 1) }
            }
        case .contains(let needle):
            return node.collapsedText().contains(needle)
        }
    }

    private func position(of node: HTMLNode, in list: [HTMLNode], fromEnd: Bool) -> Int? {
        guard let index = list.firstIndex(where: { $0 === node }) else { return nil }
        return fromEnd ? list.count - index : index + 1
    }
}

// MARK: Reading a selector

private struct SelectorParser {
    private let c: [Character]
    private var i = 0

    init(_ characters: [Character]) { c = characters }

    private func error(_ message: String) -> CSSSelectorError {
        CSSSelectorError(message: message, position: min(i, c.count))
    }

    private var atEnd: Bool { i >= c.count }

    private mutating func skipSpace() {
        while i < c.count, c[i].isWhitespace { i += 1 }
    }

    private func isIdentStart(_ ch: Character) -> Bool {
        ch.isLetter || ch == "_" || ch == "-" || ch == "\\" || (ch.unicodeScalars.first.map { $0.value > 127 } ?? false)
    }

    private func isIdentPart(_ ch: Character) -> Bool {
        isIdentStart(ch) || ch.isNumber
    }

    mutating func parseList(topLevel: Bool) throws -> [CSSSelector.Complex] {
        var list: [CSSSelector.Complex] = []
        while true {
            skipSpace()
            list.append(try parseComplex(topLevel: topLevel))
            skipSpace()
            if i < c.count, c[i] == "," {
                i += 1
                continue
            }
            break
        }
        if topLevel, !atEnd { throw error("Unexpected \"\(c[i])\"") }
        return list
    }

    private mutating func parseComplex(topLevel: Bool) throws -> CSSSelector.Complex {
        var parts: [CSSSelector.Part] = []
        var combinator: CSSSelector.Combinator = .descendant
        while true {
            let compound = try parseCompound()
            guard !compound.isEmpty else {
                throw error(atEnd ? "The selector ends where something was expected" : "Expected a selector but found \"\(c[i])\"")
            }
            parts.append(CSSSelector.Part(combinator: combinator, compound: compound))

            // Between parts: whitespace is a combinator, and so is `>`, `+`, `~`.
            let before = i
            skipSpace()
            let hadSpace = i > before
            guard i < c.count else { break }
            switch c[i] {
            case ">": combinator = .child; i += 1; skipSpace()
            case "+": combinator = .adjacent; i += 1; skipSpace()
            case "~": combinator = .sibling; i += 1; skipSpace()
            case ",", ")": return CSSSelector.Complex(parts: parts)
            default:
                guard hadSpace else { return CSSSelector.Complex(parts: parts) }
                combinator = .descendant
            }
        }
        return CSSSelector.Complex(parts: parts)
    }

    private mutating func parseCompound() throws -> CSSSelector.Compound {
        var compound = CSSSelector.Compound()
        if i < c.count, c[i] == "*" {
            compound.universal = true
            i += 1
        } else if i < c.count, isIdentStart(c[i]), c[i] != "-" || (i + 1 < c.count && isIdentStart(c[i + 1])) {
            compound.tag = try parseIdent().lowercased()
        }
        while i < c.count {
            switch c[i] {
            case "#":
                i += 1
                compound.id = try parseIdent()
            case ".":
                i += 1
                compound.classes.append(try parseIdent())
            case "[":
                compound.attributes.append(try parseAttribute())
            case ":":
                i += 1
                if i < c.count, c[i] == ":" { throw error("Pseudo-elements like ::text belong at the end of an extraction, not in a selector") }
                compound.pseudos.append(try parsePseudo())
            default:
                return compound
            }
        }
        return compound
    }

    private mutating func parseIdent() throws -> String {
        var out = ""
        while i < c.count {
            let ch = c[i]
            if ch == "\\" {
                i += 1
                guard i < c.count else { throw error("A backslash needs something after it") }
                // `\31 ` is a hex escape; anything else is the character itself.
                if c[i].isHexDigit {
                    var hex = ""
                    while i < c.count, c[i].isHexDigit, hex.count < 6 { hex.append(c[i]); i += 1 }
                    if i < c.count, c[i] == " " { i += 1 }
                    out.unicodeScalars.append(UInt32(hex, radix: 16).flatMap { Unicode.Scalar($0) } ?? "\u{FFFD}")
                } else {
                    out.append(c[i])
                    i += 1
                }
            } else if isIdentPart(ch) {
                out.append(ch)
                i += 1
            } else {
                break
            }
        }
        guard !out.isEmpty else { throw error("Expected a name") }
        return out
    }

    private mutating func parseAttribute() throws -> CSSSelector.AttributeCondition {
        i += 1   // [
        skipSpace()
        let name = try parseIdent().lowercased()
        skipSpace()
        guard i < c.count else { throw error("Missing ] to close the attribute") }
        if c[i] == "]" {
            i += 1
            return CSSSelector.AttributeCondition(name: name, op: .exists, value: "", ignoreCase: false)
        }
        let op: CSSSelector.AttributeOperator
        switch c[i] {
        case "=": op = .equals; i += 1
        case "~", "|", "^", "$", "*":
            let symbol = c[i]
            guard i + 1 < c.count, c[i + 1] == "=" else { throw error("Expected = after \"\(symbol)\"") }
            switch symbol {
            case "~": op = .word
            case "|": op = .dash
            case "^": op = .prefix
            case "$": op = .suffix
            default: op = .substring
            }
            i += 2
        default:
            throw error("Expected ] or an operator like = in the attribute")
        }
        skipSpace()
        let value = try parseValue()
        skipSpace()
        var ignoreCase = false
        if i < c.count, c[i] == "i" || c[i] == "I" {
            ignoreCase = true
            i += 1
            skipSpace()
        } else if i < c.count, c[i] == "s" || c[i] == "S" {
            i += 1
            skipSpace()
        }
        guard i < c.count, c[i] == "]" else { throw error("Missing ] to close the attribute") }
        i += 1
        return CSSSelector.AttributeCondition(name: name, op: op, value: value, ignoreCase: ignoreCase)
    }

    /// A quoted string, or a bare word.
    private mutating func parseValue() throws -> String {
        guard i < c.count else { throw error("Expected a value") }
        if c[i] == "\"" || c[i] == "'" {
            let quote = c[i]
            i += 1
            var out = ""
            while i < c.count, c[i] != quote {
                if c[i] == "\\", i + 1 < c.count {
                    i += 1
                }
                out.append(c[i])
                i += 1
            }
            guard i < c.count else { throw error("The quote is never closed") }
            i += 1
            return out
        }
        var out = ""
        while i < c.count, !c[i].isWhitespace, c[i] != "]", c[i] != ")" {
            out.append(c[i])
            i += 1
        }
        guard !out.isEmpty else { throw error("Expected a value") }
        return out
    }

    private mutating func parsePseudo() throws -> CSSSelector.Pseudo {
        let name = try parseIdent().lowercased()
        switch name {
        case "first-child": return .firstChild
        case "last-child": return .lastChild
        case "only-child": return .onlyChild
        case "first-of-type": return .firstOfType
        case "last-of-type": return .lastOfType
        case "only-of-type": return .onlyOfType
        case "empty": return .empty
        case "root": return .root
        case "nth-child": return .nthChild(try parseNth())
        case "nth-last-child": return .nthLastChild(try parseNth())
        case "nth-of-type": return .nthOfType(try parseNth())
        case "nth-last-of-type": return .nthLastOfType(try parseNth())
        case "not":
            try expect("(")
            var compounds: [CSSSelector.Compound] = []
            while true {
                skipSpace()
                let compound = try parseCompound()
                guard !compound.isEmpty else { throw error(":not( needs a selector inside") }
                compounds.append(compound)
                skipSpace()
                if i < c.count, c[i] == "," { i += 1; continue }
                break
            }
            try expect(")")
            return .not(compounds)
        case "has":
            try expect("(")
            let list = try parseList(topLevel: false)
            skipSpace()
            try expect(")")
            return .has(list)
        case "contains":
            try expect("(")
            skipSpace()
            let text = try parseValue()
            skipSpace()
            try expect(")")
            return .contains(text)
        default:
            throw error("\":\(name)\" isn't supported")
        }
    }

    private mutating func expect(_ ch: Character) throws {
        guard i < c.count, c[i] == ch else { throw error("Expected \"\(ch)\"") }
        i += 1
    }

    /// `odd`, `even`, `3`, `2n+1`, `-n+3`, `n`.
    private mutating func parseNth() throws -> CSSSelector.Nth {
        try expect("(")
        var text = ""
        while i < c.count, c[i] != ")" {
            if !c[i].isWhitespace { text.append(c[i]) }
            i += 1
        }
        try expect(")")
        let lower = text.lowercased()
        if lower == "odd" { return CSSSelector.Nth(a: 2, b: 1) }
        if lower == "even" { return CSSSelector.Nth(a: 2, b: 0) }
        guard let nIndex = lower.firstIndex(of: "n") else {
            guard let b = Int(lower) else { throw error("\"\(text)\" isn't a position") }
            return CSSSelector.Nth(a: 0, b: b)
        }
        let aText = String(lower[..<nIndex])
        let bText = String(lower[lower.index(after: nIndex)...])
        let a: Int
        switch aText {
        case "", "+": a = 1
        case "-": a = -1
        default:
            guard let parsed = Int(aText) else { throw error("\"\(text)\" isn't a position") }
            a = parsed
        }
        var b = 0
        if !bText.isEmpty {
            guard let parsed = Int(bText) else { throw error("\"\(text)\" isn't a position") }
            b = parsed
        }
        return CSSSelector.Nth(a: a, b: b)
    }
}
