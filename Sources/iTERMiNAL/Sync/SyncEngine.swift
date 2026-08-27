import Foundation

/// Where workspace state and preferences are kept, and (eventually) how they
/// travel between a user's machines.
///
/// Today only `LocalOnlySyncEngine` exists: state lives in Application Support
/// and moves between machines through explicit export/import. A CloudKit
/// engine can adopt this protocol later without touching the UI — that work is
/// deferred because iCloud requires a paid developer account, the iCloud
/// entitlement, and signed builds, none of which an open-source contributor
/// building from source necessarily has.
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
