import Foundation

// The sizes half of the dock layout: where each panel's rectangle falls, what the
// region needs at least, how a divider drag changes the shares, and which side a
// newly opened panel should go on. Foundation only, with its own small geometry
// types rather than CGRect, so all of it is checked off a Mac.

struct DockPoint: Equatable {
    var x: Double
    var y: Double
}

struct DockSize: Equatable {
    var width: Double
    var height: Double
}

struct DockRect: Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var maxX: Double { x + width }
    var maxY: Double { y + height }

    /// Half-open, so a point on the seam between two rectangles is in exactly one.
    func contains(_ point: DockPoint) -> Bool {
        point.x >= x && point.x < maxX && point.y >= y && point.y < maxY
    }
}

/// What the layout needs to know about the panels it holds, supplied by the
/// caller because this file cannot see `SidePanel`.
struct DockMetrics: Equatable {
    /// Space a divider takes between two panels.
    var dividerThickness: Double = 1
    /// For a panel with no entry in `minimums`, and for an empty region.
    var fallbackMinimum = DockSize(width: 280, height: 160)
    var minimums: [DockModuleID: DockSize] = [:]

    func minimum(of module: DockModuleID) -> DockSize {
        minimums[module] ?? fallbackMinimum
    }
}

struct DockLeafFrame: Equatable {
    let module: DockModuleID
    let rect: DockRect
}

/// A seam between two neighbouring children of one split.
struct DockDivider: Equatable {
    /// Where the split is in the tree: the child index to take at each level
    /// from the root. Empty for the root itself.
    let path: [Int]
    /// The seam sits after child `index` of that split.
    let index: Int
    let axis: DockAxis
    let rect: DockRect
    /// How much the two children either side take now, and the least each may.
    let leadingExtent: Double
    let trailingExtent: Double
    let leadingMinimum: Double
    let trailingMinimum: Double
    /// Room the split's children share, dividers not counted.
    let splitExtent: Double

    /// Where the leading child's size may be dragged to, or nil when the two
    /// are already squeezed below their minimums and there is nothing to drag.
    var leadingRange: ClosedRange<Double>? {
        let lower = leadingMinimum
        let upper = leadingExtent + trailingExtent - trailingMinimum
        return lower <= upper ? lower...upper : nil
    }
}

struct DockFrames: Equatable {
    var leaves: [DockLeafFrame]
    var dividers: [DockDivider]

    func rect(of module: DockModuleID) -> DockRect? {
        leaves.first { $0.module == module }?.rect
    }

    func module(at point: DockPoint) -> DockModuleID? {
        leaves.first { $0.rect.contains(point) }?.module
    }

    /// The panel in the region's top-right corner — the one that carries the
    /// controls that belong to the region rather than to a panel.
    func topTrailingModule() -> DockModuleID? {
        var best: DockLeafFrame?
        for leaf in leaves {
            guard let current = best else {
                best = leaf
                continue
            }
            if leaf.rect.maxX > current.rect.maxX
                || (leaf.rect.maxX == current.rect.maxX && leaf.rect.y < current.rect.y) {
                best = leaf
            }
        }
        return best?.module
    }
}

extension DockLayout {

    /// A focused panel at least this wide is split side by side. Each half is
    /// then at least 360, the width the main surface is kept to.
    static let sideBySideWidth = 720.0

    // MARK: Sizes

    /// The least the region can be, and still give every panel its minimum.
    ///
    /// A row adds up its children's widths and takes the tallest minimum; a
    /// column does the reverse. A btop that must be 640 wide therefore raises
    /// the region's floor to 640, however the others are arranged around it,
    /// but a column of three small panels does not add their widths. An empty
    /// region needs the fallback minimum.
    static func minimumSize(of root: DockNode?, metrics: DockMetrics) -> DockSize {
        guard let tree = normalized(root) else { return metrics.fallbackMinimum }
        return minimum(of: tree, metrics: metrics)
    }

