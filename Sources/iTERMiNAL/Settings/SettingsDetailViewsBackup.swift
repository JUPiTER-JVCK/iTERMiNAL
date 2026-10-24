import SwiftUI
import AppKit

/// Settings → Backup: where state lives on this Mac, and snapshot export /
/// import for moving it to another one.
///
/// This page used to offer an iCloud mode alongside the local one. CloudKit
/// needs an Apple Developer iCloud container, which an unsigned or self-built
/// copy does not have — so the mode was visible to everyone and usable by
/// almost nobody, and the status text existed mostly to explain why it was
/// switched off. Snapshots do the same job without an account.
struct BackupSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: WorkspaceStore
    @State private var savedMessage: String?

    var body: some View {
        Form {
            Section("Where your setup lives") {
                LabeledContent("Stored on", value: LocalStateStore.displayName)
                Text(LocalStateStore.statusDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("State file") {
                    Text(store.stateFileURL.path)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                HStack {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.stateFileURL])
                    }
                    // Layout saves are debounced, so the file on disk can lag
                    // the window by a second. Anyone copying it by hand wants
                    // the current one.
                    Button("Save Now") {
                        LocalStateStore.flush()
                        savedMessage = "Saved to disk."
                    }
                }
                if let savedMessage {
                    Text(savedMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                Text("A snapshot carries your workspaces, tabs, split layout, and preferences — but no secrets. Importing replaces the current layout and closes the shells running under it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("What a snapshot leaves out") {
                Text("""
                Secrets never travel: the API token stays in the keychain, SSH has no passwords to carry, and machine-local paths such as the composer shell are left out so importing on another Mac cannot point the app at a shell that isn't there.

                Terminal scrollback is excluded too. Transcripts stay in their own files on this Mac at 0600, and a snapshot you hand to someone else should not contain what your shells printed.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Everything the keyboard does, from the same catalog as the Keyboard
/// Shortcuts window (Help menu, ⌘/), which adds a search box.
struct ShortcutsSettingsView: View {
    var body: some View {
        Form {
            ForEach(ShortcutCatalog.groups(matching: "")) { group in
                Section(group.section.title) {
                    ForEach(group.entries) { entry in
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.title)
                                if let detail = entry.detail {
                                    Text(detail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 12)
                            ShortcutKeys(chords: entry.chords)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            Section {
                Text("The Help menu shows this list in a window you can search. Custom key bindings are on the roadmap.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
