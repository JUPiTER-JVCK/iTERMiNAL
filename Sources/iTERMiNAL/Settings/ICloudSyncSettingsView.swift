import SwiftUI
import AppKit

/// Settings → Sync content: mode picker, status, Sync Now, and snapshots.
///
/// Kept in its own file so the large `SettingsViews.swift` does not need a
/// full rewrite to wire iCloud controls. `SyncSettingsView` in SettingsViews
/// forwards here.
struct ICloudSyncSettingsView: View {
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
                Picker("Sync mode", selection: $settings.syncMode) {
                    ForEach(AppSettings.SyncMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.syncMode) { _ in
                    CloudKitSyncEngine.shared.refreshAvailability {
                        statusTick += 1
                    }
                    SyncEngineProvider.startWatchingStateFileIfNeeded()
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
                SyncEngineProvider.startWatchingStateFileIfNeeded()
                CloudKitSyncEngine.shared.refreshAvailability {
                    statusTick += 1
                }
            }
        }
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
