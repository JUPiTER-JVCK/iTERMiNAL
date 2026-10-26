import Foundation

struct XPathError: LocalizedError, Equatable {
    let message: String
    let position: Int
    var errorDescription: String? { "\(message) (at character \(position + 1))" }
}

/// One thing an XPath found: an element, or a piece of text (a `text()` node or
/// an `@attribute` value).
enum XPathValue {
    case node(HTMLNode)
    case text(String)
}

/// The part of XPath 1.0 that scraping uses.
///
/// - Paths: `/html/body`, `//a`, `a/b`, `.`, `..`, `*`, `@href`, `text()`, `node()`
/// - Predicates: `[2]`, `[last()]`, `[@class]`, `[@class='x']`, `[@a!='b']`,
///   `[contains(@class,'x')]`, `[starts-with(@href,'/')]`, `[ends-with(...)]`,
///   `[text()='Home']`, `[normalize-space()='Home']`, `[not(@hidden)]`,
///   `[position()<3]`, `[price>10]`, with `and`, `or` and parentheses
/// - Functions: `contains`, `starts-with`, `ends-with`, `not`, `normalize-space`,
///   `string-length`, `count`, `position`, `last`
///
/// Not here: other axes (`following-sibling::` and the like), unions with `|`,
/// variables, and the rest of the function library. Element and attribute names
/// are matched without regard to case, as the trees it runs on are lower-cased.
struct XPath {
    fileprivate enum Axis { case child, parent, selfNode, attribute }
    fileprivate enum Test { case name(String), any, text, node }

    fileprivate struct Step {
        var descendants = false
        var axis: Axis = .child
        var test: Test = .any
        var predicates: [Expr] = []
    }

    fileprivate indirect enum Expr {
        case number(Double)
        case string(String)
        case path(absolute: Bool, steps: [Step])
        case call(String, [Expr])
        case compare(Expr, String, Expr)
        case and(Expr, Expr)
        case or(Expr, Expr)
    }

    fileprivate let steps: [Step]
    fileprivate let absolute: Bool

    static func parse(_ text: String) throws -> XPath {
        var parser = Parser(Array(text))
        let (absolute, steps) = try parser.parseTopLevel()
        return XPath(steps: steps, absolute: absolute)
    }

    /// What the path selects, starting from `root` (the document, or an element
    /// to search below).
    func evaluate(from root: HTMLNode, limit: Int = 5_000) -> [XPathValue] {
        var evaluator = Evaluator(document: root)
        let results = evaluator.run(steps: steps, absolute: absolute, context: [.node(root)])
        return Array(results.prefix(limit))
    }

    // MARK: Evaluating

    private struct Evaluator {
        let document: HTMLNode

        enum Value {
            case string(String)
            case number(Double)
            case bool(Bool)
            case set([XPathValue])
        }

        init(document: HTMLNode) { self.document = document }

        mutating func run(steps: [Step], absolute: Bool, context: [XPathValue]) -> [XPathValue] {
            var current: [XPathValue] = absolute ? [.node(root(of: context))] : context
            for step in steps {
                var next: [XPathValue] = []
                var seen = Set<ObjectIdentifier>()
                for item in current {
                    guard case .node(let node) = item else { continue }
                    let origins: [HTMLNode] = step.descendants ? descendantsOrSelf(node) : [node]
                    for origin in origins {
                        var found = candidates(of: origin, step: step)
                        for predicate in step.predicates {
                            found = filter(found, by: predicate)
                        }
                        for candidate in found {
                            if case .node(let found) = candidate {
                                guard seen.insert(ObjectIdentifier(found)).inserted else { continue }
                            }
                            next.append(candidate)
                        }
                    }
                }
                current = next
                if current.isEmpty { break }
            }
            return current
        }

        private func root(of context: [XPathValue]) -> HTMLNode {
            guard case .node(var node)? = context.first else { return document }
            while let parent = node.parent { node = parent }
            return node
        }

