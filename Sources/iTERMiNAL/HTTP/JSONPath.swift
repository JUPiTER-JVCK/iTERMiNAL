import Foundation

struct JSONPathError: LocalizedError, Equatable {
    let message: String
    let position: Int
    var errorDescription: String? { "\(message) (at character \(position + 1))" }
}

/// JSONPath over a `JSONValue`: the part of it people use to pull things out of
/// an API response.
///
/// - `$` the root (optional: `data.items` means `$.data.items`)
/// - `.name`, `['name']`, `["name"]` — a member; `.*` and `[*]` — every child
/// - `[0]`, `[-1]` — an item, counting from the end if negative
/// - `[1:4]`, `[::2]` — a slice, as in Python
/// - `[0,2]`, `['a','b']` — several at once
/// - `..name`, `..*`, `..[0]` — at any depth
/// - `[?(@.price < 10 && @.stock)]` — items for which a test holds: `@` is the
///   item, `==` `!=` `<` `<=` `>` `>=` compare, `&&` `||` `!` and parentheses
///   combine, and a bare `@.field` means "has it"
///
/// Not here: functions like `length()` and `match()`, and script expressions.
struct JSONPath {
    struct Match: Equatable {
        /// Where it was found, written as a path that finds it again.
        let path: String
        let value: JSONValue
    }

    fileprivate indirect enum Filter {
        case exists(Operand)
        case compare(Operand, String, Operand)
        case and(Filter, Filter)
        case or(Filter, Filter)
        case not(Filter)
    }

    fileprivate enum Operand {
        /// `@`, then names and indexes.
        case relative([Step])
        case literal(JSONValue)
    }

    fileprivate enum Step {
        case name(String)
        case index(Int)
    }

    fileprivate indirect enum Selector {
        case name(String)
        case index(Int)
        case wildcard
        case slice(Int?, Int?, Int?)
        case union([Selector])
        case filter(Filter)
    }

    fileprivate struct Segment {
        let recursive: Bool
        let selector: Selector
    }

    fileprivate let segments: [Segment]

    static func parse(_ text: String) throws -> JSONPath {
        var parser = PathParser(Array(text))
        return JSONPath(segments: try parser.parsePath())
    }

    /// Everything the path selects, in document order.
    func evaluate(_ root: JSONValue, limit: Int = 5_000) -> [Match] {
        var current = [Match(path: "$", value: root)]
        for segment in segments {
            var next: [Match] = []
            for match in current {
                let candidates = segment.recursive ? Self.descendantsAndSelf(of: match) : [match]
                for candidate in candidates {
                    Self.apply(segment.selector, to: candidate, into: &next)
                    if next.count >= limit { break }
                }
                if next.count >= limit { break }
            }
            current = next
            if current.isEmpty { break }
        }
        return Array(current.prefix(limit))
    }

    // MARK: Walking

    private static func descendantsAndSelf(of match: Match) -> [Match] {
        var out: [Match] = []
        var stack = [match]
        // Pre-order, children left to right.
        while let node = stack.popLast() {
            out.append(node)
            if out.count > 200_000 { break }
            switch node.value {
            case .object(let members):
                for member in members.reversed() { stack.append(Match(path: node.path + key(member.key), value: member.value)) }
            case .array(let items):
                for (index, item) in items.enumerated().reversed() { stack.append(Match(path: node.path + "[\(index)]", value: item)) }
            default:
                break
            }
        }
        return out
    }

    private static func key(_ name: String) -> String {
        let simple = name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
        return simple ? "." + name : "['" + name.replacingOccurrences(of: "'", with: "\\'") + "']"
    }

    private static func children(of match: Match) -> [Match] {
        switch match.value {
        case .object(let members): return members.map { Match(path: match.path + key($0.key), value: $0.value) }
        case .array(let items): return items.enumerated().map { Match(path: match.path + "[\($0.offset)]", value: $0.element) }
        default: return []
        }
    }

