import Foundation

/// Where workspace state and preferences are kept, and how they travel
/// between a user's machines.
///
/// `LocalOnlySyncEngine` saves to Application Support and moves state through
/// explicit export/import. `CloudKitSyncEngine` adopts the same protocol for
/// iCloud when the build is signed with the iCloud entitlement and the user
/// picks that mode in Settings. Unsigned or un-entitled builds keep working:
/// the CloudKit engine reports `isAvailable == false` and falls back to
/// local-only behaviour.
protocol SyncEngine: AnyObject {
    var displayName: String { get }
    var statusDescription: String { get }
    var isAvailable: Bool { get }
    func syncNow(completion: @escaping (Result<Void, Error>) -> Void)
}

final class LocalOnlySyncEngine: SyncEngine {
    static let shared = LocalOnlySyncEngine()

    let displayName = "This Mac only"
    let isAvailable = true

    var statusDescription: String {
        "Workspaces and preferences are stored on this Mac. Use Export to move them to another machine."
    }

    func syncNow(completion: @escaping (Result<Void, Error>) -> Void) {
        WorkspaceStore.shared.saveNow()
        completion(.success(()))
    }

    /// Where the state file lives, for display in settings.
    var stateLocation: URL { WorkspaceStore.shared.stateFileURL }
}
