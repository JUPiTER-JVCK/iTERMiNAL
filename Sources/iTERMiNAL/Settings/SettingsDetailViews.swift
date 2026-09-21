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
        }
        .formStyle(.grouped)
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
                    Slider(value: $settings.backgroundOpacity, in: 0.5...1.0)
                    Text("\(Int(settings.backgroundOpacity * 100))%")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
                Text("Terminal background opacity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Sidebar") {
                Toggle("Translucent sidebar", isOn: $settings.sidebarTranslucent)
                Text("Off by default, matching the flat sidebar of the app this one is modelled on. On, the sidebar picks up the desktop behind it the way most macOS apps do.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("System monitor", isOn: $settings.showSystemMetrics)
                Text("Live CPU, memory, GPU and network for this Mac, in a strip along the bottom right of the window. Hover the numbers for detail. Off stops the sampling as well as hiding the strip.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
