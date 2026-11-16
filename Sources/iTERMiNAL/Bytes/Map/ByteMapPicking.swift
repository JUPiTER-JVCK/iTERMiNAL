import Foundation

/// Where things are on the two pictures, as fractions of their width and height, so that what a
/// click or a hover means is worked out here, and checked, and the views only scale it to the
/// size they are drawn at.
extension ByteMapLayout {
    // MARK: The map

    /// The cell under a point of the map, given as how far across and down it is, each from 0 to 1.
    /// A point off the picture is moved to its nearest edge.
    func cell(atFractionX across: Double, y down: Double) -> Int {
        func place(_ fraction: Double) -> Int {
            guard !fraction.isNaN else { return 0 }
            return min(max(Int(min(max(fraction, 0), 1) * Double(side)), 0), side - 1)
        }
        return cell(atX: place(across), y: place(down))
    }

    /// The middle of cell `index` on the map, as how far across and down it is, each from 0 to 1.
    func center(ofCell index: Int) -> (x: Double, y: Double) {
        let point = self.point(ofCell: index)
        return ((Double(point.x) + 0.5) / Double(side), (Double(point.y) + 0.5) / Double(side))
    }

    // MARK: The graph

    /// The byte a point along the graph is over, given as how far along it is, from 0 to 1.
    /// A point off either end is moved to the nearest end; an empty file has only byte 0.
    func offset(atFraction fraction: Double) -> Int64 {
        guard length > 0, !fraction.isNaN else { return 0 }
        let scaled = min(max(fraction, 0), 1) * Double(length)
        // 2^63 is the first Double past what an Int64 can hold.
        guard scaled < 9_223_372_036_854_775_808.0 else { return length - 1 }
        return min(Int64(scaled), length - 1)
    }

    /// How far along the graph byte `offset` is, from 0 to 1: the middle of the byte.
    func fraction(ofOffset offset: Int64) -> Double {
        guard length > 0 else { return 0 }
        let position = min(max(offset, 0), length - 1)
        return (Double(position) + 0.5) / Double(length)
    }

    /// Where window `index` starts and ends along the graph, each from 0 to 1.
    func fractions(ofWindow index: Int) -> (start: Double, end: Double) {
        guard length > 0 else { return (0, 1) }
        let span = windowRange(index)
        return (Double(span.lowerBound) / Double(length), Double(span.upperBound) / Double(length))
    }
}
