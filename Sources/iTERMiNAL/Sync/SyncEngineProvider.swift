import Foundation

/// Picks the active `SyncEngine` from `AppSettings.syncMode`.
///
/// Settings always binds to whatever this returns, so switching the mode
/// picker is enough to change both the status line and what Sync Now does.
/// When iCloud is selected but unavailable, `CloudKitSyncEngine` stays the
/// active engine (so the UI can explain why) and its `syncNow` falls back to
/// local-only behaviour.
enum SyncEngineProvider {
    static var active: SyncEngine {
        switch AppSettings.shared.syncMode {
        case .local:
            return LocalOnlySyncEngine.shared
        case .icloud:
            return CloudKitSyncEngine.shared
        }
    }

    /// Pull from iCloud when the user has that mode on. No-op for local mode
    /// and when CloudKit is unavailable — never throws into the UI.
    static func pullIfNeeded() {
        guard AppSettings.shared.syncMode == .icloud else { return }
        startWatchingStateFileIfNeeded()
        let engine = CloudKitSyncEngine.shared
        guard engine.isAvailable else {
            // Still refresh so Settings can show account / entitlement status.
            engine.refreshAvailability()
            return
        }
        engine.syncNow { result in
            if case .failure(let error) = result {
                NSLog("iCloud pull failed: \(error.localizedDescription)")
            }
        }
    }

    private static var pendingPush: DispatchWorkItem?

    /// Called after a local workspace save. Debounced so a burst of layout
    /// edits collapses into one CloudKit write.
    static func schedulePushAfterLocalSave() {
        guard AppSettings.shared.syncMode == .icloud else { return }

        CloudKitSyncEngine.shared.noteLocalEdit()
        guard CloudKitSyncEngine.shared.isAvailable else { return }

        pendingPush?.cancel()
        let work = DispatchWorkItem {
            CloudKitSyncEngine.shared.syncNow { result in
                if case .failure(let error) = result {
                    NSLog("iCloud push after save failed: \(error.localizedDescription)")
                }
            }
        }
        pendingPush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    // MARK: - State-file watcher

    /// Polls the workspace state file's modification date so iCloud push still
    /// runs after local saves even when `WorkspaceStore.saveNow` is not patched
    /// to call into the provider directly. Cheap (stat only) and only active
    /// while iCloud mode is selected.
    private static var watchTimer: Timer?
    private static var lastSeenStateMTime: Date?

    /// While > 0, mtime changes only refresh `lastSeenStateMTime` — they must
    /// not call `noteLocalEdit()`. `syncNow` and remote apply both write the
    /// state file; treating those writes as user edits would bump
    /// `localModifiedAt` past a just-fetched remote and upload stale data
    /// (last-writer-wins inversion), then loop every poll interval.
    private static var mtimeWatchSuppressionDepth = 0

    static func startWatchingStateFileIfNeeded() {
        guard AppSettings.shared.syncMode == .icloud else {
            watchTimer?.invalidate()
            watchTimer = nil
            return
        }
        guard watchTimer == nil else { return }

        lastSeenStateMTime = stateFileModificationDate()
        let timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            guard AppSettings.shared.syncMode == .icloud else { return }
            guard let mtime = stateFileModificationDate() else { return }
            if let last = lastSeenStateMTime, mtime <= last { return }
            lastSeenStateMTime = mtime
            if mtimeWatchSuppressionDepth > 0 { return }
            schedulePushAfterLocalSave()
        }
        // Allow the run loop to fire while the user is dragging a split.
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        watchTimer = timer
    }

    /// Runs `body` without treating state-file mtime bumps as local edits.
    /// Always refreshes the seen mtime afterward so a deferred timer tick
    /// does not mis-attribute the write.
    static func withMtimeWatchSuppressed(_ body: () -> Void) {
        mtimeWatchSuppressionDepth += 1
        defer {
            mtimeWatchSuppressionDepth -= 1
            acknowledgeStateFileMTime()
        }
        body()
    }

    /// Records the current state-file mtime as already seen (no push).
    static func acknowledgeStateFileMTime() {
        if let mtime = stateFileModificationDate() {
            lastSeenStateMTime = mtime
        }
    }

    private static func stateFileModificationDate() -> Date? {
        let url = WorkspaceStore.shared.stateFileURL
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }
}
