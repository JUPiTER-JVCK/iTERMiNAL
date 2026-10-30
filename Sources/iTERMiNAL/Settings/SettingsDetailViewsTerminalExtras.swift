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
