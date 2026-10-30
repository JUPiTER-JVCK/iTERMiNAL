import SwiftUI
import AppKit
import CoreText
import UniformTypeIdentifiers

struct TerminalSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var attention = AttentionSettings.shared
    @ObservedObject private var imported = ImportedFonts.shared
    /// What the last import did, in a sentence.
    @State private var importMessage: String?

    private static let monospacedFamilies: [String] = {
        NSFontManager.shared.availableFontFamilies.filter { family in
            // The bundled symbols face is fixed-pitch too, but it has no
            // letters: picked as the terminal font, every line would draw as
            // boxes. It is the fallback behind the chosen font, not a choice.
            family != SymbolsFont.familyName
                && NSFont(name: family, size: 12)?.isFixedPitch == true
        }
        .sorted()
    }()

    /// Twenty coding fonts worth knowing about, all free.
    ///
    /// A recommendation list, not a second source of fonts: the app does not
    /// download any. Ones this Mac has — installed, or imported with Import
    /// Font… below — are selectable; ones it doesn't are listed with somewhere
    /// to get them, which is more useful than hiding them and leaving you to
    /// wonder what to install.
    static let recommendedFonts: [(family: String, source: String)] = [
        ("JetBrains Mono", "https://www.jetbrains.com/lp/mono/"),
        ("Fira Code", "https://github.com/tonsky/FiraCode"),
        ("Fira Mono", "https://github.com/mozilla/Fira"),
        ("MesloLGS NF", "https://github.com/romkatv/powerlevel10k#manual-font-installation"),
        ("Meslo LG S", "https://github.com/andreberg/Meslo-Font"),
        ("Cascadia Code", "https://github.com/microsoft/cascadia-code"),
        ("Hack", "https://sourcefoundry.org/hack/"),
        ("Iosevka", "https://typeof.net/Iosevka/"),
        ("IBM Plex Mono", "https://github.com/IBM/plex"),
        ("Source Code Pro", "https://github.com/adobe-fonts/source-code-pro"),
        ("Victor Mono", "https://rubjo.github.io/victor-mono/"),
        ("Inconsolata", "https://github.com/googlefonts/Inconsolata"),
        ("Roboto Mono", "https://fonts.google.com/specimen/Roboto+Mono"),
        ("Ubuntu Mono", "https://fonts.google.com/specimen/Ubuntu+Mono"),
        ("Space Mono", "https://fonts.google.com/specimen/Space+Mono"),
        ("Anonymous Pro", "https://www.marksimonson.com/fonts/view/anonymous-pro"),
        ("DejaVu Sans Mono", "https://dejavu-fonts.github.io"),
        ("Monaspace Neon", "https://monaspace.githubnext.com"),
        ("Geist Mono", "https://vercel.com/font"),
        ("CommitMono", "https://commitmono.com"),
    ]

    /// Every family this Mac can use for the terminal: installed fixed-pitch
    /// ones, and the ones imported here (a font can be fixed-pitch without
    /// saying so, which is why imported ones are not filtered).
    private var knownFamilies: Set<String> {
        Set(Self.monospacedFamilies).union(imported.families.map(\.name))
    }

    private var installedRecommended: [String] {
        let known = knownFamilies
        return Self.recommendedFonts.map(\.family).filter { known.contains($0) }
    }

    private var missingRecommended: [(family: String, source: String)] {
        let known = knownFamilies
        return Self.recommendedFonts.filter { !known.contains($0.family) }
    }

    private let cursorStyles: [(tag: String, label: String)] = [
        ("steadyBlock", "Block"),
        ("blinkBlock", "Blinking Block"),
        ("steadyBar", "Bar"),
        ("blinkBar", "Blinking Bar"),
        ("steadyUnderline", "Underline"),
        ("blinkUnderline", "Blinking Underline"),
    ]

    var body: some View {
        Form {
            Section("Colors") {
                Picker("Terminal theme", selection: $settings.terminalThemeID) {
                    Text("Match system appearance").tag("auto")
                    Divider()
                    ForEach(TerminalTheme.available) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
            }
            OutputColorsSettingsSection()
            Section("Font") {
                Picker("Font", selection: $settings.terminalFontName) {
                    Text("System monospace (SF Mono)").tag("")
                    if !imported.families.isEmpty {
                        Section("Imported") {
                            ForEach(imported.families) { family in
                                Text(family.name).tag(family.name)
                            }
                        }
                    }
                    if !installedRecommended.isEmpty {
                        Section("Recommended") {
                            ForEach(installedRecommended, id: \.self) { family in
                                Text(family).tag(family)
                            }
                        }
                    }
                    Section("All monospaced fonts") {
                        ForEach(Self.monospacedFamilies.filter { name in
                            !imported.families.contains { $0.name == name }
                        }, id: \.self) { family in
                            Text(family).tag(family)
                        }
                    }
                }
                if !missingRecommended.isEmpty {
                    RecommendedFontsNotice(missing: missingRecommended)
                }
                HStack {
                    Slider(value: $settings.terminalFontSize, in: 9...24, step: 1)
                    Text("\(Int(settings.terminalFontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
                FontPreview()
                HStack {
                    Button("Import Font…") { importFonts() }
                    Spacer()
                }
                if let importMessage {
                    Text(importMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                ImportedFontsList(onRemoved: { entry in
                    // The font that was picked is gone: back to the default
                    // rather than a name nothing answers to.
                    if entry.faces.contains(where: { $0.family == settings.terminalFontName }) {
                        settings.terminalFontName = ""
                    }
                })
                Text("Import copies a .ttf, .otf, .ttc or .otc file into this app's own folder and uses it here only — nothing is installed on the Mac. macOS reads the file, so import fonts you trust.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Cursor") {
                Picker("Cursor style", selection: $settings.cursorStyleTag) {
                    ForEach(cursorStyles, id: \.tag) { style in
                        Text(style.label).tag(style.tag)
                    }
                }
                Picker("Animation", selection: $settings.cursorAnimationTag) {
                    ForEach(CursorAnimation.allCases) { animation in
                        Text(animation.label).tag(animation.rawValue)
                    }
                }
                Text("An animation takes the place of the blink, while the terminal is the one you are typing in. It is drawn by the default renderer, so it does nothing with GPU rendering on, and it is off while Reduce Motion is. Applies to open terminals as they come into view.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TerminalPaddingSection()
            SplitFocusSettingsSection()
            TerminalTypeSettingsSection()
            GhosttyThemeImportSection()
            Section("Scrollback") {
                Stepper(value: $settings.scrollbackLines, in: 500...200_000, step: 500) {
                    Text("\(settings.scrollbackLines) lines")
                        .monospacedDigit()
                }
                Text("Applies to new terminals.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Notifications") {
                Picker("Pane attention", selection: $attention.mode) {
                    ForEach(AttentionSettings.Mode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Text("Bell and OSC 9/777 from background panes show an in-app mark. System banners are optional and only fire when the app is inactive or the pane is unfocused.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Performance") {
                Toggle("GPU rendering (experimental)", isOn: $settings.useGPURendering)
                Text("Draws the terminal with Metal for smoother scrolling. The renderer is still experimental upstream; if it can't start, terminals silently keep using the CPU renderer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct PanelsSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Composer") {
                Toggle("Show composer bar", isOn: $settings.composerEnabled)
            }
            Section("Browser") {
                TextField("Homepage", text: $settings.browserHomepage)
            }
            Section("Files") {
                Toggle("Show hidden files", isOn: $settings.showHiddenFiles)
                Toggle("Follow the focused terminal's directory", isOn: $settings.followTerminalDirectory)
            }
        }
        .formStyle(.grouped)
    }
}

/// Lists the recommended fonts this Mac doesn't have, with somewhere to get
/// them. Collapsed by default — it is a suggestion, not a task.
extension TerminalSettingsView {
    fileprivate func importFonts() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.font]
        panel.message = "Choose font files: .ttf, .otf, .ttc or .otc."
        guard panel.runModal() == .OK else { return }

        var added: [String] = []
        var problems: [String] = []
        for url in panel.urls {
            switch imported.importFont(from: url) {
            case .success(let families): added += families
            case .failure(let failure): problems.append(failure.message)
            }
        }
        // The first font brought in is the one picked, so the preview shows it.
        if let first = added.first { settings.terminalFontName = first }
        var parts: [String] = []
        if !added.isEmpty {
            let names = Array(Set(added)).sorted().joined(separator: ", ")
            parts.append("Imported \(names).")
        }
        parts.append(contentsOf: problems)
        importMessage = parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// The terminal's font as it will draw — the one the terminal gets, with the
/// symbols fallback behind it — over a few lines that tell fonts apart, so a
/// font that is wrong for a terminal shows here first.
private struct FontPreview: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Text(FontImport.sampleText)
            .font(Font(settings.resolvedTerminalFont() as CTFont))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: settings.resolvedTerminalTheme(darkMode: settings.isDarkAppearance).backgroundColor))
            )
            .foregroundStyle(Color(nsColor: settings.resolvedTerminalTheme(darkMode: settings.isDarkAppearance).foregroundColor))
            .accessibilityLabel("Font preview")
    }
}

/// The fonts that have been imported, one row per file with what it holds,
/// each with a way to take it out again.
private struct ImportedFontsList: View {
    @ObservedObject private var imported = ImportedFonts.shared
    let onRemoved: (ImportedFonts.Entry) -> Void

    var body: some View {
        ForEach(imported.entries) { entry in
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    let families = Array(Set(entry.faces.map(\.family))).sorted()
                    Text(families.joined(separator: ", "))
                    Text("\(entry.fileName) · \(entry.faces.count) style\(entry.faces.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Remove", role: .destructive) {
                    imported.remove(entry)
                    onRemoved(entry)
                }
            }
        }
    }
}

struct RecommendedFontsNotice: View {
    let missing: [(family: String, source: String)]

    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(missing, id: \.family) { font in
                    if let url = URL(string: font.source) {
                        Link(font.family, destination: url)
                            .font(.caption)
                    } else {
                        Text(font.family).font(.caption)
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            Text("\(missing.count) recommended fonts aren't installed")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
