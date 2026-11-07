import Foundation

// How the right-hand region arranges its panels: a tree of splits whose leaves
// are panels. Foundation only, so every rule here — where a newcomer lands, what
// a removal gives back, how a saved layout is repaired — is checked off a Mac by
// scripts/input-logic-check. `DockGeometry.swift` adds sizes on top of this.
//
// Leaves are plain strings (a `SidePanel` raw value) rather than `SidePanel`
// itself, which lives beside the store and imports SwiftUI.

typealias DockModuleID = String

/// Which way a split lays its children out.
enum DockAxis: String, Codable, Equatable {
    /// Left to right.
    case horizontal
    /// Top to bottom.
    case vertical
}

/// A side of a panel, or of the whole region.
enum DockEdge: String, Codable, CaseIterable, Equatable {
    case left, right, top, bottom

    /// The axis a panel placed on this edge is laid out along.
    var axis: DockAxis {
        switch self {
        case .left, .right: return .horizontal
        case .top, .bottom: return .vertical
        }
    }

    /// True when a newcomer goes before what it is placed beside.
    var leads: Bool { self == .left || self == .top }
}

/// One slot of a split: how much of it the child takes, and the child.
///
/// Weight and node travel together so a split cannot end up with more weights
/// than children, which two parallel arrays would allow.
struct DockChild: Codable, Equatable {
    var weight: Double
    var node: DockNode
}

indirect enum DockNode: Equatable {
    case leaf(DockModuleID)
    case split(DockAxis, [DockChild])

    /// Every panel in the tree, in reading order — left to right, top to bottom.
    var modules: [DockModuleID] {
        switch self {
        case .leaf(let id):
            return [id]
        case .split(_, let children):
            return children.flatMap { $0.node.modules }
        }
    }

    func contains(_ module: DockModuleID) -> Bool {
        modules.contains(module)
    }
}

/// Written by hand rather than synthesized: the synthesized form of an enum with
/// associated values is `{"leaf":{"_0":"files"}}`, which is a poor thing to keep
/// in a file that outlives the build that wrote it.
///
///     {"module": "files"}
///     {"axis": "horizontal", "children": [{"weight": 0.5, "node": {...}}, ...]}
extension DockNode: Codable {
    private enum CodingKeys: String, CodingKey {
        case module, axis, children
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let module = try container.decodeIfPresent(String.self, forKey: .module) {
            self = .leaf(module)
            return
        }
        let axis = try container.decode(DockAxis.self, forKey: .axis)
        let children = try container.decode([DockChild].self, forKey: .children)
        self = .split(axis, children)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let module):
            try container.encode(module, forKey: .module)
        case .split(let axis, let children):
            try container.encode(axis, forKey: .axis)
            try container.encode(children, forKey: .children)
        }
    }
}

/// The layout as it sits inside the saved state.
///
/// Decoding never fails. The state file is read all-or-nothing — one field that
/// will not decode discards every workspace — so a layout that is malformed, or
/// was written by a newer build, must come back as "no layout" and let the
/// caller rebuild one, rather than take the user's tabs with it.
struct DockLayoutField: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var root: DockNode?

    init(root: DockNode?) {
        self.version = DockLayoutField.currentVersion
        self.root = root
    }

    private enum CodingKeys: String, CodingKey {
        case version, root
    }

    init(from decoder: Decoder) throws {
        var decodedVersion = DockLayoutField.currentVersion
        var decodedRoot: DockNode?
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            decodedVersion = (try? container.decode(Int.self, forKey: .version)) ?? DockLayoutField.currentVersion
            decodedRoot = try? container.decode(DockNode.self, forKey: .root)
        }
        // A layout from a newer version may mean something this build does not
        // know; better none than a misread one.
        if decodedVersion > DockLayoutField.currentVersion { decodedRoot = nil }
        self.version = decodedVersion
        self.root = decodedRoot
    }
}

