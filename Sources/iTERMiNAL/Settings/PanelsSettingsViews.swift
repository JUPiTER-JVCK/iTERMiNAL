import SwiftUI

// The Panels group of the settings rail: a page for each panel that has
// settings of its own. The HTTP client's page is HTTPClientSettingsView.swift.

/// Settings → Browser.
struct BrowserSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Homepage") {
                TextField("Homepage", text: $settings.browserHomepage)
                Text("Where the Home button goes, and the page a new browser split opens on. A new tab in the Browser panel starts empty instead.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings → Files.
struct FilesSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Listing") {
                Toggle("Show hidden files", isOn: $settings.showHiddenFiles)
            }
            Section("Folder") {
                Toggle("Open on the focused terminal's folder", isOn: $settings.followTerminalDirectory)
                // `WorkspaceStore.openPanel` is the one place this is read: on
                // opening, not as the terminal moves.
                Text("Opening the Files panel takes it to the folder the focused terminal is in. It stays where it is after that, and while it is browsing a saved host.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Section("Elsewhere") {
                Text("Edit in Terminal, on a file's right-click menu, opens it in the editor chosen under General. The hosts the file browser can open over SFTP, and whether it shares a terminal tab's sign-in, are under Connections.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
