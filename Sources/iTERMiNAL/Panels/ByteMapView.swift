import SwiftUI
import CoreGraphics

/// The map as an image, one pixel to a cell.
enum ByteMapImage {
    static func make(_ analysis: ByteMapAnalysis, coloring: ByteMapColoring) -> CGImage? {
        let side = analysis.layout.side
        let pixels = ByteMapRaster.pixels(analysis, coloring: coloring)
        guard side > 0, pixels.count == side * side * 4,
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: side,
            height: side,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

private extension ByteMapColor {
    var swiftUI: Color {
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255, opacity: 1)
    }
}

/// The Map outlook: how random each part of the file is, as a graph along it; the whole file
/// laid out as a picture, with the same kinds of byte kept together. Click or drag on the graph
/// or the picture to put the cursor there, and the dump below goes to it; the cursor is marked
/// on both.
///
/// What the numbers and the words are, and where a click lands, is `ByteMapLayout`'s and
/// `ByteMapAnalysis`'s, worked out and checked away from the view; what is here is drawing them.
struct ByteMapView: View {
    @ObservedObject var model: BytesViewerModel
    let theme: Theme
    let accent: Color
    @Environment(\.displayScale) private var displayScale
    @State private var hover: Hover?

    /// What the pointer is over.
    private enum Hover: Equatable {
        case cell(Int)
        case window(Int)
    }

    var body: some View {
        VStack(spacing: 0) {
            switch model.map {
            case .idle:
                notice("Preparing the map…")
            case .analysing(let fraction):
                progress(fraction)
            case .ready(let result):
                ready(result)
            }
        }
        .background(theme.background)
    }