/// The operations on a layout. Every one takes a tree (or nothing) and returns a
/// tree in normal form, and none of them traps on input that does not fit: a
/// module that is not there, or is already there, leaves the tree as it was.
enum DockLayout {

    // MARK: Normal form

    /// The tree with its invariants restored:
    ///
    /// - a split has at least two children (a lone child takes the split's place);
    /// - a split's children are never splits along the same axis (they are folded
    ///   in, their weights scaled by the slot they occupied);
    /// - weights are positive and sum to 1;
    /// - a module appears once, and none is named "".
    ///
    /// Applying it twice changes nothing more. Everything below ends here, which
    /// is what lets a hand-edited or half-migrated file through safely.
    static func normalized(_ root: DockNode?) -> DockNode? {
        guard let root else { return nil }
        var seen = Set<DockModuleID>()
        return clean(root, seen: &seen)
    }

    private static func clean(_ node: DockNode, seen: inout Set<DockModuleID>) -> DockNode? {
        switch node {
        case .leaf(let id):
            guard !id.isEmpty, !seen.contains(id) else { return nil }
            seen.insert(id)
            return node

        case .split(let axis, let children):
            var kept: [(weight: Double?, node: DockNode)] = []
            for child in children {
                guard let cleaned = clean(child.node, seen: &seen) else { continue }
                let usable = child.weight.isFinite && child.weight > 0
                kept.append((weight: usable ? child.weight : nil, node: cleaned))
            }
            guard !kept.isEmpty else { return nil }
            if kept.count == 1 { return kept[0].node }

            let weights = resolvedWeights(kept.map { $0.weight })
            var result: [DockChild] = []
            for (index, entry) in kept.enumerated() {
                if case .split(let innerAxis, let inner) = entry.node, innerAxis == axis {
                    // `inner` is already in normal form, so its weights sum to 1
                    // and scaling them by the slot keeps the total.
                    for grandchild in inner {
                        result.append(DockChild(weight: weights[index] * grandchild.weight, node: grandchild.node))
                    }
                } else {
                    result.append(DockChild(weight: weights[index], node: entry.node))
                }
            }
            return .split(axis, result)
        }
    }

    /// Weights that sum to 1. A weight that was unusable (missing, zero, negative,
    /// not a number) takes the average of those that were, so a damaged entry
    /// reads as "an ordinary share" rather than collapsing or swallowing the rest.
    private static func resolvedWeights(_ raw: [Double?]) -> [Double] {
        let valid = raw.compactMap { $0 }
        let fill = valid.isEmpty ? 1.0 : valid.reduce(0, +) / Double(valid.count)
        let filled = raw.map { $0 ?? fill }
        let total = filled.reduce(0, +)
        guard total.isFinite, total > 0 else {
            return Array(repeating: 1.0 / Double(max(raw.count, 1)), count: raw.count)
        }
        return filled.map { $0 / total }
    }