    private static func minimum(of node: DockNode, metrics: DockMetrics) -> DockSize {
        switch node {
        case .leaf(let id):
            return metrics.minimum(of: id)
        case .split(let axis, let children):
            let sizes = children.map { minimum(of: $0.node, metrics: metrics) }
            let gaps = Double(max(children.count - 1, 0)) * metrics.dividerThickness
            switch axis {
            case .horizontal:
                return DockSize(
                    width: sizes.reduce(0.0) { $0 + $1.width } + gaps,
                    height: sizes.map { $0.height }.max() ?? 0
                )
            case .vertical:
                return DockSize(
                    width: sizes.map { $0.width }.max() ?? 0,
                    height: sizes.reduce(0.0) { $0 + $1.height } + gaps
                )
            }
        }
    }

    private static func extent(of size: DockSize, along axis: DockAxis) -> Double {
        axis == .horizontal ? size.width : size.height
    }

    // MARK: Frames

    /// The rectangle of every panel and divider when the tree is laid out in
    /// `rect`.
    ///
    /// Each split shares its room out by weight, except that nobody goes below
    /// their minimum: a child that would is held at it and the others share
    /// what is left, repeating until nobody is. When even the minimums do not
    /// fit, they are scaled down together, so a rectangle is never negative and
    /// the panels still tile the region. Sizes are whole points, the last child
    /// of a split taking up the rounding, so an edge never falls between pixels.
    static func frames(
        of root: DockNode?,
        in rect: DockRect,
        metrics: DockMetrics = DockMetrics()
    ) -> DockFrames {
        var leaves: [DockLeafFrame] = []
        var dividers: [DockDivider] = []
        if let tree = normalized(root) {
            lay(tree, in: rect, path: [], metrics: metrics, leaves: &leaves, dividers: &dividers)
        }
        return DockFrames(leaves: leaves, dividers: dividers)
    }

    private static func lay(
        _ node: DockNode,
        in rect: DockRect,
        path: [Int],
        metrics: DockMetrics,
        leaves: inout [DockLeafFrame],
        dividers: inout [DockDivider]
    ) {
        switch node {
        case .leaf(let id):
            leaves.append(DockLeafFrame(module: id, rect: rect))

        case .split(let axis, let children):
            let thickness = metrics.dividerThickness
            let gaps = Double(children.count - 1) * thickness
            let room = max(0, (axis == .horizontal ? rect.width : rect.height) - gaps)
            let minimums = children.map { extent(of: minimum(of: $0.node, metrics: metrics), along: axis) }
            let extents = resolveExtents(
                weights: children.map { $0.weight },
                minimums: minimums,
                total: room
            )

            var cursor = axis == .horizontal ? rect.x : rect.y
            for (index, child) in children.enumerated() {
                let childRect: DockRect
                if axis == .horizontal {
                    childRect = DockRect(x: cursor, y: rect.y, width: extents[index], height: rect.height)
                } else {
                    childRect = DockRect(x: rect.x, y: cursor, width: rect.width, height: extents[index])
                }
                lay(child.node, in: childRect, path: path + [index], metrics: metrics,
                    leaves: &leaves, dividers: &dividers)
                cursor += extents[index]

                if index < children.count - 1 {
                    let seam: DockRect
                    if axis == .horizontal {
                        seam = DockRect(x: cursor, y: rect.y, width: thickness, height: rect.height)
                    } else {
                        seam = DockRect(x: rect.x, y: cursor, width: rect.width, height: thickness)
                    }
                    dividers.append(DockDivider(
                        path: path,
                        index: index,
                        axis: axis,
                        rect: seam,
                        leadingExtent: extents[index],
                        trailingExtent: extents[index + 1],
                        leadingMinimum: minimums[index],
                        trailingMinimum: minimums[index + 1],
                        splitExtent: room
                    ))
                    cursor += thickness
                }
            }
        }
    }

