import Foundation

// The app's own look — the window frame, the rail, cards, panels and sheets —
// as a choice of themes, each with a dark and a light variant.
//
// Light or dark is still Settings → Appearance's own choice (System, Light,
// Dark); a theme only says what each of the two looks like. So every theme
// here has both, and choosing one never overrides the person's choice of
// appearance.
//
// Foundation only: the colours are numbers, so the input-logic check can hold
// every palette to its contrast floor off a Mac. `Theme` (SwiftUI) turns the
// chosen palette into colours.

/// One variant of a theme: the chrome's opaque colours, as 0xRRGGBB.
///
/// The translucent ones — borders, dividers, shadows and highlights — are not
/// here. They are black or white at an opacity, which suits any ground, and
/// `Theme` keeps one set for dark and one for light.
struct AppThemePalette: Equatable {
    let background: UInt32
    /// The top bar, the rail and the spaces panel. The frame tint mixes into
    /// this colour.
    let sidebar: UInt32
    let surface: UInt32
    let surfaceHover: UInt32
    let textPrimary: UInt32
    let textSecondary: UInt32
    /// Surfaces that float over content: the composer, popovers, menus.
    let floatingSurface: UInt32
    /// The composer's input field. Opaque, because command colours are checked
    /// for contrast against exactly this value (`SyntaxPalette`).
    let inputField: UInt32
    /// The terminal colour scheme a terminal set to "Match app" uses with this
    /// variant: an id of `TerminalTheme`.
    let terminalSchemeID: String

    /// The colours text is drawn on, for checking contrast against.
    var grounds: [UInt32] { [background, sidebar, surface, surfaceHover, floatingSurface, inputField] }
}

struct AppThemeDefinition: Identifiable, Equatable {
    let id: String
    let name: String
    /// One line for the picker.
    let summary: String
    let dark: AppThemePalette
    let light: AppThemePalette

    func palette(dark isDark: Bool) -> AppThemePalette { isDark ? dark : light }
}

enum AppThemes {
    static let defaultID = "iterminal"

    /// The lowest contrast primary and secondary text may have on any chrome
    /// colour of any theme (WCAG: 7 is AAA for body text, 4.5 is AA). The
    /// default theme clears both with room to spare; every other theme has to
    /// as well, which the input-logic check holds them to.
    static let minimumTextContrast = 7.0
    static let minimumSecondaryContrast = 4.5

    /// A stored id, made safe: one this build does not know (a newer build's,
    /// or a damaged value) is the default theme.
    static func theme(id: String) -> AppThemeDefinition {
        all.first { $0.id == id } ?? iterminal
    }

    static let all: [AppThemeDefinition] = [
        iterminal, midnight, nord, solarized, catppuccin, gruvbox, tokyoNight, rosePine, github, everforest,
    ]

    // The first is the app's look as it has always been, value for value. The
    // others take their colours from the family each is named after — its own
    // backgrounds, surfaces and text where those reach the contrast floor above,
    // and the nearest darker or lighter shade of the same hue where they do not.

    static let iterminal = AppThemeDefinition(
        id: "iterminal",
        name: "iTERMiNAL",
        summary: "The app's own neutral greys",
        dark: AppThemePalette(
            background: 0x131316, sidebar: 0x0C0C0E, surface: 0x1D1D21, surfaceHover: 0x26262B,
            textPrimary: 0xEDEDEF, textSecondary: 0x9C9CA5, floatingSurface: 0x25252B, inputField: 0x1D1D21,
            terminalSchemeID: "codex-dark"
        ),
        light: AppThemePalette(
            background: 0xFFFFFF, sidebar: 0xF7F7F8, surface: 0xF1F1F3, surfaceHover: 0xE8E8EB,
            textPrimary: 0x0D0D0F, textSecondary: 0x60606A, floatingSurface: 0xFDFDFE, inputField: 0xF1F1F3,
            terminalSchemeID: "codex-light"
        )
    )