        private func descendantsOrSelf(_ node: HTMLNode) -> [HTMLNode] {
            var out = [node]
            out.append(contentsOf: node.descendantElements())
            return out
        }

        private func candidates(of node: HTMLNode, step: Step) -> [XPathValue] {
            switch step.axis {
            case .selfNode:
                return [.node(node)]
            case .parent:
                return node.parent.map { [.node($0)] } ?? []
            case .attribute:
                switch step.test {
                case .name(let name): return node.attribute(name).map { [.text($0)] } ?? []
                default: return node.attributes.map { .text($0.value) }
                }
            case .child:
                var out: [XPathValue] = []
                for child in node.children {
                    switch (step.test, child.kind) {
                    case (.name(let name), .element) where child.tag == name: out.append(.node(child))
                    case (.any, .element): out.append(.node(child))
                    case (.text, .text): out.append(.text(child.text))
                    case (.node, .element), (.node, .text): out.append(child.kind == .text ? .text(child.text) : .node(child))
                    default: break
                    }
                }
                return out
            }
        }

        private mutating func filter(_ items: [XPathValue], by predicate: Expr) -> [XPathValue] {
            var kept: [XPathValue] = []
            for (index, item) in items.enumerated() {
                let value = evaluate(predicate, item: item, position: index + 1, size: items.count)
                switch value {
                case .number(let number): if Int(exactly: number) == index + 1 { kept.append(item) }
                default: if truth(value) { kept.append(item) }
                }
            }
            return kept
        }

        private func truth(_ value: Value) -> Bool {
            switch value {
            case .bool(let flag): return flag
            case .number(let number): return number != 0
            case .string(let text): return !text.isEmpty
            case .set(let items): return !items.isEmpty
            }
        }

        private func string(of value: Value) -> String {
            switch value {
            case .string(let text): return text
            case .number(let number): return number == number.rounded() && abs(number) < 1e15 ? String(Int(number)) : String(number)
            case .bool(let flag): return flag ? "true" : "false"
            case .set(let items): return items.first.map(string(of:)) ?? ""
            }
        }

        private func string(of item: XPathValue) -> String {
            switch item {
            case .text(let text): return text
            case .node(let node): return node.rawText()
            }
        }

