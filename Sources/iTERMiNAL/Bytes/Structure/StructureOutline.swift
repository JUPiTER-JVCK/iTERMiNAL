import Foundation

/// One line of the Structure tree: a field, or a "show more" line standing for fields
/// that are not listed yet.
struct StructureRow: Identifiable {
    enum Content {
        case node(FieldNode)
        /// More siblings under `parentID` than are listed; how many are not.
        case more(parentID: String, remaining: Int)
    }

    let id: String
    let depth: Int
    let content: Content
    let isExpanded: Bool
}

/// The Structure tree as lines, and how to find a byte's line in it.
///
/// A capture can have a hundred thousand packets at the top, so no level lists more than
/// a page of fields until it is asked to; and a byte far down the list raises the limit
/// just far enough to show it. All of it is plain arithmetic on the tree, so it is checked
/// here and the view only draws the lines.
enum StructureOutline {
    /// How many fields of one level are listed to begin with, and how many more each ask adds.
    static let initialLimit = 500
    static let page = 500
    /// No more lines than this at all, however much is open.
    static let maxRows = 20_000

    /// The lines for `roots`, with the nodes in `expanded` open and no level longer than its
    /// limit in `limits` (keyed by the id of the node whose children they are; "" for the top).
    static func rows(roots: [FieldNode], expanded: Set<String>, limits: [String: Int]) -> [StructureRow] {
        var rows: [StructureRow] = []
        flatten(roots, depth: 0, parentID: "", expanded: expanded, limits: limits, into: &rows)
        return rows
    }

    private static func flatten(_ nodes: [FieldNode], depth: Int, parentID: String, expanded: Set<String>,
                                limits: [String: Int], into rows: inout [StructureRow]) {
        let limit = limits[parentID] ?? initialLimit
        for (index, node) in nodes.enumerated() {
            if rows.count >= maxRows { return }
            if index >= limit {
                rows.append(StructureRow(id: "more:" + parentID, depth: depth,
                                         content: .more(parentID: parentID, remaining: nodes.count - index), isExpanded: false))
                return
            }
            let open = node.isExpandable && expanded.contains(node.id)
            rows.append(StructureRow(id: node.id, depth: depth, content: .node(node), isExpanded: open))
            if open {
                flatten(node.resolvedChildren(), depth: depth + 1, parentID: node.id, expanded: expanded, limits: limits, into: &rows)
            }
        }
    }

    /// What it takes to show the field that holds a byte.
    struct Reveal {
        /// The innermost field holding the byte, if any does.
        var focus: FieldNode?
        /// The fields to open, outermost first, so that `focus` is listed.
        var open: [String]
        /// `limits` with any level raised that was too short to reach `focus`.
        var limits: [String: Int]
    }

    static func reveal(offset: Int64, in roots: [FieldNode], limits: [String: Int]) -> Reveal {
        var chain: [FieldNode] = []
        var level = roots
        var parentID = ""
        var raised = limits
        while chain.count < 64, let index = FieldNode.index(containing: offset, among: level) {
            let limit = raised[parentID] ?? initialLimit
            if index >= limit { raised[parentID] = index + 50 }
            let node = level[index]
            chain.append(node)
            let children = node.resolvedChildren()
            if children.isEmpty { break }
            parentID = node.id
            level = children
        }
        return Reveal(focus: chain.last, open: chain.dropLast().map { $0.id }, limits: raised)
    }

    /// `limits` with the level under `parentID` made one page longer.
    static func showingMore(under parentID: String, limits: [String: Int]) -> [String: Int] {
        var next = limits
        next[parentID] = (limits[parentID] ?? initialLimit) + page
        return next
    }
}

/// A flag one thread sets and another reads: that a parse is no longer wanted.
final class ParseCancellation {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

extension FieldNode {
    /// Where, among siblings in file order, the one holding `offset` is; nil if none does.
    static func index(containing offset: Int64, among siblings: [FieldNode]) -> Int? {
        var low = 0
        var high = siblings.count
        while low < high {
            let middle = (low + high) / 2
            if siblings[middle].offset <= offset { low = middle + 1 } else { high = middle }
        }
        var index = low - 1
        var looked = 0
        while index >= 0, looked < 16 {
            let sibling = siblings[index]
            if offset >= sibling.offset, offset < sibling.end { return index }
            index -= 1
            looked += 1
        }
        return nil
    }
}
