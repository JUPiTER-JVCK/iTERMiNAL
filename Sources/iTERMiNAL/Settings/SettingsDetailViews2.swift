import SwiftUI
import AppKit

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
                    AttentionSettings.shared.resetToInApp()
                }
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
            }
            // MIT and Apache-2.0 both require the notice to travel with the
            // binary. It does — in the bundle — and this is where a user can
            // actually find it.
            Section("Bundled tools") {
                ForEach(TerminalTool.allCases) { tool in
                    BundledToolRow(tool: tool)
                }
                Text("Shipped inside the app at the versions pinned in scripts/tools.env. superfile is upstream's release binary, checked against its published hash; btop publishes no macOS build, so it is compiled from pinned source. Neither runs with elevated privileges.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// One bundled tool: what it is, the version that shipped, and its licence.
private struct BundledToolRow: View {
    let tool: TerminalTool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: tool.icon)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let licenseURL = tool.licenseURL {
                Button("Licence") {
                    NSWorkspace.shared.open(licenseURL)
                }
            }
            Button("Project") {
                NSWorkspace.shared.open(tool.homepage)
            }
        }
    }

    /// Says plainly when a build has no copy — a local build made without
    /// fetching the tools — rather than printing a version that isn't there.
    private var detail: String {
        guard tool.isBundled else {
            return "\(tool.summary) · not included in this build"
        }
        let version = tool.bundledVersion.map { "v\($0)" } ?? "version unknown"
        return "\(tool.summary) · \(version) · \(tool.licenseName)"
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

            Section("Where commands run") {
                Picker("Run commands in", selection: $settings.composerTarget) {
                    ForEach(ComposerTarget.allCases) { target in
                        Text(target.label).tag(target)
                    }
                }
                Text(settings.composerTarget.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("The chip above the composer's input always names the destination, and doubles as a menu for changing it.")
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
                if settings.composerTarget != .ownShell {
                    Text("Only used while \"Run commands in\" is set to the composer's own shell.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
