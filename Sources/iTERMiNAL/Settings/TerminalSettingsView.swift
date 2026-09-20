import SwiftUI
import AppKit

struct TerminalSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    private static let monospacedFamilies: [String] = {
        NSFontManager.shared.availableFontFamilies.filter { family in
            NSFont(name: family, size: 12)?.isFixedPitch == true
        }
        .sorted()
    }()

    /// Twenty coding fonts worth knowing about, all free.
    ///
    /// The app can only use what is installed on this Mac — there is no way to
    /// load a font it doesn't have — so this is a recommendation list, not a
    /// second source of fonts. Ones you have are selectable; ones you don't are
    /// shown greyed with somewhere to get them, which is more useful than
    /// hiding them and leaving you to wonder what to install.
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

    /// Split once: which recommendations this Mac actually has.
    private static var installedRecommended: [String] {
        let installed = Set(monospacedFamilies)
        return recommendedFonts.map(\.family).filter { installed.contains($0) }
    }

    private static var missingRecommended: [(family: String, source: String)] {
        let installed = Set(monospacedFamilies)
        return recommendedFonts.filter { !installed.contains($0.family) }
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
                    ForEach(TerminalTheme.all) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
            }
            Section("Font") {
                Picker("Font", selection: $settings.terminalFontName) {
                    Text("System monospace (SF Mono)").tag("")
                    if !Self.installedRecommended.isEmpty {
                        Section("Recommended") {
                            ForEach(Self.installedRecommended, id: \.self) { family in
                                Text(family).tag(family)
                            }
                        }
                    }
                    Section("All monospaced fonts") {
                        ForEach(Self.monospacedFamilies, id: \.self) { family in
                            Text(family).tag(family)
                        }
                    }
                }
                if !Self.missingRecommended.isEmpty {
                    RecommendedFontsNotice(missing: Self.missingRecommended)
                }
                HStack {
                    Slider(value: $settings.terminalFontSize, in: 9...24, step: 1)
                    Text("\(Int(settings.terminalFontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
            }
            Section("Cursor") {
                Picker("Cursor style", selection: $settings.cursorStyleTag) {
                    ForEach(cursorStyles, id: \.tag) { style in
                        Text(style.label).tag(style.tag)
                    }
                }
                Text("Applies to new terminals.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Scrollback") {
                Stepper(value: $settings.scrollbackLines, in: 500...200_000, step: 500) {
                    Text("\(settings.scrollbackLines) lines")
                        .monospacedDigit()
                }
                Text("Applies to new terminals.")
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
