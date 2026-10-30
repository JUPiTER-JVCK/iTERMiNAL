import SwiftUI
import AppKit

struct GeneralSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                Toggle("Restore workspaces on launch", isOn: $settings.restoreSession)
            }
            Section("Shell") {
                Picker("Shell", selection: $settings.shellPath) {
                    Text("Automatic (login shell)").tag("")
                    Text("zsh").tag("/bin/zsh")
                    Text("bash").tag("/bin/bash")
                    Text("fish (Homebrew)").tag("/opt/homebrew/bin/fish")
                }
                Toggle("Run as login shell", isOn: $settings.loginShell)
                HStack {
                    TextField("Default directory", text: $settings.defaultDirectory, prompt: Text("~"))
                    Button("Choose…") { chooseDirectory() }
                }
                Text("Shell changes apply to new terminals.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Editor") {
                Picker("Editor", selection: $settings.editorChoiceTag) {
                    ForEach(EditorChoice.allCases) { choice in
                        Text(choice.label).tag(choice.rawValue)
                    }
                }
                if settings.editorChoice == .custom {
                    TextField("Command", text: $settings.editorCustomCommand, prompt: Text("code -w"))
                }
                Text(editorNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// What "Edit in Terminal" in the file browser will run, found the way it
    /// will be found: so a missing editor is known here, not on the first try.
    private var editorNote: String {
        let choice = settings.editorChoice
        if choice == .custom {
            return "Runs in a new terminal tab beside the file, with the file's path added at the end of the command."
        }
        for name in choice.candidates {
            if let path = SessionLaunch.resolveExecutable(name) {
                return "Edit in Terminal (right-click a file in the file browser) opens it with \(path), in a new terminal tab."
            }
        }
        let how = choice.installHint.map { " Install it with \($0)." } ?? ""
        return "\(choice.label) isn't installed on this Mac.\(how)"
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            settings.defaultDirectory = url.path
        }
    }
}

struct AppearanceSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    /// The Custom tint as a `Color` for the picker, stored as "#RRGGBB".
    private var customTint: Binding<Color> {
        Binding(
            get: { Color(hex: settings.frameCustomValue) },
            set: { color in
                guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                func byte(_ component: CGFloat) -> UInt32 {
                    UInt32((min(max(component, 0), 1) * 255).rounded())
                }
                let hex = (byte(rgb.redComponent) << 16)
                    | (byte(rgb.greenComponent) << 8)
                    | byte(rgb.blueComponent)
                settings.frameCustomHex = FrameStyle.hexString(hex)
            }
        )
    }

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $settings.theme) {
                    ForEach(AppSettings.ThemeChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section("Accent") {
                HStack(spacing: 12) {
                    ForEach(Accents.all) { option in
                        Button {
                            settings.accentID = option.id
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 22, height: 22)
                                if settings.accentID == option.id {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .help(option.name)
                    }
                }
                .padding(.vertical, 2)
            }
            Section("Window") {
                HStack {
                    Text("Terminal opacity")
                    Slider(value: $settings.backgroundOpacity, in: BackgroundOpacity.range)
                    Text(BackgroundOpacity.percentText(settings.backgroundOpacity))
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
                Text("Lets the desktop show through a terminal's background, softly blurred. Text and the cursor stay solid. btop and superfile keep a solid background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Workspace frame") {
                FramePreview()

                Toggle("Translucent frame", isOn: $settings.sidebarTranslucent)
                Text("Off by default, matching the flat chrome of the app this one is modelled on. On, the top bar, the icon rail and the workspaces panel pick up the desktop behind them the way most macOS apps do.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Tint", selection: $settings.frameTintSource) {
                    ForEach(FrameTintSource.allCases) { source in
                        Text(source.label).tag(source)
                    }
                }
                if settings.frameTintSource == .custom {
                    ColorPicker("Color", selection: customTint, supportsOpacity: false)
                }
                if settings.frameTintSource != .none {
                    HStack {
                        Text("Strength")
                        Slider(value: $settings.frameTintStrength, in: FrameStyle.strengthRange)
                        Text("\(Int((settings.frameTintStrength * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                Text("Mixes the color into the theme's own, rather than replacing it, so the icons and text on the bars stay readable in light and dark.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Corner radius")
                    Slider(value: $settings.frameCornerRadius, in: FrameStyle.radiusRange, step: 1)
                    Text("\(Int(settings.frameCornerRadius)) pt")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
                HStack {
                    Text("Edge thickness")
                    Slider(value: $settings.frameGap, in: FrameStyle.gapRange, step: 1)
                    Text("\(Int(settings.frameGap)) pt")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
                Toggle("Outline around the content", isOn: $settings.frameShowsBorder)

                Button("Reset Frame") { settings.resetFrame() }
            }

            Section("Interface font") {
                Picker("Typeface", selection: $settings.uiFontDesign) {
                    ForEach(FrameFontDesign.allCases) { design in
                        Text(design.label).tag(design)
                    }
                }
                .pickerStyle(.segmented)
                Text("The bars, panels, menus and settings. The terminal has its own font under Terminal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Status") {
                Toggle("System monitor", isOn: $settings.showSystemMetrics)
                Text("Live CPU, memory, GPU and network for this Mac, in a strip along the bottom right of the window. Hover the numbers for detail. Off stops the sampling as well as hiding the strip.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Show remote ports", isOn: $settings.showRemotePorts)
                Text("Shows a globe at the bottom left of the window. It lists the TCP ports the focused terminal's machine is listening on — this Mac, or a saved host — and choosing one forwards it to this Mac and opens it in the browser panel. Off by default: nothing is scanned until you open the list, and it rescans every few seconds only while it stays open. Turning it on also lets a new ssh tab share its sign-in with the scan and the forwards, so a host that wants a password works once you have signed in to it in a tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// A miniature of the window's frame — the bar, the rail, the content card —
/// drawn from the same settings the real one is, so a change shows here as it
/// is made. At actual size rather than scaled down, so what the radius and
/// thickness sliders say is what they do.
private struct FramePreview: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        let card = RoundedRectangle(cornerRadius: settings.frameCornerRadius, style: .continuous)
        ZStack(alignment: .topLeading) {
            settings.frameColor(for: colorScheme)

            VStack(spacing: 0) {
                // The top bar: a button, a title.
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(theme.textSecondary.opacity(0.5))
                        .frame(width: 12, height: 12)
                    Capsule()
                        .fill(theme.textSecondary.opacity(0.35))
                        .frame(width: 56, height: 6)
                    Spacer()
                }
                .padding(.leading, 12)
                .frame(height: 26)

                HStack(spacing: 0) {
                    // The rail: a few icons.
                    VStack(spacing: 6) {
                        ForEach(0..<3, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(theme.textSecondary.opacity(0.45))
                                .frame(width: 14, height: 14)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 2)
                    .frame(width: 34)

                    card
                        .fill(theme.background)
                        .overlay {
                            if settings.frameShowsBorder {
                                card.strokeBorder(theme.surfaceBorder)
                            }
                        }
                        .padding(.trailing, settings.frameGap)
                        .padding(.bottom, settings.frameGap)
                }
            }
        }
        .frame(height: 112)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.surfaceBorder))
        .accessibilityHidden(true)
    }
}