    /// How `total` is shared out by `weights`, with no share under its entry in
    /// `minimums`. The sizes add up to `total`.
    static func resolveExtents(weights: [Double], minimums: [Double], total: Double) -> [Double] {
        let count = weights.count
        guard count > 0, minimums.count == count else { return [] }
        guard total > 0 else { return Array(repeating: 0, count: count) }

        let minimumTotal = minimums.reduce(0, +)
        var extents = Array(repeating: 0.0, count: count)

        if minimumTotal >= total {
            for index in 0..<count {
                extents[index] = minimumTotal > 0
                    ? minimums[index] / minimumTotal * total
                    : total / Double(count)
            }
            return snapped(extents, total: total)
        }

        var held = Array(repeating: false, count: count)
        while true {
            let active = (0..<count).filter { !held[$0] }
            if active.isEmpty { break }
            let remaining = total - (0..<count).filter { held[$0] }.reduce(0.0) { $0 + extents[$1] }
            let weightSum = active.reduce(0.0) { $0 + weights[$1] }
            for index in active {
                extents[index] = weightSum > 0
                    ? remaining * weights[index] / weightSum
                    : remaining / Double(active.count)
            }
            let squeezed = active.filter { extents[$0] < minimums[$0] }
            if squeezed.isEmpty { break }
            // Not every child can be squeezed at once, or the minimums would not
            // have fit; so this ends with someone left to share what remains.
            for index in squeezed {
                extents[index] = minimums[index]
                held[index] = true
            }
        }
        return snapped(extents, total: total)
    }

    /// `extents` rounded to whole points, boundary by boundary, so each child's
    /// edge is on a point and the last takes whatever the rounding left.
    private static func snapped(_ extents: [Double], total: Double) -> [Double] {
        var result: [Double] = []
        var cumulative = 0.0
        var edge = 0.0
        for (index, extent) in extents.enumerated() {
            if index == extents.count - 1 {
                result.append(max(0, total - edge))
            } else {
                cumulative += extent
                let next = max(edge, cumulative.rounded())
                result.append(next - edge)
                edge = next
            }
        }
        return result
    }

    // MARK: Resizing

    /// The tree after the divider that follows child `dividerIndex` of the split
    /// at `splitPath` is dragged so the child before it is `leadingExtent` wide
    /// (or tall).
    ///
    /// Only the two children either side of the divider trade space; the others
    /// keep the size they are drawn at. The weights of the whole split are
    /// rewritten from those drawn sizes rather than adjusted from the old ones:
    /// a weight that was being overridden by a minimum would otherwise make the
    /// first frame of a drag jump to where it "should" be. A request outside the
    /// two minimums is held to them, and a divider that does not exist leaves the
    /// tree as it was.
    static func resizing(
        _ root: DockNode?,
        splitPath: [Int],
        dividerIndex: Int,
        leadingExtent: Double,
        in rect: DockRect,
        metrics: DockMetrics = DockMetrics()
    ) -> DockNode? {
        guard let tree = normalized(root) else { return nil }
        guard leadingExtent.isFinite else { return tree }

        let drawn = frames(of: tree, in: rect, metrics: metrics)
        let siblings = drawn.dividers
            .filter { $0.path == splitPath }
            .sorted { $0.index < $1.index }
        guard let divider = siblings.first(where: { $0.index == dividerIndex }),
              let range = divider.leadingRange,
              divider.splitExtent > 0 else { return tree }

        // Child i's drawn size: the first from its divider's leading side, the
        // rest from the trailing side of the divider before them.
        var extents = [siblings[0].leadingExtent] + siblings.map { $0.trailingExtent }
        guard extents.indices.contains(dividerIndex + 1) else { return tree }

        let pair = divider.leadingExtent + divider.trailingExtent
        let leading = min(max(leadingExtent, range.lowerBound), range.upperBound)
        extents[dividerIndex] = leading
        extents[dividerIndex + 1] = pair - leading

        // A floor of a sliver, not zero: a zero weight reads as damaged.
        let weights = extents.map { max($0 / divider.splitExtent, 1e-6) }
        return normalized(replacingWeights(at: splitPath[...], with: weights, in: tree))
    }

    private static func replacingWeights(
        at path: ArraySlice<Int>,
        with weights: [Double],
        in node: DockNode
    ) -> DockNode {
        guard case .split(let axis, let children) = node else { return node }
        guard let first = path.first else {
            guard weights.count == children.count else { return node }
            var result = children
            for index in result.indices { result[index].weight = weights[index] }
            return .split(axis, result)
        }
        guard children.indices.contains(first) else { return node }
        var result = children
        result[first].node = replacingWeights(at: path.dropFirst(), with: weights, in: children[first].node)
        return .split(axis, result)
    }

