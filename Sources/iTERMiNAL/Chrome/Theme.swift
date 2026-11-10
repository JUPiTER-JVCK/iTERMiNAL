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
    /// The tight, dark shadow right under a raised surface's edge — where it
    /// meets what it floats over. Paired with `elevatedShadow`, the soft,
    /// wide one, so a surface reads as lit from above rather than smudged.
    let contactShadow: Color
    /// Light falling on the top of a raised surface: a wash that fades out
    /// down its face, which is what makes a flat fill read as glass.
    let sheen: Color
    /// Structural seams between regions.
    let divider: Color
    /// Fill for surfaces that float over content. Deliberately further from
    /// `background` than `surface` is, so a floating panel never reads as
    /// painted onto the window behind it.
    let floatingSurface: Color

    /// The chrome for an appearance, in the chosen app theme (`AppThemes`).
    ///
    /// Views pass the `appThemeID` they read from the environment rather than
    /// the setting itself: reading it is what has SwiftUI draw them again when
    /// the theme changes (see `EnvironmentValues.appThemeID`).
    static func current(for scheme: ColorScheme, themeID: String) -> Theme {
        let dark = scheme == .dark
        return Theme(palette: AppThemes.theme(id: themeID).palette(dark: dark), dark: dark)
    }

    /// The chrome color — the top bar, the rail, and the workspaces panel —
    /// read from the palette in one place so the frame tint (see `FrameStyle`)
    /// mixes into exactly the color the theme paints, not a copy that could
    /// drift.
    static func sidebarHex(for scheme: ColorScheme, themeID: String) -> UInt32 {
        AppThemes.theme(id: themeID).palette(dark: scheme == .dark).sidebar
    }

    static func floatingSurfaceHex(for scheme: ColorScheme, themeID: String) -> UInt32 {
        AppThemes.theme(id: themeID).palette(dark: scheme == .dark).floatingSurface
    }

    /// The composer's input field, as an opaque colour.
    ///
    /// Opaque on purpose, and in hex: the command colours are chosen for
    /// contrast against exactly this value, which only holds if nothing shows
    /// through it — the card around it can be translucent over arbitrary
    /// terminal content. Read from the palette so the colour and what is
    /// measured against it cannot drift apart.
    static func inputFieldHex(for scheme: ColorScheme, themeID: String) -> UInt32 {
        AppThemes.theme(id: themeID).palette(dark: scheme == .dark).inputField
    }

    /// The opaque colours come from the palette; the translucent ones are
    /// white or black at an opacity, one set for dark and one for light, which
    /// reads on any theme's ground.
    init(palette: AppThemePalette, dark: Bool) {
        background = Color(p3: palette.background)
        sidebar = Color(p3: palette.sidebar)
        surface = Color(p3: palette.surface)
        surfaceHover = Color(p3: palette.surfaceHover)
        textPrimary = Color(p3: palette.textPrimary)
        textSecondary = Color(p3: palette.textSecondary)
        terminalBackground = NSColor(p3: palette.background)
        terminalForeground = NSColor(p3: palette.textPrimary)
        floatingSurface = Color(p3: palette.floatingSurface)
        if dark {
            surfaceBorder = Color.white.opacity(0.07)
            elevatedShadow = Color.black.opacity(0.45)
            elevatedHighlight = Color.white.opacity(0.10)
            contactShadow = Color.black.opacity(0.35)
            sheen = Color.white.opacity(0.035)
            divider = Color.white.opacity(0.09)
        } else {
            surfaceBorder = Color.black.opacity(0.08)
            elevatedShadow = Color.black.opacity(0.12)
            elevatedHighlight = Color.white.opacity(0.9)
            contactShadow = Color.black.opacity(0.08)
            sheen = Color.white.opacity(0.45)
            divider = Color.black.opacity(0.08)
        }
    }
}

// MARK: - Which theme is showing

private struct AppThemeIDKey: EnvironmentKey {
    static let defaultValue = AppThemes.defaultID
}

