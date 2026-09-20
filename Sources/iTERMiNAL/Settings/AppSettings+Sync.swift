import Foundation

/// Where workspaces and preferences are kept, and whether iCloud is tried.
///
/// Stored in UserDefaults under `syncMode` rather than as a stored property on
/// `AppSettings`, so the large preferences file does not need a full rewrite
/// for this feature. Settings binds through the computed property below.
enum SyncMode: String, CaseIterable, Identifiable {
    case local
    case icloud

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local: return "This Mac only"
        case .icloud: return "iCloud"
        }
    }
}

extension AppSettings {
    /// `local` keeps state on this Mac only; `icloud` uses CloudKit when the
    /// build is entitled and the account is signed in. Persisted so the choice
    /// survives relaunch. Secrets still never leave this Mac either way.
    var syncMode: SyncMode {
        get {
            SyncMode(rawValue: UserDefaults.standard.string(forKey: "syncMode") ?? "") ?? .local
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "syncMode")
            objectWillChange.send()
            if newValue == .icloud {
                CloudKitSyncEngine.shared.prepareForEnablingICloud()
            }
        }
    }

    /// Clears the sync-mode preference. Called from Advanced → Reset alongside
    /// `resetToDefaults()` so a full reset returns to This Mac only.
    func resetSyncModeToLocal() {
        syncMode = .local
    }
}