    // MARK: Where a newly opened panel goes

    /// Which side of the focused panel a newcomer takes.
    ///
    /// Beside it when the focused panel is wide (at least `sideBySideWidth`) and
    /// both still fit at their minimums; below it when they fit stacked; then
    /// whichever fits at all, and below if neither does. A region at its default
    /// width is narrow, so panels stack there; a tool that needs 640 goes beside
    /// only when there is room for it.
    static func smartEdge(
        focused: DockRect,
        focusedMinimum: DockSize,
        newMinimum: DockSize,
        metrics: DockMetrics
    ) -> DockEdge {
        let gap = metrics.dividerThickness
        let sideFits = focused.width >= focusedMinimum.width + newMinimum.width + gap
        let stackFits = focused.height >= focusedMinimum.height + newMinimum.height + gap
        if focused.width >= sideBySideWidth && sideFits { return .right }
        if stackFits { return .bottom }
        if sideFits { return .right }
        return .bottom
    }

    /// `module` opened beside `focused` (the first panel if that one is not in
    /// the tree), on the side `smartEdge` picks for the region as it is laid out
    /// at `regionSize`. A panel already in the tree is left where it is.
    static func smartInserting(
        _ module: DockModuleID,
        near focused: DockModuleID?,
        regionSize: DockSize,
        into root: DockNode?,
        metrics: DockMetrics
    ) -> DockNode? {
        guard let tree = normalized(root) else {
            return module.isEmpty ? nil : .leaf(module)
        }
        guard !module.isEmpty, !tree.contains(module) else { return tree }

        let anchor: DockModuleID
        if let focused, tree.contains(focused) {
            anchor = focused
        } else if let first = tree.modules.first {
            anchor = first
        } else {
            return inserting(module, atRegionEdge: .bottom, into: tree)
        }

        let region = DockRect(x: 0, y: 0, width: regionSize.width, height: regionSize.height)
        let drawn = frames(of: tree, in: region, metrics: metrics)
        guard let rect = drawn.rect(of: anchor) else {
            return inserting(module, atRegionEdge: .bottom, into: tree)
        }
        let edge = smartEdge(
            focused: rect,
            focusedMinimum: metrics.minimum(of: anchor),
            newMinimum: metrics.minimum(of: module),
            metrics: metrics
        )
        return inserting(module, beside: anchor, edge: edge, into: tree)
    }

    // MARK: Dragging a panel

    /// How far in from the region's own edge a pointer is taken to mean "along
    /// the whole side", rather than beside the panel that happens to be there.
    static let regionEdgeBand = 16.0

    /// How far in from a panel's edge a pointer means "beside this panel, on
    /// that side": a third of the panel's width (or height), but never more
    /// than `panelEdgeBandLimit`, so a large panel still has a middle to swap in.
    static let panelEdgeFraction = 0.3
    static let panelEdgeBandLimit = 96.0

