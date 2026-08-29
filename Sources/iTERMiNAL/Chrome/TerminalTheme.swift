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

    /// Twenty schemes, the app's own two plus eighteen widely used open-source
    /// palettes. Each is only colour data — the values come from the upstream
    /// projects (Catppuccin, Nord, Dracula, Gruvbox, Tokyo Night, One, Solarized,
    /// Everforest, Rosé Pine, Kanagawa, Monokai), all permissively licensed.
    static let all: [TerminalTheme] = [
        .codexDark, .codexLight, .solarizedDark, .solarizedLight, .nord, .dracula,
        .catppuccinMocha, .catppuccinMacchiato, .catppuccinFrappe, .catppuccinLatte,
        .gruvboxDark, .gruvboxLight, .tokyoNight, .tokyoNightStorm,
        .oneDark, .oneLight, .everforestDark, .rosePine, .kanagawa, .monokai,
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

    // MARK: Open-source palettes

    static let catppuccinMocha = TerminalTheme(
        id: "catppuccin-mocha",
        name: "Catppuccin Mocha",
        isDark: true,
        background: 0x1E1E2E,
        foreground: 0xCDD6F4,
        ansi: [
            0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF,
            0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xBAC2DE,
            0x585B70, 0xF38BA8, 0xA6E3A1, 0xF9E2AF,
            0x89B4FA, 0xF5C2E7, 0x94E2D5, 0xA6ADC8,
        ]
    )

    static let catppuccinMacchiato = TerminalTheme(
        id: "catppuccin-macchiato",
        name: "Catppuccin Macchiato",
        isDark: true,
        background: 0x24273A,
        foreground: 0xCAD3F5,
        ansi: [
            0x494D64, 0xED8796, 0xA6DA95, 0xEED49F,
            0x8AADF4, 0xF5BDE6, 0x8BD5CA, 0xB8C0E0,
            0x5B6078, 0xED8796, 0xA6DA95, 0xEED49F,
            0x8AADF4, 0xF5BDE6, 0x8BD5CA, 0xA5ADCB,
        ]
    )

    static let catppuccinFrappe = TerminalTheme(
        id: "catppuccin-frappe",
        name: "Catppuccin Frappé",
        isDark: true,
        background: 0x303446,
        foreground: 0xC6D0F5,
        ansi: [
            0x51576D, 0xE78284, 0xA6D189, 0xE5C890,
            0x8CAAEE, 0xF4B8E4, 0x81C8BE, 0xB5BFE2,
            0x626880, 0xE78284, 0xA6D189, 0xE5C890,
            0x8CAAEE, 0xF4B8E4, 0x81C8BE, 0xA5ADCE,
        ]
    )

    static let catppuccinLatte = TerminalTheme(
        id: "catppuccin-latte",
        name: "Catppuccin Latte",
        isDark: false,
        background: 0xEFF1F5,
        foreground: 0x4C4F69,
        ansi: [
            0x5C5F77, 0xD20F39, 0x40A02B, 0xDF8E1D,
            0x1E66F5, 0xEA76CB, 0x179299, 0xACB0BE,
            0x6C6F85, 0xD20F39, 0x40A02B, 0xDF8E1D,
            0x1E66F5, 0xEA76CB, 0x179299, 0xBCC0CC,
        ]
    )

    static let solarizedLight = TerminalTheme(
        id: "solarized-light",
        name: "Solarized Light",
        isDark: false,
        background: 0xFDF6E3,
        foreground: 0x657B83,
        ansi: [
            0x073642, 0xDC322F, 0x859900, 0xB58900,
            0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
            0x002B36, 0xCB4B16, 0x586E75, 0x657B83,
            0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3,
        ]
    )

    static let gruvboxDark = TerminalTheme(
        id: "gruvbox-dark",
        name: "Gruvbox Dark",
        isDark: true,
        background: 0x282828,
        foreground: 0xEBDBB2,
        ansi: [
            0x282828, 0xCC241D, 0x98971A, 0xD79921,
            0x458588, 0xB16286, 0x689D6A, 0xA89984,
            0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F,
            0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2,
        ]
    )

    static let gruvboxLight = TerminalTheme(
        id: "gruvbox-light",
        name: "Gruvbox Light",
        isDark: false,
        background: 0xFBF1C7,
        foreground: 0x3C3836,
        ansi: [
            0xFBF1C7, 0xCC241D, 0x98971A, 0xD79921,
            0x458588, 0xB16286, 0x689D6A, 0x7C6F64,
            0x928374, 0x9D0006, 0x79740E, 0xB57614,
            0x076678, 0x8F3F71, 0x427B58, 0x3C3836,
        ]
    )

    static let tokyoNight = TerminalTheme(
        id: "tokyo-night",
        name: "Tokyo Night",
        isDark: true,
        background: 0x1A1B26,
        foreground: 0xC0CAF5,
        ansi: [
            0x15161E, 0xF7768E, 0x9ECE6A, 0xE0AF68,
            0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
            0x414868, 0xF7768E, 0x9ECE6A, 0xE0AF68,
            0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC0CAF5,
        ]
    )

    static let tokyoNightStorm = TerminalTheme(
        id: "tokyo-night-storm",
        name: "Tokyo Night Storm",
        isDark: true,
        background: 0x24283B,
        foreground: 0xC0CAF5,
        ansi: [
            0x1D202F, 0xF7768E, 0x9ECE6A, 0xE0AF68,
            0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
            0x414868, 0xF7768E, 0x9ECE6A, 0xE0AF68,
            0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xC0CAF5,
        ]
    )

    static let oneDark = TerminalTheme(
        id: "one-dark",
        name: "One Dark",
        isDark: true,
        background: 0x282C34,
        foreground: 0xABB2BF,
        ansi: [
            0x282C34, 0xE06C75, 0x98C379, 0xE5C07B,
            0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
            0x5C6370, 0xE06C75, 0x98C379, 0xE5C07B,
            0x61AFEF, 0xC678DD, 0x56B6C2, 0xFFFFFF,
        ]
    )

    static let oneLight = TerminalTheme(
        id: "one-light",
        name: "One Light",
        isDark: false,
        background: 0xFAFAFA,
        foreground: 0x383A42,
        ansi: [
            0x383A42, 0xE45649, 0x50A14F, 0xC18401,
            0x4078F2, 0xA626A4, 0x0184BC, 0xA0A1A7,
            0x4F525E, 0xE45649, 0x50A14F, 0xC18401,
            0x4078F2, 0xA626A4, 0x0184BC, 0x383A42,
        ]
    )

    static let everforestDark = TerminalTheme(
        id: "everforest-dark",
        name: "Everforest Dark",
        isDark: true,
        background: 0x2D353B,
        foreground: 0xD3C6AA,
        ansi: [
            0x475258, 0xE67E80, 0xA7C080, 0xDBBC7F,
            0x7FBBB3, 0xD699B6, 0x83C092, 0xD3C6AA,
            0x5C6A72, 0xE67E80, 0xA7C080, 0xDBBC7F,
            0x7FBBB3, 0xD699B6, 0x83C092, 0xF2EFDF,
        ]
    )

    static let rosePine = TerminalTheme(
        id: "rose-pine",
        name: "Rosé Pine",
        isDark: true,
        background: 0x191724,
        foreground: 0xE0DEF4,
        ansi: [
            0x26233A, 0xEB6F92, 0x31748F, 0xF6C177,
            0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4,
            0x6E6A86, 0xEB6F92, 0x31748F, 0xF6C177,
            0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4,
        ]
    )

    static let kanagawa = TerminalTheme(
        id: "kanagawa",
        name: "Kanagawa",
        isDark: true,
        background: 0x1F1F28,
        foreground: 0xDCD7BA,
        ansi: [
            0x16161D, 0xC34043, 0x76946A, 0xC0A36E,
            0x7E9CD8, 0x957FB8, 0x6A9589, 0xC8C093,
            0x727169, 0xE82424, 0x98BB6C, 0xE6C384,
            0x7FB4CA, 0x938AA9, 0x7AA89F, 0xDCD7BA,
        ]
    )

    static let monokai = TerminalTheme(
        id: "monokai",
        name: "Monokai",
        isDark: true,
        background: 0x272822,
        foreground: 0xF8F8F2,
        ansi: [
            0x272822, 0xF92672, 0xA6E22E, 0xF4BF75,
            0x66D9EF, 0xAE81FF, 0xA1EFE4, 0xF8F8F2,
            0x75715E, 0xF92672, 0xA6E22E, 0xF4BF75,
            0x66D9EF, 0xAE81FF, 0xA1EFE4, 0xF9F8F5,
        ]
    )

}
