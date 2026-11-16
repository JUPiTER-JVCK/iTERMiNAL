import Foundation

/// How the map's cells are coloured.
enum ByteMapColoring: String, CaseIterable {
    /// By which kinds of byte are in the cell: text blue, zeros black, and so on.
    case byteClass
    /// By how random the window the cell is in is: dark for repetitive, bright for random.
    case entropy

    var title: String {
        switch self {
        case .byteClass: return "Byte kinds"
        case .entropy: return "Entropy"
        }
    }
}

struct ByteMapColor: Equatable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8

    /// Light on a scale of 0 to 255, by the usual weights, for telling which of two is brighter.
    var luminance: Double {
        0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)
    }
}

/// The map's colours. Plain numbers, so they are the same in the picture and in the legend.
enum ByteMapPalette {
    static func color(of byteClass: ByteClass) -> ByteMapColor {
        switch byteClass {
        case .zero: return ByteMapColor(red: 0x0E, green: 0x10, blue: 0x16)
        case .full: return ByteMapColor(red: 0xF5, green: 0xF5, blue: 0xF5)
        case .text: return ByteMapColor(red: 0x3B, green: 0x82, blue: 0xF6)
        case .control: return ByteMapColor(red: 0x22, green: 0xC5, blue: 0x5E)
        case .high: return ByteMapColor(red: 0xEF, green: 0x44, blue: 0x44)
        }
    }

    /// A cell that could not be read.
    static let unread = ByteMapColor(red: 0x80, green: 0x80, blue: 0x80)

    /// Light and dark steps, from black through purple and orange to pale yellow, that read
    /// as more and less in order; the stops of the "inferno" scale.
    private static let ramp: [ByteMapColor] = [
        ByteMapColor(red: 0, green: 0, blue: 4),
        ByteMapColor(red: 87, green: 16, blue: 110),
        ByteMapColor(red: 188, green: 55, blue: 84),
        ByteMapColor(red: 249, green: 142, blue: 9),
        ByteMapColor(red: 252, green: 255, blue: 164)
    ]

    /// The colour for `bits` of entropy, from 0 to 8.
    static func entropyColor(_ bits: Double) -> ByteMapColor {
        let position = min(max(bits / Entropy.maxBits, 0), 1) * Double(ramp.count - 1)
        let lower = min(Int(position), ramp.count - 2)
        let fraction = position - Double(lower)
        let a = ramp[lower]
        let b = ramp[lower + 1]
        func mix(_ x: UInt8, _ y: UInt8) -> UInt8 {
            UInt8(min(max((Double(x) + (Double(y) - Double(x)) * fraction).rounded(), 0), 255))
        }
        return ByteMapColor(red: mix(a.red, b.red), green: mix(a.green, b.green), blue: mix(a.blue, b.blue))
    }

    /// A cell's colour: its kinds of byte, each in its own colour, in proportion.
    static func color(of cell: ByteMapCell) -> ByteMapColor {
        let total = cell.total
        guard total > 0 else { return unread }
        var red = 0
        var green = 0
        var blue = 0
        for byteClass in ByteClass.allCases {
            let count = cell[byteClass]
            let color = self.color(of: byteClass)
            red += count * Int(color.red)
            green += count * Int(color.green)
            blue += count * Int(color.blue)
        }
        let half = total / 2
        return ByteMapColor(
            red: UInt8((red + half) / total),
            green: UInt8((green + half) / total),
            blue: UInt8((blue + half) / total)
        )
    }
}

enum ByteMapRaster {
    /// The picture as pixels: `side * side` of them, row by row from the top left, four bytes
    /// each (red, green, blue, and an alpha that is always opaque).
    static func pixels(_ analysis: ByteMapAnalysis, coloring: ByteMapColoring) -> [UInt8] {
        let layout = analysis.layout
        let side = layout.side
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        let windowColors: [ByteMapColor] = coloring == .entropy
            ? analysis.windowEntropy.enumerated().map { index, bits in
                // A window that read nothing is shown as unread, not as plain.
                analysis.windowBytes[index] > 0 ? ByteMapPalette.entropyColor(bits) : ByteMapPalette.unread
            }
            : []
        for index in 0..<layout.cellCount {
            let color: ByteMapColor
            switch coloring {
            case .byteClass:
                color = ByteMapPalette.color(of: analysis.cells[index])
            case .entropy:
                color = windowColors[layout.window(ofCell: index)]
            }
            let point = layout.point(ofCell: index)
            let at = (point.y * side + point.x) * 4
            pixels[at] = color.red
            pixels[at + 1] = color.green
            pixels[at + 2] = color.blue
        }
        return pixels
    }
}
