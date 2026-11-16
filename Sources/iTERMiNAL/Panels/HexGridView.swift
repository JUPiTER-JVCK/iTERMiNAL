import SwiftUI
import AppKit

/// The colours the grid draws with, handed over by the pane so the grid knows
/// nothing of themes.
struct HexGridStyle: Equatable {
    var background: NSColor
    var text: NSColor
    /// Offsets, zero bytes, bytes that are not printable.
    var dimText: NSColor
    var selection: NSColor
    /// The selection while the grid is not the one taking keys.
    var inactiveSelection: NSColor
    var cursor: NSColor
    /// A byte that could not be read.
    var missing: NSColor
}

/// A file's bytes as rows: offset, cells, text. `HexGridNSView` does the work;
/// this hands it what to show and takes back what was selected.
struct HexGridView: NSViewRepresentable {
    let buffer: ByteEditBuffer
    let radix: ByteRadix
    /// 0 fits as many as the width has room for.
    let bytesPerRow: Int
    let showsText: Bool
    let selection: ByteSelection?
    let reveal: BytesRevealRequest?
    let style: HexGridStyle
    let onSelect: (ByteSelection) -> Void
    let onCopy: () -> Void
    /// ⌘F, ⌘G and ⇧⌘G while the dump has the keys.
    let onFind: (HexGridFindCommand) -> Void
    /// Whether keys change the bytes: the file can be written and the cells are hex.
    let isEditable: Bool
    let onEdit: (HexGridEdit) -> Void

    /// Which reveal request was acted on, so one that is still on the model after
    /// a redraw is not acted on again.
    final class Coordinator {
        var handledReveal: UUID?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> HexGridNSView {
        let view = HexGridNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        apply(to: view, context: context)
        return view
    }

    func updateNSView(_ view: HexGridNSView, context: Context) {
        apply(to: view, context: context)
    }

    private func apply(to view: HexGridNSView, context: Context) {
        view.onSelect = onSelect
        view.onCopy = onCopy
        view.onFind = onFind
        view.isEditable = isEditable
        view.onEdit = onEdit
        view.update(buffer: buffer, radix: radix, requestedBytesPerRow: bytesPerRow, showsText: showsText,
                    selection: selection, style: style)
        if let reveal, reveal.id != context.coordinator.handledReveal {
            context.coordinator.handledReveal = reveal.id
            view.reveal(offset: reveal.offset, centered: reveal.centered)
        }
    }
}

/// What the find keys ask for, passed from the dump to the pane.
enum HexGridFindCommand {
    case show
    case next
    case previous
}

/// What a key typed in the dump asks for, when the file can be changed.
enum HexGridEdit: Equatable {
    /// 0 to 15, typed in the hex cells.
    case hexDigit(UInt8)
    /// Characters typed in the text column.
    case text(String)
    case deleteBackward
    case deleteForward
    case undo
    case redo
    case save
}

/// The dump, drawn a row at a time.
///
/// Not an `NSScrollView` with a tall document view, and not an `NSTextView`. A
/// 4 GB file at 16 bytes a row is 268 million rows, which is billions of points
/// of document: far more than a scroll view's geometry can be relied on to
/// carry, and a text view wants the whole text. So this view draws only the rows
/// in sight, keeps its place as a row number (a `Double`, so it scrolls smoothly
/// between rows), and has an `NSScroller` of its own whose knob is that number
/// as a fraction of the file.
/// The knob is coarse on a big file, as it must be; the go-to field, the arrow
/// keys and the page keys are for getting to the byte.
///
/// Everything that decides where a character goes — columns, rows, which byte a
/// click is on, what an arrow key does — is `HexGeometry` and `ByteSelection`,
/// which CI checks. What is left here is drawing, the scroller, and passing
/// events on.
final class HexGridNSView: NSView {
    var onSelect: ((ByteSelection) -> Void)?
    var onCopy: (() -> Void)?
    var onFind: ((HexGridFindCommand) -> Void)?
    var isEditable = false
    var onEdit: ((HexGridEdit) -> Void)?
    /// Whether the last click was on the text column, so that typing goes there and not to the hex cells.
    private var typesInText = false

