import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SyncSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Mode", value: LocalOnlySyncEngine.shared.displayName)
                Text(LocalOnlySyncEngine.shared.statusDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("State file") {
                    Text(store.stateFileURL.path)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.stateFileURL])
                }
            }

            Section("Snapshots") {
                HStack {
                    Button("Export Workspaces…") {
                        WorkspaceArchiveIO.promptExport(store: store, settings: settings)
                    }
                    Button("Import Workspaces…") {
                        WorkspaceArchiveIO.promptImport(store: store, settings: settings)
                    }
                }
                Text("A snapshot carries your workspaces, tabs, split layout, and preferences — but no secrets. Importing replaces the current layout.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("iCloud") {
                Text("Cross-device sync over iCloud isn't wired up yet: it needs a paid Apple Developer account, the iCloud entitlement, and a signed build, which a source build doesn't have. The sync layer is written as a seam so it can be added without changing the rest of the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ShortcutsSettingsView: View {
    private let shortcuts: [(action: String, keys: String)] = [
        ("Command palette", "⌘K"),
        ("New terminal tab", "⌘T"),
        ("New workspace", "⇧⌘N"),
        ("Split right", "⌘D"),
        ("Split down", "⇧⌘D"),
        ("Split with browser", "⇧⌘B"),
        ("Close pane", "⇧⌘W"),
        ("Close tab", "⌥⌘W"),
        ("Toggle browser panel", "⌥⌘B"),
        ("Toggle files panel", "⌥⌘F"),
        ("Settings", "⌘,"),
    ]

    var body: some View {
        Form {
            Section("Keyboard shortcuts") {
                ForEach(shortcuts, id: \.action) { shortcut in
                    HStack {
                        Text(shortcut.action)
                        Spacer()
                        Text(shortcut.keys)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Custom key bindings are on the roadmap.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