    static let midnight = AppThemeDefinition(
        id: "midnight",
        name: "Midnight",
        summary: "Near-black, for dark rooms and OLED screens",
        dark: AppThemePalette(
            background: 0x09090B, sidebar: 0x040405, surface: 0x141417, surfaceHover: 0x1C1C20,
            textPrimary: 0xF2F2F4, textSecondary: 0x9A9AA3, floatingSurface: 0x1A1A1E, inputField: 0x141417,
            terminalSchemeID: "midnight"
        ),
        light: AppThemePalette(
            background: 0xFFFFFF, sidebar: 0xF4F5F7, surface: 0xEEEFF2, surfaceHover: 0xE4E6EA,
            textPrimary: 0x08090B, textSecondary: 0x575B63, floatingSurface: 0xFFFFFF, inputField: 0xEEEFF2,
            terminalSchemeID: "codex-light"
        )
    )

    static let nord = AppThemeDefinition(
        id: "nord",
        name: "Nord",
        summary: "Arctic blue-greys",
        dark: AppThemePalette(
            background: 0x2E3440, sidebar: 0x292E39, surface: 0x3B4252, surfaceHover: 0x434C5E,
            textPrimary: 0xECEFF4, textSecondary: 0xC0C8D6, floatingSurface: 0x434C5E, inputField: 0x3B4252,
            terminalSchemeID: "nord"
        ),
        light: AppThemePalette(
            background: 0xECEFF4, sidebar: 0xE5E9F0, surface: 0xDFE4EC, surfaceHover: 0xD8DEE9,
            textPrimary: 0x2E3440, textSecondary: 0x4C566A, floatingSurface: 0xF5F7FA, inputField: 0xE5E9F0,
            terminalSchemeID: "nord-light"
        )
    )

    static let solarized = AppThemeDefinition(
        id: "solarized",
        name: "Solarized",
        summary: "Ethan Schoonover's low-contrast classic",
        dark: AppThemePalette(
            background: 0x002B36, sidebar: 0x00232D, surface: 0x073642, surfaceHover: 0x0D4150,
            textPrimary: 0xEEE8D5, textSecondary: 0xA4B1B1, floatingSurface: 0x0C3E4B, inputField: 0x073642,
            terminalSchemeID: "solarized-dark"
        ),
        light: AppThemePalette(
            background: 0xFDF6E3, sidebar: 0xF5EEDA, surface: 0xEEE8D5, surfaceHover: 0xE6DFC9,
            textPrimary: 0x073642, textSecondary: 0x50656C, floatingSurface: 0xFFFBF0, inputField: 0xEEE8D5,
            terminalSchemeID: "solarized-light"
        )
    )

    static let catppuccin = AppThemeDefinition(
        id: "catppuccin",
        name: "Catppuccin",
        summary: "Soft pastels: Mocha and Latte",
        dark: AppThemePalette(
            background: 0x1E1E2E, sidebar: 0x181825, surface: 0x27273A, surfaceHover: 0x313244,
            textPrimary: 0xCDD6F4, textSecondary: 0xA6ADC8, floatingSurface: 0x313244, inputField: 0x27273A,
            terminalSchemeID: "catppuccin-mocha"
        ),
        light: AppThemePalette(
            background: 0xEFF1F5, sidebar: 0xE6E9EF, surface: 0xE2E5EC, surfaceHover: 0xD8DCE4,
            textPrimary: 0x363A4F, textSecondary: 0x585B73, floatingSurface: 0xF7F8FA, inputField: 0xE6E9EF,
            terminalSchemeID: "catppuccin-latte"
        )
    )

    static let gruvbox = AppThemeDefinition(
        id: "gruvbox",
        name: "Gruvbox",
        summary: "Warm, retro earth tones",
        dark: AppThemePalette(
            background: 0x282828, sidebar: 0x1D2021, surface: 0x32302F, surfaceHover: 0x3C3836,
            textPrimary: 0xEBDBB2, textSecondary: 0xBDAE93, floatingSurface: 0x3C3836, inputField: 0x32302F,
            terminalSchemeID: "gruvbox-dark"
        ),
        light: AppThemePalette(
            background: 0xFBF1C7, sidebar: 0xF2E5BC, surface: 0xEBDBB2, surfaceHover: 0xE2D2A8,
            textPrimary: 0x3C3836, textSecondary: 0x5A524C, floatingSurface: 0xFDF6DB, inputField: 0xF2E5BC,
            terminalSchemeID: "gruvbox-light"
        )
    )