    // MARK: Waiting

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(theme.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func progress(_ fraction: Double) -> some View {
        VStack(spacing: 8) {
            ProgressView(value: min(max(fraction, 0), 1))
                .progressViewStyle(.linear)
                .frame(maxWidth: 220)
            Text("Reading the file… \(Int(min(max(fraction, 0), 1) * 100))%")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: The whole

    private func ready(_ result: ByteMapResult) -> some View {
        let analysis = result.analysis
        return VStack(spacing: 0) {
            summaryBar(analysis)
            FadedDivider()
            graph(analysis)
                .frame(height: 52)
                .padding(.horizontal, 10)
                .padding(.top, 6)
            picture(result)
            legend
            FadedDivider()
            details(analysis)
        }
    }

    private func summaryBar(_ analysis: ByteMapAnalysis) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(analysis.summaryLine)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                if let note = analysis.coverageNote {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Picker("Colour the map by", selection: $model.mapColoring) {
                ForEach(ByteMapColoring.allCases, id: \.self) { coloring in
                    Text(coloring.title).tag(coloring)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Byte kinds: each square is coloured by what kinds of byte it holds · Entropy: by how random the bytes around it are")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.surface)
    }

    // MARK: The graph

    /// Entropy along the file, from the start on the left to the end on the right, 0 to 8 bits
    /// of it from the bottom to the top.
    private func graph(_ analysis: ByteMapAnalysis) -> some View {
        let layout = analysis.layout
        let cursor = model.selection.map { layout.fraction(ofOffset: $0.head) }
        var hoveredWindow: Int?
        if case .window(let window)? = hover { hoveredWindow = window }
        let highlighted = hoveredWindow
        return GeometryReader { geometry in
            Canvas { context, size in
                drawGraph(&context, size: size, analysis: analysis, cursor: cursor, highlighted: highlighted)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    let across = Double(value.location.x / max(geometry.size.width, 1))
                    model.moveCursor(to: layout.offset(atFraction: across))
                }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let across = Double(point.x / max(geometry.size.width, 1))
                    hover = .window(layout.window(containing: layout.offset(atFraction: across)))
                case .ended:
                    if case .window? = hover { hover = nil }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Entropy along the file, from 0 to 8 bits per byte")
        .accessibilityValue(analysis.summaryLine)
    }

    private func drawGraph(_ context: inout GraphicsContext, size: CGSize, analysis: ByteMapAnalysis, cursor: Double?, highlighted: Int?) {
        let layout = analysis.layout
        let width = size.width
        let height = size.height
        func level(_ bits: Double) -> CGFloat {
            height - CGFloat(min(max(bits, 0), 8) / 8) * height
        }

        for bits in [2.0, 4.0, 6.0] {
            var line = Path()
            line.move(to: CGPoint(x: 0, y: level(bits)))
            line.addLine(to: CGPoint(x: width, y: level(bits)))
            context.stroke(line, with: .color(theme.textSecondary.opacity(0.2)), lineWidth: 0.5)
        }

        var outline = Path()
        for window in 0..<analysis.windowEntropy.count {
            let span = layout.fractions(ofWindow: window)
            let left = CGFloat(span.start) * width
            let right = CGFloat(span.end) * width
            let top = level(analysis.windowEntropy[window])
            let bar = CGRect(x: left, y: top, width: max(right - left, 0.5), height: max(height - top, 0.5))
            context.fill(Path(bar), with: .color(accent.opacity(window == highlighted ? 0.9 : 0.55)))
            if window == 0 { outline.move(to: CGPoint(x: left, y: top)) }
            outline.addLine(to: CGPoint(x: left, y: top))
            outline.addLine(to: CGPoint(x: right, y: top))
        }
        context.stroke(outline, with: .color(accent), lineWidth: 1)

        context.draw(
            Text("8 bits").font(.system(size: 9)).foregroundColor(theme.textSecondary),
            at: CGPoint(x: 3, y: 1),
            anchor: .topLeading
        )
        context.draw(
            Text("0").font(.system(size: 9)).foregroundColor(theme.textSecondary),
            at: CGPoint(x: 3, y: height - 1),
            anchor: .bottomLeading
        )

        if let cursor {
            var line = Path()
            let x = CGFloat(min(max(cursor, 0), 1)) * width
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: height))
            context.stroke(line, with: .color(theme.textPrimary), lineWidth: 1.5)
        }
    }

    // MARK: The picture

    private func picture(_ result: ByteMapResult) -> some View {
        let analysis = result.analysis
        let layout = analysis.layout
        let image = result.image(for: model.mapColoring)
        let cursorCell = model.selection.map { layout.cell(containing: $0.head) }
        var hoveredCandidate: Int?
        if case .cell(let cell)? = hover { hoveredCandidate = cell }
        let hoveredCell = hoveredCandidate
        return GeometryReader { geometry in
            let edge = max(min(geometry.size.width, geometry.size.height) - 8, 16)
            // Cells are drawn crisp when each is two device pixels or more across, and smoothed when
            // they are smaller, which would otherwise drop some of them.
            let crisp = edge * displayScale >= CGFloat(layout.side) * 2
            ZStack(alignment: .topLeading) {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(crisp ? .none : .medium)
                        .frame(width: edge, height: edge)
                } else {
                    Rectangle()
                        .fill(theme.surface)
                        .frame(width: edge, height: edge)
                }
                if let hoveredCell {
                    marker(at: layout.center(ofCell: hoveredCell), cells: layout.side, edge: edge, color: theme.textPrimary.opacity(0.7), width: 1)
                }
                if let cursorCell {
                    marker(at: layout.center(ofCell: cursorCell), cells: layout.side, edge: edge, color: Color.white, width: 2)
                }
            }
            .frame(width: edge, height: edge)
            .overlay(Rectangle().strokeBorder(theme.textSecondary.opacity(0.35), lineWidth: 0.5))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    let cell = layout.cell(atFractionX: Double(value.location.x / edge), y: Double(value.location.y / edge))
                    model.moveCursor(to: layout.cellRange(cell).lowerBound)
                }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hover = .cell(layout.cell(atFractionX: Double(point.x / edge), y: Double(point.y / edge)))
                case .ended:
                    if case .cell? = hover { hover = nil }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Map of \(model.fileName): each square is a part of the file")
        .accessibilityValue(model.selection.map { analysis.cellLine(layout.cell(containing: $0.head)) } ?? "Nothing selected")
    }

    /// A ring round a cell: dark under light, so it shows on any colour.
    private func marker(at center: (x: Double, y: Double), cells: Int, edge: CGFloat, color: Color, width: CGFloat) -> some View {
        // Three cells across, but never more than half the picture, which a map of a few bytes would be.
        let diameter = min(max(edge / CGFloat(cells) * 3, 10), edge / 2)
        return ZStack {
            Circle().stroke(Color.black.opacity(0.7), lineWidth: width + 1.5)
            Circle().stroke(color, lineWidth: width)
        }
        .frame(width: diameter, height: diameter)
        .position(x: CGFloat(center.x) * edge, y: CGFloat(center.y) * edge)
        .allowsHitTesting(false)
    }

    // MARK: Legend

    @ViewBuilder
    private var legend: some View {
        switch model.mapColoring {
        case .byteClass:
            HStack(spacing: 10) {
                ForEach(ByteClass.allCases, id: \.self) { byteClass in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(ByteMapPalette.color(of: byteClass).swiftUI)
                            .frame(width: 10, height: 10)
                            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(theme.textSecondary.opacity(0.4), lineWidth: 0.5))
                        Text(byteClass.title)
                            .font(.system(size: 10))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                    .help(byteClass.detail)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        case .entropy:
            HStack(spacing: 6) {
                Text("0")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textSecondary)
                LinearGradient(
                    colors: (0...8).map { ByteMapPalette.entropyColor(Double($0)).swiftUI },
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 140, height: 8)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                Text("8 bits per byte: repetitive to random")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
    }

    // MARK: Details

    /// What is under the pointer, or if nothing is, at the cursor. It is always the same height,
    /// so the picture does not change size as the words do.
    private func details(_ analysis: ByteMapAnalysis) -> some View {
        let layout = analysis.layout
        var first = "Point at the graph or the picture, or click one to go there."
        var second = ""
        switch hover {
        case .cell(let cell)?:
            first = analysis.cellLine(cell)
            second = analysis.windowLine(layout.window(ofCell: cell))
        case .window(let window)?:
            first = analysis.windowLine(window)
        case nil:
            if let head = model.selection?.head {
                let cell = layout.cell(containing: head)
                first = analysis.cellLine(cell)
                second = analysis.windowLine(layout.window(ofCell: cell))
            }
        }
        return VStack(alignment: .leading, spacing: 2) {
            Text(first)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(2)
            Text(second)
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 54, maxHeight: 54, alignment: .topLeading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.surface)
    }
}
