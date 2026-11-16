import Foundation

/// The Hilbert curve: a path through every cell of a square grid that never jumps, so cells
/// that are near each other along it are near each other on the grid.
///
/// That is what makes it the way to lay a file out as a picture. Walk the file in order and
/// put each piece where the curve says, and a run of bytes becomes one compact patch instead
/// of a thin line across the page: a header, a block of text, a stretch of zeros or a
/// compressed blob each shows up as a shape you can point at.
///
/// A curve of `order` k covers a square `2^k` cells a side, `4^k` cells in all. Cell 0 is the
/// top left, the last cell is the top right, and every step from one cell to the next is one
/// cell up, down, left or right. Every aligned run of `4^m` cells fills a square of `2^m` cells
/// a side, so the picture keeps its shape at every size.
enum HilbertCurve {
    /// The most this will make: a grid 32,768 cells a side. The panel never goes near it.
    static let maxOrder = 15

    /// Cells in a curve of `order`: `4^order`.
    static func cellCount(order: Int) -> Int {
        1 << (2 * clamped(order))
    }

    /// Where cell `index` along the curve is, as column `x` and row `y`, both counted from 0
    /// at the top left. An index outside the curve is moved to its nearest end.
    static func point(order: Int, index: Int) -> (x: Int, y: Int) {
        let order = clamped(order)
        let side = 1 << order
        var t = min(max(index, 0), side * side - 1)
        var x = 0
        var y = 0
        var s = 1
        while s < side {
            let rx = 1 & (t / 2)
            let ry = 1 & (t ^ rx)
            rotate(size: s, x: &x, y: &y, rx: rx, ry: ry)
            x += s * rx
            y += s * ry
            t /= 4
            s *= 2
        }
        return (x, y)
    }

    /// How far along the curve the cell at column `x` and row `y` is: the inverse of `point`.
    /// A column or row outside the grid is moved to its nearest edge.
    static func index(order: Int, x: Int, y: Int) -> Int {
        let order = clamped(order)
        let side = 1 << order
        var x = min(max(x, 0), side - 1)
        var y = min(max(y, 0), side - 1)
        var d = 0
        var s = side / 2
        while s > 0 {
            let rx = (x & s) > 0 ? 1 : 0
            let ry = (y & s) > 0 ? 1 : 0
            d += s * s * ((3 * rx) ^ ry)
            rotate(size: side, x: &x, y: &y, rx: rx, ry: ry)
            s /= 2
        }
        return d
    }

    private static func clamped(_ order: Int) -> Int {
        min(max(order, 0), maxOrder)
    }

    /// Turns and flips the part of the grid being worked on so that the next, smaller level
    /// sees it the same way up.
    private static func rotate(size: Int, x: inout Int, y: inout Int, rx: Int, ry: Int) {
        guard ry == 0 else { return }
        if rx == 1 {
            x = size - 1 - x
            y = size - 1 - y
        }
        swap(&x, &y)
    }
}
