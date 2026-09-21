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

    /// Called after a local save — of the workspace layout by
    /// `WorkspaceStore.saveNow`, or of a preference by the observer below.
    /// Debounced so a burst of edits collapses into one CloudKit write.
    static func schedulePushAfterLocalSave() {
        guard AppSettings.shared.syncMode == .icloud else { return }
        // Sync's own writes are not user edits. Treating them as such bumped
        // the local stamp past a just-fetched remote and re-uploaded what had
        // only just been downloaded, every poll, forever.
        guard suppressionDepth == 0 else { return }

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

    // MARK: - Suppression

    /// While > 0, local saves are sync's own and must not count as edits.
    ///
    /// This replaced a state-file mtime poller. The poller existed only to
    /// infer "the user changed something" from a file timestamp, and could not
    /// tell sync's writes from the user's — hence a suppression window that had
    /// to be held open across an asynchronous, debounced save it could not see
    /// the end of. Now `saveNow` says so directly and the window is exactly the
    /// call it wraps.
    private static var suppressionDepth = 0

    /// Runs `body` with local saves attributed to sync rather than the user.
    static func suppressingPush<T>(_ body: () -> T) -> T {
        suppressionDepth += 1
        defer { suppressionDepth -= 1 }
        return body()
    }

    // MARK: - Preference changes

    private static var defaultsObserver: NSObjectProtocol?
    private static var pendingPreferencePush: DispatchWorkItem?

    /// Preferences live in `UserDefaults`, not the state file, so nothing about
    /// a theme, font or SSH connection change touches `saveNow`. Without this
    /// they synced in only one direction: uploaded whenever some *layout* edit
    /// happened to follow, and otherwise silently overwritten by the next
    /// remote apply.
    static func startObservingPreferenceChanges() {
        guard defaultsObserver == nil else { return }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { _ in
            guard AppSettings.shared.syncMode == .icloud else { return }
            guard suppressionDepth == 0 else { return }
            // Coalesce: a slider emits a write per frame.
            pendingPreferencePush?.cancel()
            let work = DispatchWorkItem { schedulePushAfterLocalSave() }
            pendingPreferencePush = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
        }
    }
}