extension EnvironmentValues {
    /// The app theme every view draws its chrome in, set once at the root of
    /// each window from `AppSettings.appThemeID`.
    ///
    /// An environment value rather than a read of the setting, because SwiftUI
    /// draws a view again when an environment value it reads changes, and only
    /// then: a view that read `AppSettings.shared` directly would keep its old
    /// colours until something else happened to redraw it. Every view that
    /// asks `Theme.current(for:themeID:)` reads this beside `colorScheme`.
    var appThemeID: String {
        get { self[AppThemeIDKey.self] }
        set { self[AppThemeIDKey.self] = newValue }
    }
}

// MARK: - Depth

/// Lifts a surface off the background the way light would: a soft, wide
/// ambient shadow and a tight contact shadow under the edge, a sheen across
/// the top of its face, and a rim that catches the light along the top edge
/// and fades into a hairline down the sides. Every floating surface — the
/// composer, cards, the floating workspaces panel — goes through here, so
/// they are lit by the same light.
struct ElevatedSurface: ViewModifier {
    var cornerRadius: CGFloat = 14
    var radius: CGFloat = 14
    var y: CGFloat = 4
    /// Overridable so hover states can brighten the surface — a shadow
    /// growing on its own is weak feedback.
    var fill: Color?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID

    func body(content: Content) -> some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(
                ZStack {
                    shape
                        .fill(fill ?? theme.surface)
                        // Contact first, then ambient: the second is cast from
                        // the first's silhouette, which is the same shape.
                        .shadow(color: theme.contactShadow, radius: 1.5, y: 1)
                        .shadow(color: theme.elevatedShadow, radius: radius, y: y)
                    // Light on the face, strongest at the top and gone by the
                    // middle. Behind the content, so it never washes text out.
                    shape
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: theme.sheen, location: 0),
                                    .init(color: theme.sheen.opacity(0), location: 0.55),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
            )
            .overlay(
                shape
                    .strokeBorder(
                        LinearGradient(
                            colors: [theme.elevatedHighlight, theme.surfaceBorder],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                    .allowsHitTesting(false)
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
    @Environment(\.appThemeID) private var appThemeID

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
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
    let hex: UInt32

    var color: Color { Color(hex: hex) }
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
    /// In the order of the spectrum, which is how the picker shows them. The
    /// ids are what is stored, so the order can change without moving anyone's
    /// choice.
    static let all: [AccentOption] = [
        AccentOption(id: "red", name: "Red", hex: 0xEF4444),
        AccentOption(id: "orange", name: "Orange", hex: 0xF97316),
        AccentOption(id: "amber", name: "Amber", hex: 0xF59E0B),
        AccentOption(id: "lime", name: "Lime", hex: 0x65A30D),
        AccentOption(id: "green", name: "Green", hex: 0x10A37F),
        AccentOption(id: "teal", name: "Teal", hex: 0x14B8A6),
        AccentOption(id: "sky", name: "Sky", hex: 0x0EA5E9),
        AccentOption(id: "blue", name: "Blue", hex: 0x3B82F6),
        AccentOption(id: "indigo", name: "Indigo", hex: 0x6366F1),
        AccentOption(id: "purple", name: "Purple", hex: 0x8B5CF6),
        AccentOption(id: "pink", name: "Pink", hex: 0xEC4899),
        AccentOption(id: "graphite", name: "Graphite", hex: 0x8E8EA0),
    ]

    /// What an id this build does not know falls back to: the default accent,
    /// which is no longer the first in the list.
    static let defaultID = "green"

    private static func option(for id: String) -> AccentOption {
        all.first { $0.id == id } ?? all.first { $0.id == defaultID }!
    }

    static func color(for id: String) -> Color {
        option(for: id).color
    }

    /// The accent as 0xRRGGBB, for the frame tint to mix with.
    static func hex(for id: String) -> UInt32 {
        option(for: id).hex
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
