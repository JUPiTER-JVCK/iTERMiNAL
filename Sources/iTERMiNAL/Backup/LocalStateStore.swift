import Foundation

/// Where workspace state and preferences live, and how a user moves them
/// between machines.
///
/// State is kept in Application Support on this Mac and travels by explicit
/// snapshot: Settings → Backup writes an `.iterminal` file and reads one back.
/// There is no background service and nothing leaves the machine on its own.
///
/// This used to sit behind a `SyncEngine` protocol with a CloudKit
/// implementation beside it. That path required an Apple Developer iCloud
/// container, so every unsigned or self-built copy of the app showed a sync
/// mode it could never use, and the protocol existed only to hold the two
/// apart. Snapshots do the same job — move my setup to my other Mac — without
/// an account, so the protocol and the second implementation went with it.
enum LocalStateStore {
    static let displayName = "This Mac"

    static var statusDescription: String {
        "Workspaces and preferences are stored on this Mac. Export a snapshot to move them to another machine."
    }

    /// Where the state file lives, for display in settings.
    static var stateLocation: URL { WorkspaceStore.shared.stateFileURL }

    /// Flushes the debounced save so the file on disk matches the window.
    /// Export builds its archive from the live store rather than from disk, so
    /// this is for the user who wants to copy the file themselves.
    static func flush() {
        WorkspaceStore.shared.saveNow()
    }
}