    private static func apply(_ selector: Selector, to match: Match, into out: inout [Match]) {
        switch selector {
        case .name(let name):
            if case .object(let members) = match.value, let member = members.first(where: { $0.key == name }) {
                out.append(Match(path: match.path + key(name), value: member.value))
            }
        case .index(let index):
            if case .array(let items) = match.value {
                let resolved = index < 0 ? items.count + index : index
                if items.indices.contains(resolved) { out.append(Match(path: match.path + "[\(resolved)]", value: items[resolved])) }
            }
        case .wildcard:
            out.append(contentsOf: children(of: match))
        case .slice(let start, let end, let step):
            guard case .array(let items) = match.value else { return }
            for index in sliceIndices(count: items.count, start: start, end: end, step: step ?? 1) {
                out.append(Match(path: match.path + "[\(index)]", value: items[index]))
            }
        case .union(let selectors):
            for inner in selectors { apply(inner, to: match, into: &out) }
        case .filter(let filter):
            for child in children(of: match) where holds(filter, for: child.value) { out.append(child) }
        }
    }

    /// Python's slice rules: negative bounds count from the end, a negative
    /// step walks backwards, out-of-range bounds are clamped.
    static func sliceIndices(count: Int, start: Int?, end: Int?, step: Int) -> [Int] {
        guard step != 0, count > 0 else { return [] }
        func clamp(_ value: Int, low: Int, high: Int) -> Int { max(low, min(high, value)) }
        var result: [Int] = []
        if step > 0 {
            var first = start.map { $0 < 0 ? $0 + count : $0 } ?? 0
            var last = end.map { $0 < 0 ? $0 + count : $0 } ?? count
            first = clamp(first, low: 0, high: count)
            last = clamp(last, low: 0, high: count)
            var index = first
            while index < last { result.append(index); index += step }
        } else {
            var first = start.map { $0 < 0 ? $0 + count : $0 } ?? count - 1
            var last = end.map { $0 < 0 ? $0 + count : $0 } ?? -1
            first = clamp(first, low: -1, high: count - 1)
            last = clamp(last, low: -1, high: count - 1)
            var index = first
            while index > last { result.append(index); index += step }
        }
        return result
    }

    // MARK: Filters

    private static func holds(_ filter: Filter, for item: JSONValue) -> Bool {
        switch filter {
        case .and(let lhs, let rhs): return holds(lhs, for: item) && holds(rhs, for: item)
        case .or(let lhs, let rhs): return holds(lhs, for: item) || holds(rhs, for: item)
        case .not(let inner): return !holds(inner, for: item)
        case .exists(let operand): return value(of: operand, in: item) != nil
        case .compare(let lhs, let op, let rhs):
            guard let left = value(of: lhs, in: item), let right = value(of: rhs, in: item) else {
                // A missing field equals nothing — except that it is not equal to anything.
                return op == "!="
            }
            return compare(left, op, right)
        }
    }

    private static func value(of operand: Operand, in item: JSONValue) -> JSONValue? {
        switch operand {
        case .literal(let value): return value
        case .relative(let steps):
            var current = item
            for step in steps {
                switch (step, current) {
                case (.name(let name), .object(let members)):
                    guard let member = members.first(where: { $0.key == name }) else { return nil }
                    current = member.value
                case (.index(let index), .array(let items)):
                    let resolved = index < 0 ? items.count + index : index
                    guard items.indices.contains(resolved) else { return nil }
                    current = items[resolved]
                default:
                    return nil
                }
            }
            return current
        }
    }

    private static func compare(_ lhs: JSONValue, _ op: String, _ rhs: JSONValue) -> Bool {
        func ordered<T: Comparable>(_ a: T, _ b: T) -> Bool {
            switch op {
            case "==": return a == b
            case "!=": return a != b
            case "<": return a < b
            case "<=": return a <= b
            case ">": return a > b
            case ">=": return a >= b
            default: return false
            }
        }
        switch (lhs, rhs) {
        case (.number(let a), .number(let b)):
            guard let x = Double(a), let y = Double(b) else { return false }
            return ordered(x, y)
        case (.string(let a), .string(let b)): return ordered(a, b)
        case (.bool(let a), .bool(let b)): return op == "==" ? a == b : op == "!=" ? a != b : false
        case (.null, .null): return op == "==" || op == "<=" || op == ">="
        default: return op == "!="
        }
    }

