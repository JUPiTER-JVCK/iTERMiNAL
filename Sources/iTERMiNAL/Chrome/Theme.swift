import SwiftUI
import AppKit

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
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
}

/// The neutral, low-chrome palette the app's ChatGPT-style shell is built on.
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

    static func current(for scheme: ColorScheme) -> Theme {
        scheme == .dark ? .dark : .light
    }

    static let dark = Theme(
        background: Color(hex: 0x212121),
        sidebar: Color(hex: 0x171717),
        surface: Color(hex: 0x2F2F2F),
        surfaceHover: Color(hex: 0x3A3A3A),
        surfaceBorder: Color.white.opacity(0.08),
        textPrimary: Color(hex: 0xECECEC),
        textSecondary: Color(hex: 0xB4B4B4),
        terminalBackground: NSColor(hex: 0x212121),
        terminalForeground: NSColor(hex: 0xECECEC)
    )

    static let light = Theme(
        background: Color.white,
        sidebar: Color(hex: 0xF9F9F9),
        surface: Color(hex: 0xF4F4F4),
        surfaceHover: Color(hex: 0xEBEBEB),
        surfaceBorder: Color.black.opacity(0.08),
        textPrimary: Color(hex: 0x0D0D0D),
        textSecondary: Color(hex: 0x5D5D5D),
        terminalBackground: NSColor.white,
        terminalForeground: NSColor(hex: 0x0D0D0D)
    )
}

struct AccentOption: Identifiable {
    let id: String
    let name: String
    let color: Color
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
