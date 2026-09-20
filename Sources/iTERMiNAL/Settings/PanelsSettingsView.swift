import SwiftUI
import AppKit

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