    // MARK: Reading a path

    fileprivate struct PathParser {
        private let c: [Character]
        private var i = 0

        init(_ characters: [Character]) { c = characters }

        private func error(_ message: String) -> JSONPathError { JSONPathError(message: message, position: min(i, c.count)) }
        private var atEnd: Bool { i >= c.count }
        private mutating func skipSpace() { while i < c.count, c[i].isWhitespace { i += 1 } }

        mutating func parsePath() throws -> [Segment] {
            skipSpace()
            var segments: [Segment] = []
            if i < c.count, c[i] == "$" { i += 1 }
            // `data.items`, with no leading `$.`, is a path from the root.
            else if i < c.count, c[i] != ".", c[i] != "[" { segments.append(Segment(recursive: false, selector: try parseDotName())) }
            while true {
                skipSpace()
                guard i < c.count else { break }
                if c[i] == "." {
                    i += 1
                    var recursive = false
                    if i < c.count, c[i] == "." { recursive = true; i += 1 }
                    if i < c.count, c[i] == "[" {
                        guard recursive else { throw error("Expected a name after \".\"") }
                        segments.append(Segment(recursive: true, selector: try parseBracket()))
                    } else {
                        segments.append(Segment(recursive: recursive, selector: try parseDotName()))
                    }
                } else if c[i] == "[" {
                    segments.append(Segment(recursive: false, selector: try parseBracket()))
                } else {
                    throw error("Unexpected \"\(c[i])\"")
                }
            }
            return segments
        }

        private mutating func parseDotName() throws -> Selector {
            if i < c.count, c[i] == "*" { i += 1; return .wildcard }
            var name = ""
            while i < c.count, !".[ ]".contains(c[i]) { name.append(c[i]); i += 1 }
            guard !name.isEmpty else { throw error("Expected a name") }
            return .name(name)
        }

        private mutating func parseBracket() throws -> Selector {
            i += 1   // [
            skipSpace()
            guard i < c.count else { throw error("Missing ]") }
            if c[i] == "?" {
                i += 1
                skipSpace()
                guard i < c.count, c[i] == "(" else { throw error("A filter looks like [?(@.field > 1)]") }
                i += 1
                let filter = try parseOr()
                skipSpace()
                guard i < c.count, c[i] == ")" else { throw error("Missing ) in the filter") }
                i += 1
                skipSpace()
                guard i < c.count, c[i] == "]" else { throw error("Missing ]") }
                i += 1
                return .filter(filter)
            }
            var selectors: [Selector] = []
            while true {
                skipSpace()
                selectors.append(try parseBracketItem())
                skipSpace()
                guard i < c.count else { throw error("Missing ]") }
                if c[i] == "," { i += 1; continue }
                if c[i] == "]" { i += 1; break }
                throw error("Expected , or ]")
            }
            return selectors.count == 1 ? selectors[0] : .union(selectors)
        }

        private mutating func parseBracketItem() throws -> Selector {
            guard i < c.count else { throw error("Missing ]") }
            if c[i] == "*" { i += 1; return .wildcard }
            if c[i] == "'" || c[i] == "\"" { return .name(try parseQuoted()) }
            // A number, or a slice made of up to three.
            var parts: [Int?] = []
            var current = ""
            var colons = 0
            while i < c.count, c[i] != "," && c[i] != "]" {
                if c[i] == ":" {
                    colons += 1
                    parts.append(current.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Int(current.trimmingCharacters(in: .whitespaces)))
                    if parts.last! == nil, !current.trimmingCharacters(in: .whitespaces).isEmpty { throw error("\"\(current)\" is not a number") }
                    current = ""
                } else {
                    current.append(c[i])
                }
                i += 1
            }
            let last = current.trimmingCharacters(in: .whitespaces)
            if colons == 0 {
                guard let index = Int(last) else { throw error("\"\(last)\" is not an index or a name") }
                return .index(index)
            }
            if last.isEmpty { parts.append(nil) } else {
                guard let number = Int(last) else { throw error("\"\(last)\" is not a number") }
                parts.append(number)
            }
            guard parts.count <= 3 else { throw error("A slice has at most three parts") }
            return .slice(parts[0], parts.count > 1 ? parts[1] : nil, parts.count > 2 ? parts[2] : nil)
        }

        private mutating func parseQuoted() throws -> String {
            let quote = c[i]
            i += 1
            var out = ""
            while i < c.count, c[i] != quote {
                if c[i] == "\\", i + 1 < c.count { i += 1 }
                out.append(c[i])
                i += 1
            }
            guard i < c.count else { throw error("The quote is never closed") }
            i += 1
            return out
        }

        // MARK: Filter expressions

        private mutating func parseOr() throws -> Filter {
            var left = try parseAnd()
            while true {
                skipSpace()
                guard i + 1 < c.count, c[i] == "|", c[i + 1] == "|" else { return left }
                i += 2
                left = .or(left, try parseAnd())
            }
        }

        private mutating func parseAnd() throws -> Filter {
            var left = try parseNot()
            while true {
                skipSpace()
                guard i + 1 < c.count, c[i] == "&", c[i + 1] == "&" else { return left }
                i += 2
                left = .and(left, try parseNot())
            }
        }

        private mutating func parseNot() throws -> Filter {
            skipSpace()
            if i < c.count, c[i] == "!", !(i + 1 < c.count && c[i + 1] == "=") {
                i += 1
                return .not(try parseNot())
            }
            return try parseComparison()
        }

        private mutating func parseComparison() throws -> Filter {
            skipSpace()
            if i < c.count, c[i] == "(" {
                i += 1
                let inner = try parseOr()
                skipSpace()
                guard i < c.count, c[i] == ")" else { throw error("Missing )") }
                i += 1
                return inner
            }
            let left = try parseOperand()
            skipSpace()
            for op in ["==", "!=", "<=", ">=", "<", ">"] where matches(op) {
                i += op.count
                skipSpace()
                return .compare(left, op, try parseOperand())
            }
            return .exists(left)
        }

        private func matches(_ text: String) -> Bool {
            let chars = Array(text)
            guard i + chars.count <= c.count else { return false }
            return Array(c[i..<(i + chars.count)]) == chars
        }

        private mutating func parseOperand() throws -> Operand {
            skipSpace()
            guard i < c.count else { throw error("The filter ends where a value was expected") }
            if c[i] == "@" {
                i += 1
                var steps: [Step] = []
                while i < c.count {
                    if c[i] == "." {
                        i += 1
                        var name = ""
                        while i < c.count, !" .[]()=!<>&|".contains(c[i]) { name.append(c[i]); i += 1 }
                        guard !name.isEmpty else { throw error("Expected a field name after \".\"") }
                        steps.append(.name(name))
                    } else if c[i] == "[" {
                        i += 1
                        if i < c.count, c[i] == "'" || c[i] == "\"" {
                            steps.append(.name(try parseQuoted()))
                        } else {
                            var digits = ""
                            while i < c.count, c[i] != "]" { digits.append(c[i]); i += 1 }
                            guard let index = Int(digits.trimmingCharacters(in: .whitespaces)) else { throw error("Expected an index") }
                            steps.append(.index(index))
                        }
                        guard i < c.count, c[i] == "]" else { throw error("Missing ]") }
                        i += 1
                    } else {
                        break
                    }
                }
                return .relative(steps)
            }
            if c[i] == "'" || c[i] == "\"" { return .literal(.string(try parseQuoted())) }
            var word = ""
            while i < c.count, !" )&|=!<>".contains(c[i]) { word.append(c[i]); i += 1 }
            switch word {
            case "true": return .literal(.bool(true))
            case "false": return .literal(.bool(false))
            case "null": return .literal(.null)
            default:
                guard Double(word) != nil else { throw error("\"\(word)\" is not a value — quote text, or start a field with @") }
                return .literal(.number(word))
            }
        }
    }
}
