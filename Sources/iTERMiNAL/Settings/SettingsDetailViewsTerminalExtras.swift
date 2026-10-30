import SwiftUI
import AppKit

/// Settings → Terminal → which `TERM` local and remote sessions announce.
struct TerminalTypeSettingsSection: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Section("Terminal type") {
            Picker("Local shells", selection: $settings.localTerminalTypeTag) {
                ForEach(TerminalType.allCases) { type in
                    Text(type.label).tag(type.rawValue)
                }
            }
            if !TerminfoLookup.isInstalledLocally(settings.localTerminalType) {
                Label(
                    "This Mac has no terminfo entry named \(settings.localTerminalType.termValue). Programs here may print “unknown terminal type” until one is installed.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            } else {
                Text(settings.localTerminalType.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("Remote sessions", selection: $settings.remoteTerminalTypeTag) {
                ForEach(TerminalType.allCases) { type in
                    Text(type.label).tag(type.rawValue)
                }
            }
            Text(settings.remoteTerminalType.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let hint = settings.remoteTerminalType.installHint {
                Text("A host that doesn't know this name can be taught it with: \(hint)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text("Sets TERM for new sessions; a host can use its own under Connections. It is what programs are told, not what the terminal can do — naming a type the host has no entry for makes less, vim and tput fall back or complain, and iTERMiNAL can only check this Mac. COLORTERM=truecolor goes along only with types that claim 256 colours or more.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Settings → Terminal → Ghostty themes brought in from files.
struct GhosttyThemeImportSection: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var message: String?

    var body: some View {
        Section("Ghostty themes") {
            Button("Import Theme Files…") { importFiles() }
            ForEach(settings.importedThemes) { theme in
                HStack {
                    Text(theme.name)
                    Spacer()
                    Button("Remove", role: .destructive) { remove(theme) }
                        .buttonStyle(.borderless)
                }
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Reads Ghostty theme files — the ones in Ghostty's themes folder, or any file of palette = N=#rrggbb, background and foreground lines — and adds each to the theme list above. Only the colours are read; nothing else in a file is used.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func importFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose Ghostty theme files"
        guard panel.runModal() == .OK else { return }

        var added = 0
        var problems: [String] = []
        for url in panel.urls {
            let name = String(url.lastPathComponent.prefix(60))
            // One byte more than the limit is enough to know it is too large,
            // and keeps a mistaken pick of a huge file from being read whole.
            guard let handle = try? FileHandle(forReadingFrom: url),
                  let data = try? handle.read(upToCount: GhosttyThemeFile.maxBytes + 1) else {
                problems.append("\(name): couldn't be read.")
                continue
            }
            try? handle.close()
            guard let text = String(data: data, encoding: .utf8) else {
                problems.append("\(name): isn't text.")
                continue
            }
            switch GhosttyThemeFile.parse(text) {
            case .success(let file):
                settings.importedThemes.append(ImportedTerminalTheme(name: name, file: file))
                added += 1
            case .failure(let problem):
                problems.append("\(name): \(problem.message)")
            }
        }
        var lines: [String] = []
        if added > 0 { lines.append("Added \(added) theme\(added == 1 ? "" : "s").") }
        lines.append(contentsOf: problems.prefix(4))
        if problems.count > 4 { lines.append("…and \(problems.count - 4) more that couldn't be used.") }
        message = lines.joined(separator: "\n")
    }

    private func remove(_ theme: ImportedTerminalTheme) {
        // A removed theme that was the chosen one would leave the picker on a
        // name that no longer exists, which resolves to the default anyway;
        // say so in the setting too.
        if settings.terminalThemeID == theme.id { settings.terminalThemeID = "auto" }
        settings.importedThemes.removeAll { $0.id == theme.id }
    }
}

/// Settings → Terminal → space around the text.
struct TerminalPaddingSection: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Section("Window padding") {
            Toggle("Set padding myself", isOn: $settings.customTerminalPadding)
            if settings.customTerminalPadding {
                Stepper(value: $settings.terminalPaddingHorizontal, in: TerminalPadding.range, step: 1) {
                    HStack {
                        Text("Horizontal")
                        Spacer()
                        Text("\(Int(settings.terminalPaddingHorizontal)) pt").foregroundStyle(.secondary)
                    }
                }
                Stepper(value: $settings.terminalPaddingVertical, in: TerminalPadding.range, step: 1) {
                    HStack {
                        Text("Vertical")
                        Spacer()
                        Text("\(Int(settings.terminalPaddingVertical)) pt").foregroundStyle(.secondary)
                    }
                }
                Button("Reset to Defaults (\(Int(TerminalPadding.defaultHorizontal)) pt / \(Int(TerminalPadding.defaultVertical)) pt)") {
                    settings.terminalPaddingHorizontal = TerminalPadding.defaultHorizontal
                    settings.terminalPaddingVertical = TerminalPadding.defaultVertical
                }
                Text("Custom padding active. Turn it off to return to the built-in padding, which is a little wider on the left.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Space between a terminal's edge and its text. The built-in padding is used until you set your own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Settings → Terminal → how the focused pane is marked in a split.
struct SplitFocusSettingsSection: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Section("Split panes") {
            Picker("Split focus border", selection: $settings.splitFocusStyleTag) {
                ForEach(SplitFocusStyle.allCases) { style in
                    Text(style.label).tag(style.rawValue)
                }
            }
            Picker("Border color", selection: $settings.splitFocusColorTag) {
                ForEach(SplitFocusColor.allCases) { color in
                    Text(color.label).tag(color.rawValue)
                }
            }
            .disabled(settings.splitFocusStyle == .none || settings.splitFocusStyle == .dimOthers)
            Text("How the pane you are typing in stands out once a tab is split. A single pane is never marked.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Colours

/// A colour as it is stored — "#RRGGBB" text or a 0xRRGGBB number — and as a
/// picker holds it.
enum ColorHex {
    static func value(of color: Color) -> UInt32? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        func byte(_ component: CGFloat) -> UInt32 {
            UInt32((min(max(component, 0), 1) * 255).rounded())
        }
        return (byte(rgb.redComponent) << 16) | (byte(rgb.greenComponent) << 8) | byte(rgb.blueComponent)
    }

    static func binding(_ number: Binding<UInt32>) -> Binding<Color> {
        Binding(
            get: { Color(hex: number.wrappedValue) },
            set: { color in
                if let value = value(of: color) { number.wrappedValue = value }
            }
        )
    }

    static func binding(_ text: Binding<String>, default fallback: UInt32) -> Binding<Color> {
        Binding(
            get: { Color(hex: FrameStyle.parseHex(text.wrappedValue) ?? fallback) },
            set: { color in
                if let value = value(of: color) { text.wrappedValue = FrameStyle.hexString(value) }
            }
        )
    }
}

/// A switch for "use my own colour", and, when it is on, the picker.
private struct OverrideColorRow: View {
    let title: String
    @Binding var hex: String
    let defaultHex: UInt32

    var body: some View {
        Toggle(title, isOn: Binding(
            get: { !hex.isEmpty },
            set: { hex = $0 ? FrameStyle.hexString(defaultHex) : "" }
        ))
        if !hex.isEmpty {
            ColorPicker("Color", selection: ColorHex.binding($hex, default: defaultHex), supportsOpacity: false)
        }
    }
}

/// Settings → Terminal → cursor, selection and bold colours.
struct TerminalColorOverridesSection: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = settings.resolvedTerminalTheme(darkMode: colorScheme == .dark)
        Section("Cursor and selection colors") {
            OverrideColorRow(title: "Custom cursor color", hex: $settings.cursorColorHex, defaultHex: theme.foreground)
            OverrideColorRow(title: "Custom text color under the cursor", hex: $settings.cursorTextColorHex, defaultHex: theme.background)
            OverrideColorRow(title: "Custom selection color", hex: $settings.selectionColorHex, defaultHex: 0x3B82F6)
            Toggle("Draw bold text in bright colors", isOn: $settings.boldAsBright)
            Text("Off, the theme's cursor and selection colors are used. Bold in bright colors is how most terminals draw bold in the eight dark ANSI colors; turn it off for a font whose bold weight is enough on its own. Open terminals pick the change up as they come into view. Bundled tools such as btop keep their own cursor.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Settings → Terminal → line height.
struct TerminalLineSpacingSection: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Section("Line height") {
            HStack {
                Text("Spacing")
                Slider(value: $settings.terminalLineSpacing, in: VisualRange.lineSpacing, step: 0.05)
                Text(String(format: "%.2f×", settings.terminalLineSpacing))
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
            Button("Reset") { settings.terminalLineSpacing = 1 }
                .disabled(settings.terminalLineSpacing == 1)
            Text("Multiplies the height of each row of text; 1.00× is the font's own. Rows get taller or shorter, the letters do not change. Character width is fixed by the font and has no setting here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Settings → Terminal → edit a copy of a theme's colors.
struct ThemeEditorSection: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    private static let colorNames = [
        "Black", "Red", "Green", "Yellow", "Blue", "Magenta", "Cyan", "White",
        "Bright black", "Bright red", "Bright green", "Bright yellow",
        "Bright blue", "Bright magenta", "Bright cyan", "Bright white",
    ]

    private var editedID: String? {
        settings.importedThemes.contains { $0.id == settings.terminalThemeID } ? settings.terminalThemeID : nil
    }

    var body: some View {
        Section("Edit a theme") {
            Button("Duplicate the Current Theme to Edit") { duplicate() }
            if let id = editedID {
                TextField("Name", text: field(id, \.name, fallback: ""))
                Toggle("Dark theme", isOn: field(id, \.isDark, fallback: true))
                ColorPicker("Background", selection: ColorHex.binding(field(id, \.background, fallback: 0)), supportsOpacity: false)
                ColorPicker("Text", selection: ColorHex.binding(field(id, \.foreground, fallback: 0xFFFFFF)), supportsOpacity: false)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 8), alignment: .leading, spacing: 6) {
                    ForEach(0..<16, id: \.self) { index in
                        ColorPicker("", selection: ColorHex.binding(ansi(id, index)), supportsOpacity: false)
                            .labelsHidden()
                            .help(Self.colorNames[index])
                    }
                }
                Text("The sixteen colors programs draw with, dark above, bright below. Changes apply as you make them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("The built-in themes can't be changed. Duplicate one to get a copy you can: it is added to the theme list and chosen, and imported Ghostty themes can be edited the same way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func duplicate() {
        let base = settings.resolvedTerminalTheme(darkMode: colorScheme == .dark)
        let copy = ImportedTerminalTheme(copying: base, name: "\(base.name) copy")
        settings.importedThemes.append(copy)
        settings.terminalThemeID = copy.id
    }

    /// A binding to one field of the theme with this id, looked up on every
    /// access so it stays right if the list changes underneath it.
    private func field<Value>(_ id: String, _ keyPath: WritableKeyPath<ImportedTerminalTheme, Value>, fallback: Value) -> Binding<Value> {
        Binding(
            get: { settings.importedThemes.first { $0.id == id }?[keyPath: keyPath] ?? fallback },
            set: { value in
                guard let index = settings.importedThemes.firstIndex(where: { $0.id == id }) else { return }
                settings.importedThemes[index][keyPath: keyPath] = value
            }
        )
    }

    private func ansi(_ id: String, _ position: Int) -> Binding<UInt32> {
        Binding(
            get: {
                guard let theme = settings.importedThemes.first(where: { $0.id == id }), theme.ansi.count == 16 else { return 0 }
                return theme.ansi[position]
            },
            set: { value in
                guard let index = settings.importedThemes.firstIndex(where: { $0.id == id }),
                      settings.importedThemes[index].ansi.count == 16 else { return }
                settings.importedThemes[index].ansi[position] = value
            }
        )
    }
}

// MARK: - Appearance

/// Settings → Appearance → Accent: a colour of your own beside the six.
struct CustomAccentRow: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack {
            ColorPicker("Custom accent", selection: Binding(
                get: { Color(hex: FrameStyle.parseHex(settings.customAccentHex) ?? 0x10A37F) },
                set: { color in
                    guard let value = ColorHex.value(of: color) else { return }
                    settings.customAccentHex = FrameStyle.hexString(value)
                    settings.accentID = "custom"
                }
            ), supportsOpacity: false)
            if settings.accentID == "custom" {
                Image(systemName: "checkmark")
                    .foregroundStyle(settings.accentColor)
            }
        }
    }
}

/// Settings → Appearance → Effects.
struct EffectsSection: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Section("Effects") {
            HStack {
                Text("Animation speed")
                Slider(value: $settings.animationSpeed, in: VisualRange.animationSpeed, step: 0.1)
                Text(String(format: "%.1f×", settings.animationSpeed))
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
            Button("Reset") { settings.animationSpeed = 1 }
                .disabled(settings.animationSpeed == 1)
            Text("How fast panels, banners and highlights move: 2× is twice as quick, 0.5× half as quick. It does not replace Reduce Motion, which still removes the sliding.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