    private var buffer: ByteEditBuffer?
    private var radix = ByteRadix.hex
    private var requestedBytesPerRow = 0
    private var showsText = true
    private var selection: ByteSelection?
    private var style: HexGridStyle?

    private static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private static let groupSize = 8
    private let padding = NSSize(width: 8, height: 4)
    private let charWidth: CGFloat
    private let lineHeight: CGFloat
    private let scroller = NSScroller(frame: NSRect(x: 0, y: 0, width: 15, height: 100))

    /// The row at the top of the view, and how far the rows are shifted sideways.
    private var scrollRow: Double = 0
    private var panX: CGFloat = 0
    /// The row width last used, to keep the first byte in place when it changes.
    private var lastBytesPerRow = 0
    private var dragAnchor: Int64?

    override init(frame: NSRect) {
        let font = HexGridNSView.font
        charWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        lineHeight = ceil(font.ascender - font.descender + font.leading) + 2
        super.init(frame: frame)
        scroller.scrollerStyle = .legacy
        scroller.target = self
        scroller.action = #selector(scrolled(_:))
        scroller.knobProportion = 1
        scroller.isEnabled = false
        addSubview(scroller)
    }

    required init?(coder: NSCoder) {
        fatalError("HexGridNSView is made in code")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// A click that brings the window forward also selects.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    // MARK: What to show

    func update(buffer: ByteEditBuffer, radix: ByteRadix, requestedBytesPerRow: Int, showsText: Bool,
                selection: ByteSelection?, style: HexGridStyle) {
        self.buffer = buffer
        self.radix = radix
        self.requestedBytesPerRow = requestedBytesPerRow
        self.showsText = showsText
        self.selection = selection
        self.style = style
        geometryDidChange()
        updateScroller()
        needsDisplay = true
    }

    /// Brings `offset` into sight: where it is already, if it is; else in the middle
    /// if asked, or at the top.
    func reveal(offset: Int64, centered: Bool) {
        let row = Double(geometry.location(of: offset).row)
        let inSight = row >= scrollRow && row + 1 <= scrollRow + visibleRows
        if !inSight {
            scrollRow = centered ? row - (visibleRows - 1) / 2 : row
        }
        clampScroll()
        updateScroller()
        needsDisplay = true
    }

    // MARK: Geometry

    private var length: Int64 { buffer?.length ?? 0 }

    /// The width the rows have: the view less its scroller.
    private var rowsWidth: CGFloat { max(0, bounds.width - scroller.frame.width) }

    private var geometry: HexGeometry {
        let digits = HexGeometry.offsetDigits(forLength: length)
        let perRow: Int
        if requestedBytesPerRow > 0 {
            perRow = requestedBytesPerRow
        } else {
            let columns = Int(max(0, rowsWidth - padding.width * 2) / charWidth)
            perRow = HexGeometry.fitting(columns: columns, groupSize: HexGridNSView.groupSize, radix: radix,
                                         offsetDigits: digits, showsText: showsText)
        }
        return HexGeometry(bytesPerRow: perRow, groupSize: HexGridNSView.groupSize, radix: radix,
                           offsetDigits: digits, showsText: showsText)
    }

    private var rowCount: Int64 { geometry.rowCount(forLength: length) }

    /// How many rows the view shows, fractions included.
    private var visibleRows: Double {
        Double(max(0, bounds.height - padding.height * 2) / lineHeight)
    }

    /// The furthest the rows scroll: the last row at the bottom edge.
    private var maxScroll: Double { max(0, Double(rowCount) - visibleRows) }

    private func clampScroll() {
        scrollRow = min(max(0, scrollRow), maxScroll)
        let content = padding.width * 2 + CGFloat(geometry.totalColumns) * charWidth
        panX = min(max(0, panX), max(0, content - rowsWidth))
    }

    /// When the row width changes, the first byte in view stays the first in view.
    private func geometryDidChange() {
        let perRow = geometry.bytesPerRow
        if lastBytesPerRow != 0, perRow != lastBytesPerRow {
            let firstOffset = Int64(scrollRow) * Int64(lastBytesPerRow)
            scrollRow = Double(firstOffset / Int64(perRow))
        }
        lastBytesPerRow = perRow
        clampScroll()
    }

    private func updateScroller() {
        let furthest = maxScroll
        scroller.isEnabled = furthest > 0
        scroller.doubleValue = furthest > 0 ? scrollRow / furthest : 0
        scroller.knobProportion = rowCount > 0 ? CGFloat(min(1, visibleRows / Double(rowCount))) : 1
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let width = NSScroller.scrollerWidth(for: .regular, scrollerStyle: scroller.scrollerStyle)
        scroller.frame = NSRect(x: bounds.width - width, y: 0, width: width, height: bounds.height)
        geometryDidChange()
        updateScroller()
    }

    /// Where column `column` of a row starts, in points.
    private func x(_ column: Int) -> CGFloat {
        padding.width - panX + CGFloat(column) * charWidth
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let style else { return }
        // A path composites over what is under it; `NSRect.fill()` would copy, and
        // a translucent selection would punch through to nothing.
        style.background.setFill()
        NSBezierPath(rect: bounds).fill()
        guard let buffer, buffer.length > 0 else { return }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        // The rows slide sideways under the scroller, not over it.
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: rowsWidth, height: bounds.height)).addClip()