    static let tokyoNight = AppThemeDefinition(
        id: "tokyo-night",
        name: "Tokyo Night",
        summary: "Deep blue night, and its Day",
        dark: AppThemePalette(
            background: 0x1A1B26, sidebar: 0x16161E, surface: 0x222332, surfaceHover: 0x292E42,
            textPrimary: 0xC0CAF5, textSecondary: 0xA0A9CB, floatingSurface: 0x292E42, inputField: 0x222332,
            terminalSchemeID: "tokyo-night"
        ),
        light: AppThemePalette(
            background: 0xE1E2E7, sidebar: 0xD6D8E0, surface: 0xD2D4DE, surfaceHover: 0xC6CAD8,
            textPrimary: 0x2A3050, textSecondary: 0x48506E, floatingSurface: 0xECEDF1, inputField: 0xD6D8E0,
            terminalSchemeID: "tokyo-night-day"
        )
    )

    static let rosePine = AppThemeDefinition(
        id: "rose-pine",
        name: "Rosé Pine",
        summary: "Muted rose and pine: Main and Dawn",
        dark: AppThemePalette(
            background: 0x191724, sidebar: 0x16141F, surface: 0x1F1D2E, surfaceHover: 0x26233A,
            textPrimary: 0xE0DEF4, textSecondary: 0xA9A5C4, floatingSurface: 0x26233A, inputField: 0x1F1D2E,
            terminalSchemeID: "rose-pine"
        ),
        light: AppThemePalette(
            background: 0xFAF4ED, sidebar: 0xF4EDE8, surface: 0xF2E9E1, surfaceHover: 0xE9DFD6,
            textPrimary: 0x433E63, textSecondary: 0x5D587B, floatingSurface: 0xFFFAF3, inputField: 0xF2E9E1,
            terminalSchemeID: "rose-pine-dawn"
        )
    )

    static let github = AppThemeDefinition(
        id: "github",
        name: "GitHub",
        summary: "GitHub's dark and light",
        dark: AppThemePalette(
            background: 0x0D1117, sidebar: 0x010409, surface: 0x161B22, surfaceHover: 0x21262D,
            textPrimary: 0xE6EDF3, textSecondary: 0x9198A1, floatingSurface: 0x1C2128, inputField: 0x161B22,
            terminalSchemeID: "github-dark"
        ),
        light: AppThemePalette(
            background: 0xFFFFFF, sidebar: 0xF6F8FA, surface: 0xEFF2F5, surfaceHover: 0xE6EAEF,
            textPrimary: 0x1F2328, textSecondary: 0x59636E, floatingSurface: 0xFFFFFF, inputField: 0xF6F8FA,
            terminalSchemeID: "github-light"
        )
    )

    static let everforest = AppThemeDefinition(
        id: "everforest",
        name: "Everforest",
        summary: "Calm greens and warm paper",
        dark: AppThemePalette(
            background: 0x2D353B, sidebar: 0x272E33, surface: 0x343F44, surfaceHover: 0x3D484D,
            textPrimary: 0xECE4CD, textSecondary: 0xB9C0AF, floatingSurface: 0x3D484D, inputField: 0x343F44,
            terminalSchemeID: "everforest-dark"
        ),
        light: AppThemePalette(
            background: 0xFDF6E3, sidebar: 0xF4F0D9, surface: 0xEFEBD4, surfaceHover: 0xE6E2CC,
            textPrimary: 0x343E44, textSecondary: 0x525F66, floatingSurface: 0xFFFBEF, inputField: 0xF4F0D9,
            terminalSchemeID: "everforest-light"
        )
    )
}