    /// Where a panel being dragged would land if it were dropped at `point`
    /// (both in the region's own coordinates), or nil when dropping there does
    /// nothing: outside the region, or on the panel being dragged.
    ///
    /// The thin strip along the region's edge comes first, and wins even over
    /// the dragged panel's own area, so a panel can be sent to a side from
    /// wherever it is. Past that, the pointer is over some other panel: near
    /// one of its sides it means beside it on that side (the nearest side, in
    /// proportion to how wide the band is, when it is near two), and in the
    /// middle it means swapping places. The seam between two panels counts as
    /// the panel on its near side, so a zone does not flicker off as the
    /// pointer crosses it.
    static func dropTarget(
        at point: DockPoint,
        dragging: DockModuleID,
        in frames: DockFrames,
        region: DockRect
    ) -> DockDropTarget? {
        guard region.width > 0, region.height > 0, region.contains(point) else { return nil }

        let sides: [(edge: DockEdge, distance: Double)] = [
            (.left, point.x - region.x),
            (.right, region.maxX - point.x),
            (.top, point.y - region.y),
            (.bottom, region.maxY - point.y),
        ]
        if let nearest = sides.min(by: { $0.distance < $1.distance }), nearest.distance < regionEdgeBand {
            return .regionEdge(nearest.edge)
        }

        guard let target = panel(at: point, in: frames), target.module != dragging else { return nil }
        let rect = target.rect
        let bandAcross = min(panelEdgeFraction * rect.width, panelEdgeBandLimit)
        let bandDown = min(panelEdgeFraction * rect.height, panelEdgeBandLimit)
        let inner: [(edge: DockEdge, distance: Double, band: Double)] = [
            (.left, point.x - rect.x, bandAcross),
            (.right, rect.maxX - point.x, bandAcross),
            (.top, point.y - rect.y, bandDown),
            (.bottom, rect.maxY - point.y, bandDown),
        ]
        // How far into its band each side is, from 0 at the edge to 1 at the
        // band's inner limit. The shallowest wins, so a pointer near a corner
        // goes to the side it is closer to.
        let within = inner.filter { $0.band > 0 && $0.distance < $0.band }
        if let side = within.min(by: { $0.distance / $0.band < $1.distance / $1.band }) {
            return .beside(target.module, side.edge)
        }
        return .swap(target.module)
    }

    /// The panel under `point`, or — for a point on a divider, between panels —
    /// the first one within a few points of it.
    private static func panel(at point: DockPoint, in frames: DockFrames) -> DockLeafFrame? {
        if let hit = frames.leaves.first(where: { $0.rect.contains(point) }) { return hit }
        let slack = 4.0
        return frames.leaves.first { leaf in
            point.x >= leaf.rect.x - slack && point.x < leaf.rect.maxX + slack
                && point.y >= leaf.rect.y - slack && point.y < leaf.rect.maxY + slack
        }
    }

    /// The area to light up for `target`: the half of the panel the dragged one
    /// would take, the whole panel it would swap with, or a third of the region
    /// along the side it would go to. Only a picture of where it lands — the
    /// sizes it really gets are worked out by `dropping`.
    static func dropHighlight(for target: DockDropTarget, in frames: DockFrames, region: DockRect) -> DockRect? {
        switch target {
        case .swap(let module):
            return frames.rect(of: module)
        case .beside(let module, let edge):
            guard let rect = frames.rect(of: module) else { return nil }
            return portion(of: rect, edge: edge, fraction: 0.5)
        case .regionEdge(let edge):
            return portion(of: region, edge: edge, fraction: 1.0 / 3.0)
        }
    }

    private static func portion(of rect: DockRect, edge: DockEdge, fraction: Double) -> DockRect {
        let width = rect.width * fraction
        let height = rect.height * fraction
        switch edge {
        case .left:
            return DockRect(x: rect.x, y: rect.y, width: width, height: rect.height)
        case .right:
            return DockRect(x: rect.maxX - width, y: rect.y, width: width, height: rect.height)
        case .top:
            return DockRect(x: rect.x, y: rect.y, width: rect.width, height: height)
        case .bottom:
            return DockRect(x: rect.x, y: rect.maxY - height, width: rect.width, height: height)
        }
    }

    /// The tree after `module` is dropped on `target`: the same moves and swaps
    /// the Move menu makes, so a drag and a menu choice end up in the same place.
    static func dropping(_ module: DockModuleID, onto target: DockDropTarget, in root: DockNode?) -> DockNode? {
        switch target {
        case .beside(let other, let edge):
            return moving(module, beside: other, edge: edge, in: root)
        case .swap(let other):
            return swapping(module, other, in: root)
        case .regionEdge(let edge):
            return moving(module, toRegionEdge: edge, in: root)
        }
    }
}

/// Where a dragged panel would land.
enum DockDropTarget: Equatable {
    /// Beside another panel, on one of its sides, taking half of its room.
    case beside(DockModuleID, DockEdge)
    /// In another panel's place, and that one in this one's.
    case swap(DockModuleID)
    /// Along one side of the whole region.
    case regionEdge(DockEdge)
}