        let g = geometry
        let rows = g.rowCount(forLength: buffer.length)
        let perRow = Int64(g.bytesPerRow)
        let firstRow = Int64(scrollRow)
        let lastRow = min(rows - 1, firstRow + Int64(ceil(visibleRows)) + 1)
        guard firstRow <= lastRow else { return }

        // One read for everything in sight.
        let windowStart = firstRow * perRow
        let data = buffer.read(windowStart..<min(buffer.length, (lastRow + 1) * perRow))
        let focused = window?.firstResponder === self
        let cellWidth = CGFloat(g.radix.cellWidth) * charWidth

        for row in firstRow...lastRow {
            let y = padding.height + CGFloat(Double(row) - scrollRow) * lineHeight
            guard y + lineHeight >= dirtyRect.minY, y <= dirtyRect.maxY else { continue }
            let rowOffset = row * perRow
            let expected = g.bytesInRow(row, length: buffer.length)
            let from = Int(rowOffset - windowStart)
            let to = min(from + expected, data.count)
            let bytes: [UInt8] = from < to ? Array(data[from..<to]) : []

            if let selection, let span = selection.indices(inRow: row, bytesPerRow: g.bytesPerRow) {
                (focused ? style.selection : style.inactiveSelection).setFill()
                let start = x(g.cellColumn(span.lowerBound))
                let end = x(g.cellColumn(span.upperBound - 1)) + cellWidth
                NSBezierPath(rect: NSRect(x: start - 1, y: y, width: end - start + 2, height: lineHeight)).fill()
                if g.showsText {
                    let textStart = x(g.textColumn(span.lowerBound))
                    let textEnd = x(g.textColumn(span.upperBound))
                    NSBezierPath(rect: NSRect(x: textStart, y: y, width: textEnd - textStart, height: lineHeight)).fill()
                }
            }

            let text = g.rowText(offset: rowOffset, bytes: bytes, expected: expected)
            let attributed = NSMutableAttributedString(
                string: text,
                attributes: [.font: HexGridNSView.font, .foregroundColor: style.text])
            attributed.addAttribute(.foregroundColor, value: style.dimText,
                                    range: NSRange(location: 0, length: g.offsetDigits))
            for (index, byte) in bytes.enumerated() {
                if byte == 0 {
                    attributed.addAttribute(.foregroundColor, value: style.dimText,
                                            range: NSRange(location: g.cellColumn(index), length: g.radix.cellWidth))
                }
                if g.showsText, !HexGeometry.isPrintable(byte) {
                    attributed.addAttribute(.foregroundColor, value: style.dimText,
                                            range: NSRange(location: g.textColumn(index), length: 1))
                }
            }
            if bytes.count < expected {
                for index in bytes.count..<expected {
                    attributed.addAttribute(.foregroundColor, value: style.missing,
                                            range: NSRange(location: g.cellColumn(index), length: g.radix.cellWidth))
                }
            }
            attributed.draw(at: NSPoint(x: x(0), y: y + 1))

            // The byte the cursor is on, outlined in both columns.
            if let selection, selection.head / perRow == row {
                let index = Int(selection.head % perRow)
                style.cursor.setStroke()
                let cell = NSRect(x: x(g.cellColumn(index)) - 1, y: y, width: cellWidth + 2, height: lineHeight)
                let outline = NSBezierPath(rect: cell.insetBy(dx: 0.5, dy: 0.5))
                outline.lineWidth = 1
                outline.stroke()
                if g.showsText {
                    let glyph = NSRect(x: x(g.textColumn(index)), y: y, width: charWidth, height: lineHeight)
                    let textOutline = NSBezierPath(rect: glyph.insetBy(dx: 0.5, dy: 0.5))
                    textOutline.lineWidth = 1
                    textOutline.stroke()
                }
            }
        }
    }

