import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AdvancedSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        Form {
            Section("Session state") {
                Button("Save Session Now") { store.saveNow() }
                Button("Reveal State File in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.stateFileURL])
                }
            }
            Section("Reset") {
                Button("Reset All Settings", role: .destructive) {
                    settings.resetToDefaults()
                }
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings for the floating command box: how big it is, how solid it looks,
/// and which shell it runs.
struct ComposerSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        Form {
            Section("Visibility") {
                Toggle("Show composer", isOn: $settings.composerEnabled)
            }

            Section("Size") {
                HStack {
                    Text("Width")
                    Slider(value: $settings.composerWidth, in: 420...1200, step: 10)
                    Text("\(Int(settings.composerWidth)) pt")
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
                HStack {
                    Text("Transcript height")
                    Slider(value: $settings.composerTranscriptHeight, in: 100...560, step: 10)
                    Text("\(Int(settings.composerTranscriptHeight)) pt")
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
                Text("The transcript is the composer's own shell, shown once it has run something. Both can also be dragged directly on the card. A tall transcript is capped to whatever the window can fit, so the input stays reachable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Reset position") {
                    settings.composerOffsetX = 0
                    settings.composerOffsetY = 0
                }
                .help("Return the card to the bottom centre")
            }

            Section("Fill") {
                HStack {
                    Text("Opacity")
                    Slider(value: $settings.composerOpacity, in: 0.5...1.0)
                    Text("\(Int(settings.composerOpacity * 100))%")
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
                Toggle("Background vibrancy", isOn: $settings.composerVibrancy)
                Text("Vibrancy lets the terminal underneath show through the card — not the desktop, since the composer floats over the app's own content. Off by default, because the card is meant to read as sitting above the terminal rather than as a window onto it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Shell") {
                Picker("Shell", selection: shellBinding) {
                    Text("Same as new terminals").tag("")
                    ForEach(ComposerShells.available, id: \.path) { shell in
                        Text(shell.name).tag(shell.path)
                    }
                }
                Text("Applies only to the composer's own session, so trying something in another shell doesn't change what new tabs open as. Changing it restarts that session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var shellBinding: Binding<String> {
        Binding(
            get: { settings.composerShell },
            set: { newValue in
                guard newValue != settings.composerShell else { return }
                settings.composerShell = newValue
                store.resetComposerSession()
            }
        )
    }
}