    private static func unique(_ ids: [DockModuleID]) -> [DockModuleID] {
        var seen = Set<DockModuleID>()
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: Building

    /// `ids` in one line, sharing the space equally.
    static func stacked(_ ids: [DockModuleID], axis: DockAxis = .vertical) -> DockNode? {
        let kept = unique(ids)
        guard !kept.isEmpty else { return nil }
        if kept.count == 1 { return .leaf(kept[0]) }
        let share = 1.0 / Double(kept.count)
        return .split(axis, kept.map { DockChild(weight: share, node: .leaf($0)) })
    }

    /// A saved layout made to agree with what is open.
    ///
    /// Panels that are not open (or are not known to this build) are taken out;
    /// open panels the layout does not mention are added along the bottom; with
    /// no usable layout the open panels are stacked. `open` is in the order
    /// newcomers should appear.
    static func reconciled(_ saved: DockNode?, open: [DockModuleID], known: Set<DockModuleID>) -> DockNode? {
        let wanted = unique(open).filter { known.contains($0) }
        guard !wanted.isEmpty else { return nil }
        let wantedSet = Set(wanted)

        var tree = normalized(saved)
        for id in tree?.modules ?? [] where !wantedSet.contains(id) {
            tree = removing(id, from: tree)
        }
        guard var current = tree else { return stacked(wanted) }
        for id in wanted where !current.contains(id) {
            current = inserting(id, atRegionEdge: .bottom, into: current) ?? current
        }
        return current
    }

    /// What a saved state file says about the region, and the arrangement to
    /// start from because of it.
    struct Restoration: Equatable {
        var root: DockNode?
        /// The panel standing alone in the region, if one was.
        var fill: DockModuleID?
    }

    /// The arrangement to restore.
    ///
    /// A saved layout is used, made to agree with `open`. With none (or none
    /// that is usable), the file is taken to be from before panels could be
    /// tiled, when they were tabs with one showing: the open panels are stacked
    /// in a column, the one that was in front first, and — when there is more
    /// than one — that one fills the region, so the region looks as it did and
    /// tiling is a choice from the menu rather than a surprise on upgrading.
    static func restoring(
        saved: DockNode?,
        savedFill: DockModuleID?,
        open: [DockModuleID],
        front: DockModuleID?,
        known: Set<DockModuleID>
    ) -> Restoration {
        let wanted = unique(open).filter { known.contains($0) }
        if saved != nil, let root = reconciled(saved, open: wanted, known: known) {
            let fill = savedFill.flatMap { root.contains($0) ? $0 : nil }
            return Restoration(root: root, fill: fill)
        }
        var ordered = wanted
        if let front, let index = ordered.firstIndex(of: front) {
            ordered.remove(at: index)
            ordered.insert(front, at: 0)
        }
        return Restoration(root: stacked(ordered), fill: ordered.count >= 2 ? ordered[0] : nil)
    }

    // MARK: Editing

    /// `module` placed on `edge` of `target`, taking half of what `target` had.
    ///
    /// Beside a panel in a split that runs the same way, it becomes one more
    /// child and nothing else resizes. Across the split's axis, the target's slot
    /// becomes a small split of its own. A target that is not in the tree falls
    /// back to the same edge of the whole region; a module that is already in the
    /// tree leaves it unchanged (that is `moving`).
    static func inserting(
        _ module: DockModuleID,
        beside target: DockModuleID,
        edge: DockEdge,
        into root: DockNode?
    ) -> DockNode? {
        guard !module.isEmpty else { return normalized(root) }
        guard let tree = normalized(root) else { return .leaf(module) }
        guard !tree.contains(module) else { return tree }
        guard tree.contains(target) else {
            return inserting(module, atRegionEdge: edge, into: tree)
        }
        return normalized(place(module, beside: target, edge: edge, in: tree))
    }

    private static func place(
        _ module: DockModuleID,
        beside target: DockModuleID,
        edge: DockEdge,
        in node: DockNode
    ) -> DockNode {
        switch node {
        case .leaf(let id):
            guard id == target else { return node }
            let existing = DockChild(weight: 0.5, node: node)
            let added = DockChild(weight: 0.5, node: .leaf(module))
            return .split(edge.axis, edge.leads ? [added, existing] : [existing, added])

        case .split(let axis, let children):
            var result: [DockChild] = []
            for child in children {
                if case .leaf(let id) = child.node, id == target, axis == edge.axis {
                    let half = child.weight / 2
                    let existing = DockChild(weight: half, node: child.node)
                    let added = DockChild(weight: half, node: .leaf(module))
                    result.append(contentsOf: edge.leads ? [added, existing] : [existing, added])
                } else {
                    result.append(DockChild(
                        weight: child.weight,
                        node: place(module, beside: target, edge: edge, in: child.node)
                    ))
                }
            }
            return .split(axis, result)
        }
    }

    /// `module` placed along one side of the whole region, spanning its full
    /// height or width.
    ///
    /// It takes a third of the region — a half if the region held a single
    /// panel, and 1/(n+1) when the region is already a row of n along that axis
    /// — and everything else keeps its proportions within the rest.
    static func inserting(
        _ module: DockModuleID,
        atRegionEdge edge: DockEdge,
        into root: DockNode?
    ) -> DockNode? {
        guard !module.isEmpty else { return normalized(root) }
        guard let tree = normalized(root) else { return .leaf(module) }
        guard !tree.contains(module) else { return tree }

        let share: Double
        switch tree {
        case .leaf:
            share = 0.5
        case .split(let axis, let children):
            share = axis == edge.axis ? 1.0 / Double(children.count + 1) : 1.0 / 3.0
        }
        let existing = DockChild(weight: 1 - share, node: tree)
        let added = DockChild(weight: share, node: .leaf(module))
        return normalized(.split(edge.axis, edge.leads ? [added, existing] : [existing, added]))
    }

    /// The tree without `module`. Its space goes to the panel before it, or to
    /// the one after if it was first: one neighbour grows and the rest keep
    /// their size, so only one terminal is resized rather than all of them.
    static func removing(_ module: DockModuleID, from root: DockNode?) -> DockNode? {
        guard let tree = normalized(root) else { return nil }
        guard tree.contains(module) else { return tree }
        return normalized(drop(module, from: tree))
    }

    private static func drop(_ module: DockModuleID, from node: DockNode) -> DockNode? {
        switch node {
        case .leaf(let id):
            return id == module ? nil : node

        case .split(let axis, let children):
            var result: [DockChild] = []
            // Space freed by a first child, waiting for the next one to take it.
            var carried = 0.0
            for child in children {
                if let remaining = drop(module, from: child.node) {
                    result.append(DockChild(weight: child.weight + carried, node: remaining))
                    carried = 0
                } else if result.isEmpty {
                    carried += child.weight
                } else {
                    result[result.count - 1].weight += child.weight
                }
            }
            return result.isEmpty ? nil : .split(axis, result)
        }
    }

    /// `module` taken out and put back on `edge` of `target`.
    static func moving(
        _ module: DockModuleID,
        beside target: DockModuleID,
        edge: DockEdge,
        in root: DockNode?
    ) -> DockNode? {
        guard let tree = normalized(root) else { return nil }
        guard module != target, tree.contains(module), tree.contains(target),
              let without = removing(module, from: tree) else { return tree }
        return inserting(module, beside: target, edge: edge, into: without)
    }

    /// `module` taken out and put along one side of the whole region.
    ///
    /// A panel already first (or last) along that side stays where it is, with
    /// its size: asking for what it already has is not a reason to resize it.
    static func moving(
        _ module: DockModuleID,
        toRegionEdge edge: DockEdge,
        in root: DockNode?
    ) -> DockNode? {
        guard let tree = normalized(root) else { return nil }
        guard tree.contains(module), tree.modules.count > 1 else { return tree }
        if case .split(let axis, let children) = tree, axis == edge.axis,
           let atEdge = edge.leads ? children.first : children.last,
           case .leaf(let id) = atEdge.node, id == module {
            return tree
        }
        guard let without = removing(module, from: tree) else { return tree }
        return inserting(module, atRegionEdge: edge, into: without)
    }

    /// `a` and `b` trade places. Every share stays where it was.
    static func swapping(_ a: DockModuleID, _ b: DockModuleID, in root: DockNode?) -> DockNode? {
        guard let tree = normalized(root) else { return nil }
        guard a != b, tree.contains(a), tree.contains(b) else { return tree }
        return exchange(a, b, in: tree)
    }

    private static func exchange(_ a: DockModuleID, _ b: DockModuleID, in node: DockNode) -> DockNode {
        switch node {
        case .leaf(let id):
            if id == a { return .leaf(b) }
            if id == b { return .leaf(a) }
            return node
        case .split(let axis, let children):
            return .split(axis, children.map {
                DockChild(weight: $0.weight, node: exchange(a, b, in: $0.node))
            })
        }
    }
}