    // MARK: Mouse

    /// The byte a point in the view is on: the row it is in, and the column's byte.
    /// A point above or below the rows is the first or last row's.
    private func byteOffset(at point: NSPoint) -> Int64? {
        guard length > 0 else { return nil }
        let g = geometry
        let rows = g.rowCount(forLength: length)
        let rowPosition = scrollRow + Double((point.y - padding.height) / lineHeight)
        let row = min(max(Int64(rowPosition.rounded(.down)), 0), rows - 1)
        let column = Int(((point.x - padding.width + panX) / charWidth).rounded(.down))
        let index: Int
        switch g.hit(column: column) {
        case .cell(let i), .text(let i): index = i
        case .offset: index = 0
        case .none: index = column >= g.cellsEnd ? g.bytesPerRow - 1 : 0
        }
        return min(row * Int64(g.bytesPerRow) + Int64(index), length - 1)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if case .text = geometry.hit(column: Int(((convert(event.locationInWindow, from: nil).x - padding.width + panX) / charWidth).rounded(.down))) {
            typesInText = true
        } else {
            typesInText = false
        }
        guard let target = byteOffset(at: convert(event.locationInWindow, from: nil)) else { return }
        let anchor = event.modifierFlags.contains(.shift) ? (selection?.anchor ?? target) : target
        dragAnchor = anchor
        publish(ByteSelection(anchor: anchor, head: target))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = dragAnchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        // Past the top or bottom edge the rows follow the pointer.
        if point.y < 0 {
            scrollBy(rows: Double(point.y / lineHeight) - 1)
        } else if point.y > bounds.height {
            scrollBy(rows: Double((point.y - bounds.height) / lineHeight) + 1)
        }
        guard let target = byteOffset(at: point) else { return }
        publish(ByteSelection(anchor: anchor, head: target))
    }

