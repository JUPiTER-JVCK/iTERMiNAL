import SwiftUI
import AppKit

extension Color {
    /// sRGB, for values that must match a specific web colour exactly.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1.0
        )
    }

    /// Display P3, the wide gamut every Retina display since 2016 can show.
    /// Chrome colours use this so gradients and near-blacks step smoothly
    /// instead of banding through the smaller sRGB space.
    init(p3 hex: UInt32) {
        self.init(
            .displayP3,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1.0
        )
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }

    convenience init(p3 hex: UInt32) {
        self.init(
            displayP3Red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}

/// The neutral, low-chrome palette the app's shell is built on.
///
/// Dark values sit deeper than the reference app's, but deliberately short of
/// true black: the elevation shadows below need somewhere to fall, and against
/// #000 they stop reading at all.
struct Theme {
    let background: Color
    let sidebar: Color
    let surface: Color
    let surfaceHover: Color
    let surfaceBorder: Color
    let textPrimary: Color
    let textSecondary: Color
    let terminalBackground: NSColor
    let terminalForeground: NSColor
    /// Cast under surfaces that float — composer, cards, popovers.
    let elevatedShadow: Color
    /// Hairline that catches light along the top edge of a raised surface.
    let elevatedHighlight: Color
    /// Structural seams between regions.
    let divider: Color
    /// Fill for surfaces that float over content. Deliberately further from
    /// `background` than `surface` is, so a floating panel never reads as
    /// painted onto the window behind it.
    let floatingSurface: Color

    static func current(for scheme: ColorScheme) -> Theme {
        scheme == .dark ? .dark : .light
    }

    static let dark = Theme(
        background: Color(p3: 0x131316),
        sidebar: Color(p3: 0x0C0C0E),
        surface: Color(p3: 0x1D1D21),
        surfaceHover: Color(p3: 0x26262B),
        surfaceBorder: Color.white.opacity(0.07),
        textPrimary: Color(p3: 0xEDEDEF),
        textSecondary: Color(p3: 0x9C9CA5),
        terminalBackground: NSColor(p3: 0x131316),
        terminalForeground: NSColor(p3: 0xEDEDEF),
        elevatedShadow: Color.black.opacity(0.55),
        elevatedHighlight: Color.white.opacity(0.06),
        divider: Color.white.opacity(0.09),
        floatingSurface: Color(p3: 0x25252B)
    )

    static let light = Theme(
        background: Color(p3: 0xFFFFFF),
        sidebar: Color(p3: 0xF7F7F8),
        surface: Color(p3: 0xF1F1F3),
        surfaceHover: Color(p3: 0xE8E8EB),
        surfaceBorder: Color.black.opacity(0.08),
        textPrimary: Color(p3: 0x0D0D0F),
        textSecondary: Color(p3: 0x60606A),
        terminalBackground: NSColor.white,
        terminalForeground: NSColor(p3: 0x0D0D0F),
        elevatedShadow: Color.black.opacity(0.13),
        elevatedHighlight: Color.white.opacity(0.9),
        divider: Color.black.opacity(0.08),
        floatingSurface: Color(p3: 0xFDFDFE)
    )
}

// MARK: - Depth

/// Lifts a surface off the background: a soft shadow plus a hairline
/// highlight along the top edge, which is what stops a flat card reading as
/// a painted rectangle.
struct ElevatedSurface: ViewModifier {
    var cornerRadius: CGFloat = 14
    var radius: CGFloat = 14
    var y: CGFloat = 4
    /// Overridable so hover states can brighten the surface — a shadow
    /// growing on its own is weak feedback.
    var fill: Color?

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let theme = Theme.current(for: colorScheme)
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill ?? theme.surface)
                    .shadow(color: theme.elevatedShadow, radius: radius, y: y)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [theme.elevatedHighlight, theme.surfaceBorder],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
    }
}

extension View {
    func elevated(
        cornerRadius: CGFloat = 14,
        radius: CGFloat = 14,
        y: CGFloat = 4,
        fill: Color? = nil
    ) -> some View {
        modifier(ElevatedSurface(cornerRadius: cornerRadius, radius: radius, y: y, fill: fill))
    }
}

/// A structural seam whose ends fade out, so long runs stop reading as hard
/// ruled lines drawn across the window.
struct FadedDivider: View {
    enum Axis { case horizontal, vertical }

    var axis: Axis = .horizontal
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        Rectangle()
            .fill(theme.divider)
            .frame(
                width: axis == .vertical ? 1 : nil,
                height: axis == .horizontal ? 1 : nil
            )
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.12),
                        .init(color: .black, location: 0.88),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: axis == .horizontal ? .leading : .top,
                    endPoint: axis == .horizontal ? .trailing : .bottom
                )
            )
    }
}

struct AccentOption: Identifiable {
    let id: String
    let name: String
    let color: Color
}

/// Per-item colour identity, the way the reference app gives every project
/// its own glyph colour instead of a wall of uniform grey.
///
/// The colour is derived from the item's UUID, so it is stable across
/// relaunches without needing to be stored, and two workspaces created in the
/// same order always look the same as each other.
enum IdentityPalette {
    static let colors: [Color] = [
        Color(p3: 0x5B8DEF),  // blue
        Color(p3: 0x9B7BEA),  // violet
        Color(p3: 0x3FB68B),  // green
        Color(p3: 0xE8833A),  // orange
        Color(p3: 0xE0609C),  // pink
        Color(p3: 0x46B0C7),  // teal
        Color(p3: 0xD4A73C),  // amber
    ]

    static func color(for id: UUID) -> Color {
        // Fold the UUID's bytes rather than using hashValue, which Swift
        // seeds per-process and would repaint everything on every launch.
        let sum = withUnsafeBytes(of: id.uuid) { bytes in
            bytes.reduce(0) { $0 &+ Int($1) }
        }
        return colors[sum % colors.count]
    }
}

enum Accents {
    static let all: [AccentOption] = [
        AccentOption(id: "green", name: "Green", color: Color(hex: 0x10A37F)),
        AccentOption(id: "blue", name: "Blue", color: Color(hex: 0x3B82F6)),
        AccentOption(id: "purple", name: "Purple", color: Color(hex: 0x8B5CF6)),
        AccentOption(id: "orange", name: "Orange", color: Color(hex: 0xF97316)),
        AccentOption(id: "pink", name: "Pink", color: Color(hex: 0xEC4899)),
        AccentOption(id: "graphite", name: "Graphite", color: Color(hex: 0x8E8EA0)),
    ]

    static func color(for id: String) -> Color {
        all.first { $0.id == id }?.color ?? all[0].color
    }
}

/// Frosted background used behind the sidebar so it picks up desktop tint
/// the way modern macOS apps do.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
