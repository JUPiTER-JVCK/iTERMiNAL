import Foundation

/// What the map says about a place in the file, in words. The numbers are all worked out
/// here, so what a person is told is checked like everything else; the view shows the lines.
enum ByteMapText {
    /// "0x1F40", for an offset.
    static func hex(_ value: Int64) -> String {
        "0x" + String(value, radix: 16, uppercase: true)
    }

    /// "0x1F40 to 0x1FFF" for a run of bytes, or "0x1F40" for one byte.
    static func range(_ span: Range<Int64>) -> String {
        guard span.upperBound - span.lowerBound > 1 else { return hex(span.lowerBound) }
        return "\(hex(span.lowerBound)) to \(hex(span.upperBound - 1))"
    }

    /// "1 byte", "300 bytes", "64 KiB", "1.5 MiB": binary units, named as such so there is no
    /// doubt what a figure means beside offsets that are in hex.
    static func size(_ bytes: Int64) -> String {
        if bytes < 1024 { return bytes == 1 ? "1 byte" : "\(max(bytes, 0)) bytes" }
        let units = ["KiB", "MiB", "GiB", "TiB", "PiB", "EiB"]
        var value = Double(bytes) / 1024
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        let number = value < 10 ? String(format: "%.1f", value) : String(format: "%.0f", value)
        return number + " " + units[unit]
    }

    /// Bits per byte to two places: "7.98".
    static func bits(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// The kinds of byte in a cell that make up a tenth or more of it, biggest first:
    /// "text 62%, control codes 21%, zeros 17%".
    static func mix(_ cell: ByteMapCell) -> String {
        let total = cell.total
        guard total > 0 else { return "nothing read" }
        let shares = ByteClass.allCases
            .map { (byteClass: $0, count: cell[$0]) }
            .filter { $0.count * 10 >= total }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.byteClass.rawValue < $1.byteClass.rawValue }
        return shares
            .map { "\($0.byteClass.title) \(percent($0.count, of: total))%" }
            .joined(separator: ", ")
    }

    /// A share as a whole percent: never 0 for something that is there, never 100 for
    /// something that is not all of it.
    static func percent(_ count: Int, of total: Int) -> Int {
        guard total > 0, count > 0 else { return 0 }
        let rounded = (count * 100 + total / 2) / total
        if count < total { return min(max(rounded, 1), 99) }
        return 100
    }
}

extension ByteMapAnalysis {
    /// What is in cell `index`: where it is, how big, and what its bytes are.
    func cellLine(_ index: Int) -> String {
        let cell = cells[min(max(index, 0), cells.count - 1)]
        let span = layout.cellRange(index)
        var parts = [ByteMapText.range(span), ByteMapText.size(span.upperBound - span.lowerBound)]
        if isSampled, cell.total > 0 { parts.append("sampled \(ByteMapText.size(Int64(cell.total)))") }
        parts.append(ByteMapText.mix(cell))
        return parts.joined(separator: " · ")
    }

    /// How random the window `index` is: where it is, its entropy and what that is typical of.
    func windowLine(_ index: Int) -> String {
        let w = min(max(index, 0), windowEntropy.count - 1)
        let bits = windowEntropy[w]
        let reading = EntropyReading.describe(bits: bits, bytes: Int64(windowBytes[w]), distinct: windowDistinct[w])
        let span = layout.windowRange(w)
        return "\(ByteMapText.range(span)) · entropy \(ByteMapText.bits(bits)) bits per byte: \(reading)"
    }

    /// The whole file in a line.
    var summaryLine: String {
        let reading = EntropyReading.describe(bits: entropy, bytes: readBytes, distinct: distinctValues)
        let scope = isSampled ? "Sampled: " : ""
        return "\(scope)entropy \(ByteMapText.bits(entropy)) bits per byte over \(ByteMapText.size(readBytes)): \(reading)"
    }

    /// Something to say about how much was read, or nil when all of it was and nothing was missed.
    var coverageNote: String? {
        var notes: [String] = []
        if isSampled {
            notes.append("A file this big is sampled: \(ByteMapText.size(sampleSize)) from each of \(cells.count) places, \(ByteMapText.size(readBytes)) of \(ByteMapText.size(length)).")
        }
        if unreadBytes > 0 {
            notes.append("\(ByteMapText.size(unreadBytes)) could not be read; the file may have changed.")
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }
}