    override func mouseUp(with event: NSEvent) {
        dragAnchor = nil
    }

    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas {
            panBy(-event.scrollingDeltaX)
            scrollBy(rows: Double(-event.scrollingDeltaY / lineHeight))
        } else {
            scrollBy(rows: Double(-event.scrollingDeltaY) * 3)
        }
    }

    private func scrollBy(rows delta: Double) {
        scrollRow += delta
        clampScroll()
        updateScroller()
        needsDisplay = true
    }

    private func panBy(_ delta: CGFloat) {
        panX += delta
        clampScroll()
        needsDisplay = true
    }

    @objc private func scrolled(_ sender: NSScroller) {
        switch sender.hitPart {
        case .knob, .knobSlot:
            scrollRow = Double(sender.doubleValue) * maxScroll
        case .decrementPage:
            scrollRow -= max(1, visibleRows - 1)
        case .incrementPage:
            scrollRow += max(1, visibleRows - 1)
        case .decrementLine:
            scrollRow -= 1
        case .incrementLine:
            scrollRow += 1
        default:
            return
        }
        clampScroll()
        updateScroller()
        needsDisplay = true
    }

    // MARK: Keys

    /// ⌘F opens the find bar, ⌘G goes to the next match and ⇧⌘G to the one before, when this view has the keys.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self {
            if let command = HexGridNSView.findCommand(for: event) {
                onFind?(command)
                return true
            }
            if isEditable, let edit = HexGridNSView.commandEdit(for: event) {
                onEdit?(edit)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// ⌘Z, ⇧⌘Z and ⌘S.
    private static func commandEdit(for event: NSEvent) -> HexGridEdit? {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags.contains(.command), !flags.contains(.option), !flags.contains(.control) else { return nil }
        switch (event.charactersIgnoringModifiers ?? "").lowercased() {
        case "z": return flags.contains(.shift) ? .redo : .undo
        case "s" where !flags.contains(.shift): return .save
        default: return nil
        }
    }

    /// A key that types: a hex digit in the cells, a character in the text column, or Delete.
    private static func typedEdit(for event: NSEvent, inText: Bool) -> HexGridEdit? {
        let flags = event.modifierFlags.intersection([.command, .control])
        guard flags.isEmpty else { return nil }
        switch event.keyCode {
        case 51: return .deleteBackward
        case 117: return .deleteForward
        default: break
        }
        guard event.specialKey == nil, let characters = event.characters, !characters.isEmpty else { return nil }
        if inText { return .text(characters) }
        if characters.count == 1, let digit = UInt8(characters, radix: 16) { return .hexDigit(digit) }
        return nil
    }

    private static func findCommand(for event: NSEvent) -> HexGridFindCommand? {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard flags.contains(.command), !flags.contains(.option), !flags.contains(.control) else { return nil }
        switch (event.charactersIgnoringModifiers ?? "").lowercased() {
        case "f" where !flags.contains(.shift): return .show
        case "g": return flags.contains(.shift) ? .previous : .next
        default: return nil
        }
    }

    override func keyDown(with event: NSEvent) {
        if let command = HexGridNSView.findCommand(for: event) {
            onFind?(command)
            return
        }
        if isEditable, HexGridNSView.move(for: event) == nil, let edit = HexGridNSView.typedEdit(for: event, inText: typesInText && showsText) {
            onEdit?(edit)
            return
        }
        guard let buffer, buffer.length > 0, let move = HexGridNSView.move(for: event) else {
            super.keyDown(with: event)
            return
        }
        let current = selection ?? ByteSelection(at: 0)
        let next = current.moved(move, extending: event.modifierFlags.contains(.shift),
                                 bytesPerRow: geometry.bytesPerRow, rowsPerPage: max(1, Int(visibleRows) - 1),
                                 length: buffer.length)
        publish(next)
        keepInView(next.head)
    }

    private static func move(for event: NSEvent) -> ByteSelection.Move? {
        let command = event.modifierFlags.contains(.command)
        switch event.specialKey {
        case .leftArrow?: return .left
        case .rightArrow?: return .right
        case .upArrow?: return command ? .fileStart : .up
        case .downArrow?: return command ? .fileEnd : .down
        case .pageUp?: return .pageUp
        case .pageDown?: return .pageDown
        case .home?: return command ? .fileStart : .rowStart
        case .end?: return command ? .fileEnd : .rowEnd
        default: return nil
        }
    }

    /// Scrolls just far enough that the row `offset` is in is in sight.
    private func keepInView(_ offset: Int64) {
        let row = Double(geometry.location(of: offset).row)
        if row < scrollRow {
            scrollRow = row
        } else if row + 1 > scrollRow + visibleRows {
            scrollRow = row + 1 - visibleRows
        }
        clampScroll()
        updateScroller()
        needsDisplay = true
    }

    /// The Edit menu's Copy reaches the grid when it is the one taking keys.
    @objc func copy(_ sender: Any?) {
        onCopy?()
    }

    private func publish(_ new: ByteSelection) {
        // Drawn now, not when the model's change makes its way back.
        selection = new
        needsDisplay = true
        onSelect?(new)
    }
}
