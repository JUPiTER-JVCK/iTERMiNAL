import Foundation

/// Dresses btop and superfile in the terminal's own colours, and keeps them
/// dressed when those colours change — a new theme, or the switch between
/// light and dark.
///
/// Both tools shipped painting a theme of their own: btop a near-black
/// background, superfile Catppuccin Mocha. Beside a light terminal, or any
/// theme but those two, the panel read as a different app — and it stayed
/// that way through a switch to dark mode, because neither knew anything had
/// changed.
///
/// They are dressed differently because they accept different things:
///
/// - superfile takes colours as ANSI palette numbers — "4", not "#0072C3" —
///   and can leave the background and body text to the terminal. What it
///   draws then *is* the terminal's palette, so a theme change restyles it on
///   the spot: nothing to rewrite, restart or signal.
/// - btop takes only literal colours. It gets a theme generated from the
///   terminal's palette, with the background left to the terminal, and is
///   told to reload — SIGUSR2, its documented hot-reload signal — whenever
///   the palette changes.
///
/// Each reads its configuration from files this app owns, named on the
/// command line, so a copy of either tool the user installed separately keeps
/// its own settings. The one exception is superfile's theme, which it reads
/// only from its own theme folder: the app adds `iterminal.toml` there and
/// touches nothing else in it.
enum ToolTheming {
    /// The name both tools know the generated theme by.
    static let themeName = "iterminal"

