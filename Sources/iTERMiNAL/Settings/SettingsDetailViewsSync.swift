import SwiftUI
import AppKit

/// Settings → Sync: mode picker (This Mac only | iCloud), status, Sync Now, and snapshots.
struct SyncSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: WorkspaceStore
    @State private var syncMessage: String?
    @State private var isSyncing = false
    /// Bumped after sync / availability refresh so status text re-reads the engine.
    @State private var statusTick = 0

    private var engine: SyncEngine { SyncEngineProvider.active }

    var body: some View {
        Form {
            Section("Mode") {
                Picker("Sync mode", selection: syncModeBinding) {
                    ForEach(SyncMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.syncMode) { _, _ in
                    CloudKitSyncEngine.shared.refreshAvailability {
                        statusTick += 1
                    }
                }
            }

            Section("Status") {
                let _ = statusTick
                LabeledContent("Engine", value: engine.displayName)
                Text(engine.statusDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.syncMode == .icloud {
                    LabeledContent("Available", value: engine.isAvailable ? "Yes" : "No")
                    Button(isSyncing ? "Syncing…" : "Sync Now") {
                        runSyncNow()
                    }
                    .disabled(isSyncing)
                    if let syncMessage {
                        Text(syncMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let pending = CloudKitSyncEngine.shared.pendingRemoteLayout {
                    // A sync must not close running shells on its own, so the
                    // decision comes here instead.
                    LabeledContent("Layout waiting", value: "from \(pending.deviceName)")
                    Text("Applying it closes the \(pending.liveSessions) shell\(pending.liveSessions == 1 ? "" : "s") still running on this Mac. Keeping this layout uploads it instead on the next sync.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    HStack {
                        Button("Apply Layout") {
                            CloudKitSyncEngine.shared.applyPendingLayout()
                            statusTick += 1
                        }
                        Button("Keep This Mac's") {
                            CloudKitSyncEngine.shared.discardPendingLayout()
                            statusTick += 1
                        }
                    }
                }
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

            Section("About iCloud sync") {
                Text("""
                Secrets never sync: the API token stays in the keychain, SSH has no passwords to carry, and machine-local paths such as the composer shell are left out of the payload.

                Unsigned or CI builds often show iCloud as unavailable until the app is signed with an Apple Developer account and the iCloud capability (container iCloud.com.jupiterjvck.iterminal). Hardened Runtime stays on; App Sandbox stays off so shells can still reach ~/.ssh and Homebrew.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if settings.syncMode == .icloud {
                CloudKitSyncEngine.shared.refreshAvailability {
                    statusTick += 1
                }
            }
        }
    }

    private var syncModeBinding: Binding<SyncMode> {
        Binding(
            get: { settings.syncMode },
            set: { settings.syncMode = $0 }
        )
    }

    private func runSyncNow() {
        isSyncing = true
        syncMessage = nil
        engine.syncNow { result in
            isSyncing = false
            statusTick += 1
            switch result {
            case .success:
                syncMessage = engine.isAvailable
                    ? "Sync finished."
                    : "Saved locally. iCloud is not available in this build or account — see status above."
            case .failure(let error):
                syncMessage = error.localizedDescription
            }
        }
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
