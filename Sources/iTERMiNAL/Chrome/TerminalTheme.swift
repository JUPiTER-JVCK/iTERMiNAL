import AppKit

/// One entry of the 16-color ANSI palette, in 8-bit components.
struct PaletteColor: Equatable {
    let red: UInt16
    let green: UInt16
    let blue: UInt16

    init(_ hex: UInt32) {
        red = UInt16((hex >> 16) & 0xFF)
        green = UInt16((hex >> 8) & 0xFF)
        blue = UInt16(hex & 0xFF)
    }
}

/// A terminal color scheme: window background/foreground plus the 16 ANSI
/// colors (8 normal, 8 bright) that SwiftTerm installs as its palette.
struct TerminalTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let isDark: Bool
    let background: UInt32
    let foreground: UInt32
    let ansi: [UInt32]

    var backgroundColor: NSColor { NSColor(hex: background) }
    var foregroundColor: NSColor { NSColor(hex: foreground) }
    var palette: [PaletteColor] { ansi.map { PaletteColor($0) } }

    static func theme(id: String, darkMode: Bool) -> TerminalTheme {
        if id == "auto" || id.isEmpty {
            return darkMode ? .codexDark : .codexLight
        }
        return all.first { $0.id == id } ?? (darkMode ? .codexDark : .codexLight)
    }

    static let all: [TerminalTheme] = [
        .codexDark, .codexLight, .solarizedDark, .nord, .dracula,
    ]

    /// Matches the app chrome's dark palette.
    static let codexDark = TerminalTheme(
        id: "codex-dark",
        name: "iTERMiNAL Dark",
        isDark: true,
        background: 0x212121,
        foreground: 0xECECEC,
        ansi: [
            0x2B2B2B, 0xE05561, 0x8CC265, 0xD18F52,
            0x4AA5F0, 0xC162DE, 0x42B3C2, 0xD7D7D7,
            0x666666, 0xFF6E6E, 0xA5E075, 0xF0A45D,
            0x63B0F2, 0xD26FEE, 0x54C4D4, 0xFFFFFF,
        ]
    )

    /// Matches the app chrome's light palette.
    static let codexLight = TerminalTheme(
        id: "codex-light",
        name: "iTERMiNAL Light",
        isDark: false,
        background: 0xFFFFFF,
        foreground: 0x0D0D0D,
        ansi: [
            0x2E2E2E, 0xC91B00, 0x00A250, 0xA07400,
            0x0072C3, 0xA018B8, 0x0087A8, 0x5D5D5D,
            0x8E8E8E, 0xE0402F, 0x18B36B, 0xC08A00,
            0x2B8FE0, 0xB93FCC, 0x14A0BE, 0x1A1A1A,
        ]
    )

    static let solarizedDark = TerminalTheme(
        id: "solarized-dark",
        name: "Solarized Dark",
        isDark: true,
        background: 0x002B36,
        foreground: 0x839496,
        ansi: [
            0x073642, 0xDC322F, 0x859900, 0xB58900,
            0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
            0x002B36, 0xCB4B16, 0x586E75, 0x657B83,
            0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3,
        ]
    )

    static let nord = TerminalTheme(
        id: "nord",
        name: "Nord",
        isDark: true,
        background: 0x2E3440,
        foreground: 0xD8DEE9,
        ansi: [
            0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B,
            0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
            0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B,
            0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4,
        ]
    )

    static let dracula = TerminalTheme(
        id: "dracula",
        name: "Dracula",
        isDark: true,
        background: 0x282A36,
        foreground: 0xF8F8F2,
        ansi: [
            0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C,
            0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
            0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5,
            0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF,
        ]
    )
}