    /// `~/Library/Application Support/iTERMiNAL/Tools`.
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("iTERMiNAL", isDirectory: true)
            .appendingPathComponent("Tools", isDirectory: true)
    }()

    private static var btopDirectory: URL {
        directory.appendingPathComponent("btop", isDirectory: true)
    }

    static var btopConfigURL: URL {
        btopDirectory.appendingPathComponent("btop.conf")
    }

    static var btopThemesDirectory: URL {
        btopDirectory.appendingPathComponent("themes", isDirectory: true)
    }

    static var superfileConfigURL: URL {
        directory
            .appendingPathComponent("superfile", isDirectory: true)
            .appendingPathComponent("config.toml")
    }

    /// Where superfile reads themes. Its config file can be moved with a
    /// flag; its theme folder cannot, and sits under the XDG config home —
    /// on macOS, Application Support unless `XDG_CONFIG_HOME` holds an
    /// absolute path, after `~` or `$HOME` is expanded. That is the rule its
    /// xdg library applies, repeated here so both land on the same folder.
    /// superfile inherits this app's environment, so both read the same
    /// variable.
    static var superfileThemeDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var base = (home as NSString).appendingPathComponent("Library/Application Support")
        if var value = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !value.isEmpty {
            if value.hasPrefix("~") {
                value = home + value.dropFirst()
            } else if value.hasPrefix("$HOME") {
                value = home + value.dropFirst("$HOME".count)
            }
            if value.hasPrefix("/") {
                base = value
            }
        }
        return URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent("superfile", isDirectory: true)
            .appendingPathComponent("theme", isDirectory: true)
    }

    // MARK: Launching and following

    /// The theme each tool's files were last written for.
    private static var written: [TerminalTool: TerminalTheme] = [:]

    /// Arguments that point `tool` at configuration dressed in `theme`,
    /// written before this returns so the first frame is already right.
    ///
    /// Empty if the files could not be written. The tool then starts on its
    /// own defaults — mismatched colours, but running — rather than being
    /// pointed at a themes folder that does not exist, which btop refuses
    /// outright.
    static func launchArguments(for tool: TerminalTool, theme: TerminalTheme) -> [String] {
        guard write(theme, for: tool) else { return [] }
        switch tool {
        case .btop:
            return ["--config", btopConfigURL.path, "--themes-dir", btopThemesDirectory.path]
        case .superfile:
            return ["--config-file", superfileConfigURL.path]
        }
    }

    /// Rewrites `tool`'s files for `theme` if they were last written for
    /// another. True when they changed — the moment a running btop needs
    /// telling. superfile's colours already follow the palette, so for it
    /// this only keeps the syntax colours and progress bar right for the
    /// next launch.
    static func follow(_ theme: TerminalTheme, tool: TerminalTool) -> Bool {
        guard written[tool] != theme else { return false }
        return write(theme, for: tool)
    }

    private static func write(_ theme: TerminalTheme, for tool: TerminalTool) -> Bool {
        do {
            switch tool {
            case .btop: try writeBtop(theme)
            case .superfile: try writeSuperfile(theme)
            }
            written[tool] = theme
            return true
        } catch {
            NSLog("iTERMiNAL: could not write the \(tool.title) configuration: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: btop

    private static func writeBtop(_ theme: TerminalTheme) throws {
        try FileManager.default.createDirectory(at: btopThemesDirectory, withIntermediateDirectories: true)
        // Atomic, because a running btop rereads this file on SIGUSR2 and
        // must never find half of one.
        try btopTheme(for: theme).write(
            to: btopThemesDirectory.appendingPathComponent("\(themeName).theme"),
            atomically: true,
            encoding: .utf8
        )
        try setConfig(
            [("color_theme", "\"\(themeName)\"")],
            in: btopConfigURL,
            creatingWith: """
            #? btop configuration for the copy bundled with iTERMiNAL. iTERMiNAL
            #? keeps color_theme on the theme it generates from the terminal's
            #? colours; btop writes every other setting here itself.

            """
        )
    }

    /// A btop theme in the terminal's colours.
    ///
    /// Background left empty, which btop draws as the terminal's own — the
    /// same pixels as the panel behind it, translucency included. Text is the
    /// terminal's foreground; the quiet parts — dividers, meter tracks,
    /// inactive items — are that foreground faded toward the background, so
    /// they stay quiet on light themes and dark alike. Graphs use the
    /// palette's own red, green, yellow, blue, magenta and cyan, and the
    /// memory and network graphs fade in from the background colour as btop's
    /// own theme does, starting from this background instead of black.
    static func btopTheme(for theme: TerminalTheme) -> String {
        let bg = theme.background
        let fg = theme.foreground
        let red = theme.ansi[1], green = theme.ansi[2], yellow = theme.ansi[3]
        let blue = theme.ansi[4], magenta = theme.ansi[5], cyan = theme.ansi[6]

        let entries: [(String, UInt32?)] = [
            ("main_bg", nil),
            ("main_fg", fg),
            ("title", fg),
            ("hi_fg", red),
            ("selected_bg", mix(bg, blue, 0.35)),
            ("selected_fg", fg),
            ("inactive_fg", mix(fg, bg, 0.55)),
            ("graph_text", mix(fg, bg, 0.35)),
            ("meter_bg", mix(fg, bg, 0.8)),
            ("proc_misc", green),
            ("cpu_box", mix(bg, green, 0.65)),
            ("mem_box", mix(bg, yellow, 0.65)),
            ("net_box", mix(bg, magenta, 0.65)),
            ("proc_box", mix(bg, red, 0.65)),
            ("div_line", mix(fg, bg, 0.75)),
            ("temp_start", blue),
            ("temp_mid", magenta),
            ("temp_end", red),
            ("cpu_start", green),
            ("cpu_mid", yellow),
            ("cpu_end", red),
            ("free_start", mix(bg, green, 0.3)),
            ("free_mid", mix(bg, green, 0.7)),
            ("free_end", green),
            ("cached_start", mix(bg, cyan, 0.3)),
            ("cached_mid", mix(bg, cyan, 0.7)),
            ("cached_end", cyan),
            ("available_start", mix(bg, yellow, 0.3)),
            ("available_mid", mix(bg, yellow, 0.7)),
            ("available_end", yellow),
            ("used_start", mix(bg, red, 0.3)),
            ("used_mid", mix(bg, red, 0.7)),
            ("used_end", red),
            ("download_start", mix(bg, blue, 0.3)),
            ("download_mid", mix(bg, blue, 0.7)),
            ("download_end", blue),
            ("upload_start", mix(bg, magenta, 0.3)),
            ("upload_mid", mix(bg, magenta, 0.7)),
            ("upload_end", magenta),
            ("process_start", green),
            ("process_mid", yellow),
            ("process_end", red),
            ("proc_pause_bg", red),
            ("proc_follow_bg", blue),
            ("proc_banner_bg", magenta),
            ("proc_banner_fg", bg),
            ("followed_bg", blue),
            ("followed_fg", bg),
        ]
        var lines = [
            "# Generated by iTERMiNAL from the \(theme.name) terminal theme, and",
            "# rewritten whenever that changes. Edits here do not survive.",
        ]
        for (key, color) in entries {
            lines.append("theme[\(key)]=\"\(color.map { hex($0) } ?? "")\"")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: superfile

    private static func writeSuperfile(_ theme: TerminalTheme) throws {
        try FileManager.default.createDirectory(at: superfileThemeDirectory, withIntermediateDirectories: true)
        try superfileTheme(for: theme).write(
            to: superfileThemeDirectory.appendingPathComponent("\(themeName).toml"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: superfileConfigURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try setConfig(
            [
                ("theme", "\"\(themeName)\""),
                // Leaves the background to the terminal.
                ("transparent_background", "true"),
                // Versions move with scripts/tools.env, not from inside the
                // panel, so superfile has no reason to call GitHub.
                ("auto_check_update", "false"),
                // Everything not set here takes superfile's default; without
                // this it would list those as "missing" before every start.
                ("ignore_missing_fields", "true"),
            ],
            in: superfileConfigURL,
            creatingWith: """
            # superfile configuration for the copy bundled with iTERMiNAL.
            # iTERMiNAL sets the keys below each time it starts superfile; any
            # other setting from https://superfile.dev/configure/superfile-config/
            # added here is kept.

            """
        )
    }

    /// A superfile theme that draws in the terminal's palette.
    ///
    /// Numbers are ANSI palette entries and empty strings are the terminal's
    /// own foreground or background, so this file barely depends on `theme`
    /// at all — which is the point. Three things do: the syntax-highlighting
    /// style, the two progress-bar colours (superfile blends between them, so
    /// they have to be literal), and the colour for borders and dividers.
    /// That is palette 8, "bright black", everywhere it reads as a quiet
    /// grey; Solarized Dark's 8 is its own background colour, so there the
    /// file carries a literal grey rather than borders that vanish.
    static func superfileTheme(for theme: TerminalTheme) -> String {
        let quiet = contrast(theme.ansi[8], theme.background) >= 1.6
            ? "8"
            : hex(mix(theme.foreground, theme.background, 0.55))
        let entries: [(String, String)] = [
            ("file_panel_border", quiet),
            ("sidebar_border", quiet),
            ("footer_border", quiet),
            ("file_panel_border_active", "4"),
            ("sidebar_border_active", "4"),
            ("footer_border_active", "4"),
            ("modal_border_active", "5"),
            ("full_screen_bg", ""),
            ("file_panel_bg", ""),
            ("sidebar_bg", ""),
            ("footer_bg", ""),
            ("modal_bg", ""),
            ("full_screen_fg", ""),
            ("file_panel_fg", ""),
            ("sidebar_fg", ""),
            ("footer_fg", ""),
            ("modal_fg", ""),
            ("cursor", "5"),
            ("correct", "2"),
            ("error", "1"),
            ("hint", "6"),
            ("cancel", "3"),
            ("directory_icon_color", "4"),
            ("file_panel_top_directory_icon", "2"),
            ("file_panel_top_path", "4"),
            ("file_panel_item_selected_fg", "6"),
            ("file_panel_item_selected_bg", ""),
            ("sidebar_title", "6"),
            ("sidebar_item_selected_fg", "6"),
            ("sidebar_item_selected_bg", ""),
            ("sidebar_divider", quiet),
            // Button labels sit on a coloured fill, where palette 0 — the
            // palette's black, or its darkest tone — reads in every theme.
            ("modal_cancel_fg", "0"),
            ("modal_cancel_bg", "9"),
            ("modal_confirm_fg", "0"),
            ("modal_confirm_bg", "12"),
            ("help_menu_hotkey", "6"),
            ("help_menu_title", "5"),
        ]
        var lines = [
            "# Generated by iTERMiNAL from the \(theme.name) terminal theme, and",
            "# rewritten whenever that changes. Edits here do not survive.",
            "#",
            "# Numbers are the terminal's ANSI palette and empty strings its own",
            "# colours, so superfile follows the terminal as it changes.",
            "code_syntax_highlight = \"\(syntaxStyle(for: theme))\"",
            "gradient_color = [\"\(hex(theme.ansi[4]))\", \"\(hex(theme.ansi[5]))\"]",
        ]
        for (key, value) in entries {
            lines.append("\(key) = \"\(value)\"")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The code-preview style closest to the terminal theme, by name where the
    /// highlighter has a match. Preview text is literal colour, not palette,
    /// so it is the one part of superfile a theme change reaches only at its
    /// next start.
    static func syntaxStyle(for theme: TerminalTheme) -> String {
        let styles: [String: String] = [
            "solarized-dark": "solarized-dark",
            "solarized-light": "solarized-light",
            "nord": "nord",
            "dracula": "dracula",
            "catppuccin-mocha": "catppuccin-mocha",
            "catppuccin-macchiato": "catppuccin-macchiato",
            "catppuccin-frappe": "catppuccin-frappe",
            "catppuccin-latte": "catppuccin-latte",
            "gruvbox-dark": "gruvbox",
            "gruvbox-light": "gruvbox-light",
            "tokyo-night": "tokyonight-night",
            "tokyo-night-storm": "tokyonight-storm",
            "one-dark": "onedark",
            "everforest-dark": "evergarden",
            "rose-pine": "rose-pine",
            "kanagawa": "kanagawa-wave",
            "monokai": "monokai",
        ]
        return styles[theme.id] ?? (theme.isDark ? "github-dark" : "github")
    }

    // MARK: Config files

    /// Sets top-level `key = value` lines in `url`, creating it from `header`
    /// if it does not exist, and leaving every other line as it was. Only
    /// written when something actually changed: a running btop owns this
    /// file too, and rewrites it on exit.
    private static func setConfig(_ values: [(String, String)], in url: URL, creatingWith header: String) throws {
        let existing = try? String(contentsOf: url, encoding: .utf8)
        let updated = settingKeys(values, in: existing ?? header)
        if updated != existing {
            try updated.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// `text` with each key's top-level assignment replaced, or added if it
    /// has none. Works for btop.conf and superfile's TOML alike: both are
    /// `key = value` lines, and in TOML anything after the first `[table]`
    /// header belongs to that table, so keys are only matched — and new ones
    /// only inserted — above it.
    static func settingKeys(_ values: [(String, String)], in text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var tableStart = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
        // New keys go after the last non-blank top-level line, not after a
        // trailing newline, so the file does not grow a blank line per key.
        var insertAt = tableStart
        while insertAt > 0, lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            insertAt -= 1
        }
        for (key, value) in values {
            let line = "\(key) = \(value)"
            if let index = lines[..<tableStart].firstIndex(where: { assigns($0, key) }) {
                lines[index] = line
            } else {
                lines.insert(line, at: insertAt)
                insertAt += 1
                tableStart += 1
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Whether `line` assigns `key`: `theme = …` does, `theme_background = …`
    /// and `# theme = …` do not.
    private static func assigns(_ line: String, _ key: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(key) else { return false }
        return trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces).hasPrefix("=")
    }

    // MARK: Colour

    /// `a` moved `amount` of the way to `b`, per channel.
    static func mix(_ a: UInt32, _ b: UInt32, _ amount: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let from = Double((a >> shift) & 0xFF)
            let to = Double((b >> shift) & 0xFF)
            return UInt32((from + (to - from) * amount).rounded()) << shift
        }
        return channel(16) | channel(8) | channel(0)
    }

    static func hex(_ color: UInt32) -> String {
        String(format: "#%06x", color & 0xFFFFFF)
    }

    /// WCAG contrast ratio between two colours, 1 (none) to 21.
    static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func luminance(_ color: UInt32) -> Double {
            func linear(_ shift: UInt32) -> Double {
                let c = Double((color >> shift) & 0xFF) / 255
                return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0)
        }
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}