        private func number(of value: Value) -> Double? {
            switch value {
            case .number(let number): return number
            case .bool(let flag): return flag ? 1 : 0
            case .string, .set: return Double(string(of: value).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        private mutating func evaluate(_ expr: Expr, item: XPathValue, position: Int, size: Int) -> Value {
            switch expr {
            case .number(let number): return .number(number)
            case .string(let text): return .string(text)
            case .path(let absolute, let steps):
                return .set(run(steps: steps, absolute: absolute, context: [item]))
            case .and(let lhs, let rhs):
                return .bool(truth(evaluate(lhs, item: item, position: position, size: size)) && truth(evaluate(rhs, item: item, position: position, size: size)))
            case .or(let lhs, let rhs):
                return .bool(truth(evaluate(lhs, item: item, position: position, size: size)) || truth(evaluate(rhs, item: item, position: position, size: size)))
            case .compare(let lhs, let op, let rhs):
                return .bool(compare(evaluate(lhs, item: item, position: position, size: size), op, evaluate(rhs, item: item, position: position, size: size)))
            case .call(let name, let args):
                func arg(_ index: Int) -> Value {
                    guard index < args.count else { return .string(string(of: item)) }
                    return evaluate(args[index], item: item, position: position, size: size)
                }
                switch name {
                case "position": return .number(Double(position))
                case "last": return .number(Double(size))
                case "not": return .bool(!truth(arg(0)))
                case "true": return .bool(true)
                case "false": return .bool(false)
                case "contains": return .bool(string(of: arg(0)).contains(string(of: arg(1))))
                case "starts-with": return .bool(string(of: arg(0)).hasPrefix(string(of: arg(1))))
                case "ends-with": return .bool(string(of: arg(0)).hasSuffix(string(of: arg(1))))
                case "normalize-space": return .string(HTMLNode.collapseWhitespace(string(of: arg(0))))
                case "string-length": return .number(Double(string(of: arg(0)).count))
                case "string": return .string(string(of: arg(0)))
                case "count":
                    if case .set(let items) = arg(0) { return .number(Double(items.count)) }
                    return .number(0)
                default: return .bool(false)
                }
            }
        }

        private func compare(_ lhs: Value, _ op: String, _ rhs: Value) -> Bool {
            // A node-set compares as true if any member does.
            if case .set(let items) = lhs {
                return items.contains { compare(.string(string(of: $0)), op, rhs) }
            }
            if case .set(let items) = rhs {
                return items.contains { compare(lhs, op, .string(string(of: $0))) }
            }
            // Numbers when either side is one, text otherwise.
            var isNumeric = false
            if case .number = lhs { isNumeric = true }
            if case .number = rhs { isNumeric = true }
            if isNumeric || ["<", "<=", ">", ">="].contains(op) {
                guard let a = number(of: lhs), let b = number(of: rhs) else { return op == "!=" }
                switch op {
                case "=": return a == b
                case "!=": return a != b
                case "<": return a < b
                case "<=": return a <= b
                case ">": return a > b
                default: return a >= b
                }
            }
            let a = string(of: lhs)
            let b = string(of: rhs)
            return op == "=" ? a == b : a != b
        }
    }

    // MARK: Reading a path

    fileprivate struct Parser {
        private let c: [Character]
        private var i = 0

        init(_ characters: [Character]) { c = characters }

        private func error(_ message: String) -> XPathError { XPathError(message: message, position: min(i, c.count)) }
        private mutating func skipSpace() { while i < c.count, c[i].isWhitespace { i += 1 } }

        mutating func parseTopLevel() throws -> (Bool, [Step]) {
            skipSpace()
            let result = try parsePath()
            skipSpace()
            if i < c.count { throw error("Unexpected \"\(c[i])\"") }
            guard !result.1.isEmpty || result.0 else { throw error("The path is empty") }
            return result
        }

        /// A path, absolute or relative, and where it stopped.
        private mutating func parsePath() throws -> (Bool, [Step]) {
            var absolute = false
            var steps: [Step] = []
            var nextDescendants = false
            if i < c.count, c[i] == "/" {
                absolute = true
                i += 1
                if i < c.count, c[i] == "/" { nextDescendants = true; i += 1 }
            }
            while true {
                skipSpace()
                guard i < c.count, c[i] != "]", c[i] != ")", c[i] != "," else {
                    if absolute, steps.isEmpty, !nextDescendants { return (true, []) }
                    throw error("The path ends where a step was expected")
                }
                var step = try parseStep()
                step.descendants = nextDescendants
                nextDescendants = false
                steps.append(step)
                skipSpace()
                guard i < c.count, c[i] == "/" else { break }
                i += 1
                if i < c.count, c[i] == "/" { nextDescendants = true; i += 1 }
            }
            return (absolute, steps)
        }

        private mutating func parseStep() throws -> Step {
            var step = Step()
            if matches("..") { i += 2; step.axis = .parent; step.test = .node; return step }
            if i < c.count, c[i] == "." { i += 1; step.axis = .selfNode; step.test = .node; return try withPredicates(step) }
            if i < c.count, c[i] == "@" {
                i += 1
                step.axis = .attribute
                if i < c.count, c[i] == "*" { i += 1; step.test = .any } else { step.test = .name(try parseName().lowercased()) }
                return step
            }
            if i < c.count, c[i] == "*" {
                i += 1
                step.test = .any
                return try withPredicates(step)
            }
            let name = try parseName()
            if i < c.count, c[i] == "(" {
                // text() and node() are tests; anything else here is a function call
                // used as a step, which this does not support.
                i += 1
                skipSpace()
                guard i < c.count, c[i] == ")" else { throw error("\(name)( takes nothing here") }
                i += 1
                switch name.lowercased() {
                case "text": step.test = .text
                case "node": step.test = .node
                default: throw error("\(name)() can't be used as a step")
                }
            } else {
                step.test = .name(name.lowercased())
            }
            return try withPredicates(step)
        }

        private mutating func withPredicates(_ start: Step) throws -> Step {
            var step = start
            while true {
                skipSpace()
                guard i < c.count, c[i] == "[" else { return step }
                i += 1
                step.predicates.append(try parseOr())
                skipSpace()
                guard i < c.count, c[i] == "]" else { throw error("Missing ]") }
                i += 1
            }
        }

        private mutating func parseName() throws -> String {
            var name = ""
            while i < c.count, c[i].isLetter || c[i].isNumber || c[i] == "_" || c[i] == "-" || c[i] == ":" || c[i] == "." && !name.isEmpty {
                name.append(c[i])
                i += 1
            }
            guard !name.isEmpty else { throw error(i < c.count ? "Unexpected \"\(c[i])\"" : "Expected a name") }
            return name
        }

        private func matches(_ text: String) -> Bool {
            let chars = Array(text)
            guard i + chars.count <= c.count else { return false }
            return Array(c[i..<(i + chars.count)]) == chars
        }

        private mutating func matchesWord(_ word: String) -> Bool {
            skipSpace()
            guard matches(word) else { return false }
            let end = i + word.count
            // A word, not the start of a name: `or` and not `order`.
            if end < c.count, c[end].isLetter || c[end].isNumber || c[end] == "_" || c[end] == "-" { return false }
            return true
        }

        private mutating func parseOr() throws -> Expr {
            var left = try parseAnd()
            while matchesWord("or") {
                i += 2
                left = .or(left, try parseAnd())
            }
            return left
        }

        private mutating func parseAnd() throws -> Expr {
            var left = try parseComparison()
            while matchesWord("and") {
                i += 3
                left = .and(left, try parseComparison())
            }
            return left
        }

        private mutating func parseComparison() throws -> Expr {
            let left = try parsePrimary()
            skipSpace()
            for op in ["!=", "<=", ">=", "=", "<", ">"] where matches(op) {
                i += op.count
                return .compare(left, op, try parsePrimary())
            }
            return left
        }

        private mutating func parsePrimary() throws -> Expr {
            skipSpace()
            guard i < c.count else { throw error("The expression ends where a value was expected") }
            if c[i] == "(" {
                i += 1
                let inner = try parseOr()
                skipSpace()
                guard i < c.count, c[i] == ")" else { throw error("Missing )") }
                i += 1
                return inner
            }
            if c[i] == "'" || c[i] == "\"" {
                let quote = c[i]
                i += 1
                var text = ""
                while i < c.count, c[i] != quote { text.append(c[i]); i += 1 }
                guard i < c.count else { throw error("The quote is never closed") }
                i += 1
                return .string(text)
            }
            if c[i].isNumber || (c[i] == "-" && i + 1 < c.count && c[i + 1].isNumber) {
                var digits = String(c[i])
                i += 1
                while i < c.count, c[i].isNumber || c[i] == "." { digits.append(c[i]); i += 1 }
                guard let number = Double(digits) else { throw error("\"\(digits)\" is not a number") }
                return .number(number)
            }
            // A function call, or a path.
            let start = i
            if c[i].isLetter, let name = try? parseName(), i < c.count, c[i] == "(", !["text", "node"].contains(name.lowercased()) {
                i += 1
                var args: [Expr] = []
                skipSpace()
                if i < c.count, c[i] == ")" {
                    i += 1
                } else {
                    while true {
                        args.append(try parseOr())
                        skipSpace()
                        guard i < c.count else { throw error("Missing ) after the arguments") }
                        if c[i] == "," { i += 1; continue }
                        if c[i] == ")" { i += 1; break }
                        throw error("Expected , or )")
                    }
                }
                return .call(name.lowercased(), args)
            }
            i = start
            let (absolute, steps) = try parsePath()
            return .path(absolute: absolute, steps: steps)
        }
    }
}
