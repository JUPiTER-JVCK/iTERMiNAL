import SwiftUI
import AppKit

/// The Files pane's preview text: read-only, selectable, with line numbers
/// down the left edge, either wrapping long lines to the pane's width or
/// scrolling sideways.
///
/// This is an `NSTextView` rather than a stack of SwiftUI `Text` rows. A row
/// that is wider than the pane — a long line with sideways scrolling, or a
/// long unbroken token with wrapping — widens the whole stack past the pane,
/// and the lines end up shifted out of view. A text view lays itself out
/// against its scroll view, whichever way long lines are handled, and takes
/// the preview's cap of several thousand lines without building a view each.
struct FilePreviewTextView: NSViewRepresentable {
    let text: String
    /// Wrap long lines to the width of the pane; off, scroll sideways instead.
    let wrap: Bool
    let textColor: NSColor
    let numberColor: NSColor

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    /// What was last handed to the views, so a SwiftUI update that changes
    /// nothing does not re-set, and so re-lay-out, a file of up to 2 MB.
    final class Coordinator {
        var text: String?
        var wrap: Bool?
        var textColor: NSColor?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        // A TextKit 1 stack, built by hand: the line numbers read the layout
        // manager, and asking a TextKit 2 view for one switches it over in the
        // middle of its life.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        // A placeholder width until the scroll view has one, so the text is
        // not first laid out one character to a line.
        let container = NSTextContainer(size: NSSize(width: 400, height: Self.unbounded))
        layout.addTextContainer(container)

        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 0),
                              textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.font = Self.font
        view.textColor = textColor
        view.textContainerInset = NSSize(width: 6, height: 6)
        view.minSize = .zero
        view.maxSize = NSSize(width: Self.unbounded, height: Self.unbounded)
        view.isVerticallyResizable = true

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = view

        let ruler = FilePreviewLineNumbers(scrollView: scroll, textView: view,
                                           font: Self.font, color: numberColor)
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true

        Self.applyWrap(wrap, to: scroll, view: view)
        view.string = text
        ruler.reload(text: text)
        context.coordinator.text = text
        context.coordinator.wrap = wrap
        context.coordinator.textColor = textColor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView,
              let ruler = scroll.verticalRulerView as? FilePreviewLineNumbers else { return }
        let coordinator = context.coordinator

        if coordinator.textColor != textColor {
            coordinator.textColor = textColor
            view.textColor = textColor
        }
        ruler.color = numberColor

        if coordinator.wrap != wrap {
            coordinator.wrap = wrap
            Self.applyWrap(wrap, to: scroll, view: view)
        }
        if coordinator.text != text {
            coordinator.text = text
            view.string = text
            ruler.reload(text: text)
            // A different file starts at its top and its left edge.
            view.scroll(.zero)
        }
        ruler.needsDisplay = true
    }

    /// Stands in for "no limit" along an axis. AppKit's own documentation
    /// uses `FLT_MAX` here; a `Double` maximum can overflow once the insets
    /// are added to it.
    private static let unbounded = CGFloat(Float.greatestFiniteMagnitude)

    /// Wrapping tracks the scroll view's width; not wrapping lets the text
    /// run as wide as its longest line and turns on the horizontal scroller.
    private static func applyWrap(_ wrap: Bool, to scroll: NSScrollView, view: NSTextView) {
        guard let container = view.textContainer else { return }
        scroll.hasHorizontalScroller = !wrap
        view.isHorizontallyResizable = !wrap
        view.autoresizingMask = wrap ? [.width] : []
        container.widthTracksTextView = wrap
        if wrap {
            let width = scroll.contentSize.width
            // Zero before the view has been laid out: the container follows
            // the view's width from then on, so there is nothing to set yet.
            if width > 0 {
                view.setFrameSize(NSSize(width: width, height: view.frame.height))
                container.containerSize = NSSize(width: width, height: unbounded)
            }
        } else {
            container.containerSize = NSSize(width: unbounded, height: unbounded)
        }
        // No `sizeToFit()`: it lays out the whole file at once. Changing the
        // container's size invalidates the layout, and the view resizes itself
        // as the lines are laid out.
        view.needsDisplay = true
    }
}

/// Line numbers for a text view, one per line of the file. A line that wraps
/// is numbered once, on its first row.
final class FilePreviewLineNumbers: NSRulerView {
    private weak var textView: NSTextView?
    private var font: NSFont
    /// UTF-16 offset at which each line of the text starts, which is the unit
    /// the layout manager counts characters in.
    private var lineStarts: [Int] = [0]

    var color: NSColor {
        didSet { if color != oldValue { needsDisplay = true } }
    }

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color]
    }

    init(scrollView: NSScrollView, textView: NSTextView, font: NSFont, color: NSColor) {
        self.textView = textView
        self.font = font
        self.color = color
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = Self.thickness(forLineCount: 1, font: font)

        // Scrolling redraws a ruler by itself. A change of wrapping or of the
        // pane's width re-flows the text without scrolling it, so those need
        // asking for.
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(layoutChanged),
            name: NSView.frameDidChangeNotification, object: textView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(layoutChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    required init(coder: NSCoder) {
        fatalError("FilePreviewLineNumbers is built in code")
    }

    @objc private func layoutChanged() {
        needsDisplay = true
    }

    /// Recounts the lines and widens the gutter to fit the largest number.
    func reload(text: String) {
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 0x0A { starts.append(offset) }
        }
        lineStarts = starts
        ruleThickness = Self.thickness(forLineCount: starts.count, font: font)
        needsDisplay = true
    }

    private static func thickness(forLineCount count: Int, font: NSFont) -> CGFloat {
        // At least three digits wide, so the text does not shift sideways
        // between a short file and a longer one.
        let digits = max(3, String(count).count)
        let digit = ("0" as NSString).size(withAttributes: [.font: font]).width
        return ceil(CGFloat(digits) * digit) + 18
    }

    /// The number of the line that starts at `offset`, or nil when `offset`
    /// is partway along a line — the second and later rows of a wrapped one.
    private func lineNumber(startingAt offset: Int) -> Int? {
        var low = 0
        var high = lineStarts.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let start = lineStarts[middle]
            if start == offset { return middle + 1 }
            if start < offset { low = middle + 1 } else { high = middle - 1 }
        }
        return nil
    }

    /// Draws only the numbers: the stock ruler paints a background of its own
    /// that would show as a grey strip against the pane.
    override func draw(_ dirtyRect: NSRect) {
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layout = textView.layoutManager,
              let container = textView.textContainer,
              let clip = scrollView?.contentView else { return }

        // The layout manager's rectangles are in the text container's
        // coordinates, which sit inside the view by the container's origin.
        let origin = textView.textContainerOrigin
        let visible = clip.bounds.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let attributes = self.attributes

        layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, glyphRange, _ in
            let characters = layout.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
            guard let number = self.lineNumber(startingAt: characters.location) else { return }

            // Converting a rectangle rather than a point keeps this right
            // whichever way up the ruler's coordinates run.
            let row = self.convert(
                NSRect(x: 0, y: fragment.minY + origin.y, width: 1, height: fragment.height),
                from: textView)
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(
                in: NSRect(x: self.bounds.width - size.width - 8,
                           y: row.minY + (row.height - size.height) / 2,
                           width: size.width, height: size.height),
                withAttributes: attributes)
        }
    }
}
