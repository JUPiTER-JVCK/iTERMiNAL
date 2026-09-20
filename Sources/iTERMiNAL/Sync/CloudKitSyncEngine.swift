import CloudKit
import Foundation

/// CloudKit-backed sync: one private-database record per iCloud account,
/// carrying the same `WorkspaceArchive` JSON that Export writes to disk.
///
/// Last-writer-wins on `modifiedAt`. Secrets never appear in the payload —
/// the archive already excludes the keychain token, SSH passwords, and
/// machine-local paths like `composerShell`.
///
/// Unsigned Debug builds (`CODE_SIGN_IDENTITY "-"`) and builds without the
/// iCloud entitlement typically report `isAvailable == false`. That is
/// expected: Settings shows why, and `syncNow` falls back to a local save
/// so nothing crashes.
final class CloudKitSyncEngine: SyncEngine {
    static let shared = CloudKitSyncEngine()

    static let containerIdentifier = "iCloud.com.jupiterjvck.iterminal"
    static let recordType = "ITerminalSyncState"
    static let recordName = "primary"

    let displayName = "iCloud"

    private let container: CKContainer
    private let database: CKDatabase

    /// Wall-clock of the last successful fetch or upload, for the Settings
    /// status line. Not persisted across launches — CloudKit is the source
    /// of truth for what is newer.
    private(set) var lastSyncedAt: Date?

    private(set) var lastErrorDescription: String?

    /// Cached account / entitlement probe. Refreshed on sync and when
    /// Settings asks for status.
    private var accountStatus: CKAccountStatus = .couldNotDetermine
    private var containerUsable = true
    private var probed = false

    /// True while applying a remote snapshot, so the ensuing local save does
    /// not count as a newer local edit (which would immediately re-upload).
    private var isApplyingRemote = false

    /// Timestamp of this Mac's syncable content for last-writer-wins.
    /// Bumped on local edits; set to the remote value after a successful
    /// apply; set to the upload time after a successful push.
    private var localModifiedAt: Date? {
        get {
            UserDefaults.standard.object(forKey: "icloudSync.localModifiedAt") as? Date
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "icloudSync.localModifiedAt")
        }
    }

    private init() {
        container = CKContainer(identifier: Self.containerIdentifier)
        database = container.privateCloudDatabase
        refreshAvailability()
    }

    var isAvailable: Bool {
        guard AppSettings.shared.syncMode == .icloud else { return false }
        guard containerUsable else { return false }
        return accountStatus == .available
    }

    var statusDescription: String {
        if AppSettings.shared.syncMode != .icloud {
            return "iCloud sync is off. Choose iCloud under Mode to enable it."
        }
        if !containerUsable {
            return "iCloud is unavailable in this build. Unsigned or un-entitled builds cannot reach CloudKit — use a development-signed build with the iCloud capability, or stay on This Mac only."
        }
        switch accountStatus {
        case .available:
            break
        case .noAccount:
            return "Sign in to iCloud in System Settings to sync across Macs."
        case .restricted:
            return "iCloud access is restricted on this Mac (parental controls or managed device)."
        case .couldNotDetermine:
            return probed
                ? "Could not determine iCloud account status. Try Sync Now, or check System Settings → Apple ID."
                : "Checking iCloud account status…"
        case .temporarilyUnavailable:
            return "iCloud is temporarily unavailable. Try again in a moment."
        @unknown default:
            return "iCloud account status is unknown."
        }

        var parts: [String] = [
            "Workspaces and preferences sync through your private iCloud database. Secrets, keychain items, and machine-local paths are never uploaded.",
        ]
        if let lastSyncedAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            parts.append("Last synced \(formatter.localizedString(for: lastSyncedAt, relativeTo: Date())).")
        }
        if let lastErrorDescription {
            parts.append("Last error: \(lastErrorDescription)")
        }
        return parts.joined(separator: " ")
    }

    func noteLocalEdit() {
        guard !isApplyingRemote else { return }
        localModifiedAt = Date()
    }

    func prepareForEnablingICloud() {
        if localModifiedAt == nil {
            localModifiedAt = Date()
        }
        refreshAvailability()
        SyncEngineProvider.startWatchingStateFileIfNeeded()
    }

    func refreshAvailability(completion: (() -> Void)? = nil) {
        container.accountStatus { [weak self] status, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.probed = true
                if let error {
                    NSLog("CloudKit accountStatus failed: \(error.localizedDescription)")
                    self.lastErrorDescription = error.localizedDescription
                    if Self.looksLikeMissingEntitlement(error) {
                        self.containerUsable = false
                    }
                } else {
                    self.accountStatus = status
                }
                completion?()
            }
        }
    }

    func syncNow(completion: @escaping (Result<Void, Error>) -> Void) {
        // Always persist locally first so a CloudKit outage never loses work.
        WorkspaceStore.shared.saveNow()

        refreshAvailability { [weak self] in
            guard let self else {
                completion(.success(()))
                return
            }

            guard self.isAvailable else {
                completion(.success(()))
                return
            }

            self.performSync(completion: completion)
        }
    }

    private func performSync(completion: @escaping (Result<Void, Error>) -> Void) {
        let store = WorkspaceStore.shared
        let settings = AppSettings.shared
        let now = Date()

        let archive = WorkspaceArchive(
            version: WorkspaceArchive.currentVersion,
            exportedAt: now,
            state: store.currentSnapshot(),
            preferences: PreferencesArchive(settings: settings)
        )

        let localPayload: Data
        do {
            localPayload = try SyncCodec.encode(archive)
        } catch {
            NSLog("iCloud sync encode failed: \(error.localizedDescription)")
            lastErrorDescription = error.localizedDescription
            completion(.failure(error))
            return
        }

        let recordID = CKRecord.ID(recordName: Self.recordName)
        database.fetch(withRecordID: recordID) { [weak self] remoteRecord, error in
            DispatchQueue.main.async {
                guard let self else {
                    completion(.success(()))
                    return
                }

                if let error = error as? CKError, error.code == .unknownItem {
                    self.upload(payload: localPayload, modifiedAt: now, existing: nil, completion: completion)
                    return
                }

                if let error {
                    if Self.looksLikeMissingEntitlement(error) {
                        self.containerUsable = false
                    }
                    NSLog("iCloud fetch failed: \(error.localizedDescription)")
                    self.lastErrorDescription = error.localizedDescription
                    completion(.failure(error))
                    return
                }

                guard let remoteRecord else {
                    self.upload(payload: localPayload, modifiedAt: now, existing: nil, completion: completion)
                    return
                }

                let remoteModified = remoteRecord["modifiedAt"] as? Date ?? .distantPast
                let remoteVersion = remoteRecord["schemaVersion"] as? Int ?? 1

                if remoteVersion > WorkspaceArchive.currentVersion {
                    let unsupported = ArchiveError.unsupportedVersion(remoteVersion)
                    self.lastErrorDescription = unsupported.localizedDescription
                    completion(.failure(unsupported))
                    return
                }

                if SyncCodec.remoteIsNewer(localModified: self.localModifiedAt, remoteModified: remoteModified) {
                    self.applyRemote(record: remoteRecord, completion: completion)
                } else if let localModified = self.localModifiedAt, remoteModified == localModified {
                    self.lastSyncedAt = Date()
                    self.lastErrorDescription = nil
                    completion(.success(()))
                } else {
                    self.upload(
                        payload: localPayload,
                        modifiedAt: max(now, self.localModifiedAt ?? now),
                        existing: remoteRecord,
                        completion: completion
                    )
                }
            }
        }
    }

    private func applyRemote(record: CKRecord, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let payload = Self.payloadData(from: record) else {
            let error = SyncError.missingPayload
            lastErrorDescription = error.localizedDescription
            completion(.failure(error))
            return
        }

        do {
            let archive = try SyncCodec.decode(payload)
            isApplyingRemote = true
            archive.preferences.apply(to: AppSettings.shared)
            WorkspaceStore.shared.applySnapshot(archive.state)
            isApplyingRemote = false
            localModifiedAt = record["modifiedAt"] as? Date
            lastSyncedAt = Date()
            lastErrorDescription = nil
            let device = record["deviceName"] as? String ?? "another Mac"
            NSLog("iCloud sync applied remote state from \(device)")
            completion(.success(()))
        } catch {
            isApplyingRemote = false
            NSLog("iCloud apply failed: \(error.localizedDescription)")
            lastErrorDescription = error.localizedDescription
            completion(.failure(error))
        }
    }

    private func upload(
        payload: Data,
        modifiedAt: Date,
        existing: CKRecord?,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let record: CKRecord
        if let existing {
            record = existing
        } else {
            record = CKRecord(
                recordType: Self.recordType,
                recordID: CKRecord.ID(recordName: Self.recordName)
            )
        }

        record["payload"] = payload as CKRecordValue
        record["schemaVersion"] = WorkspaceArchive.currentVersion as CKRecordValue
        record["modifiedAt"] = modifiedAt as CKRecordValue
        record["deviceName"] = (Host.current().localizedName ?? "Mac") as CKRecordValue

        database.save(record) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else {
                    completion(.success(()))
                    return
                }
                if let error {
                    if Self.looksLikeMissingEntitlement(error) {
                        self.containerUsable = false
                    }
                    NSLog("iCloud upload failed: \(error.localizedDescription)")
                    self.lastErrorDescription = error.localizedDescription
                    completion(.failure(error))
                    return
                }
                self.localModifiedAt = modifiedAt
                self.lastSyncedAt = Date()
                self.lastErrorDescription = nil
                completion(.success(()))
            }
        }
    }

    private static func payloadData(from record: CKRecord) -> Data? {
        if let data = record["payload"] as? Data { return data }
        if let asset = record["payload"] as? CKAsset, let url = asset.fileURL {
            return try? Data(contentsOf: url)
        }
        return nil
    }

    private static func looksLikeMissingEntitlement(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        if text.contains("entitlement") { return true }
        if text.contains("container"), text.contains("not available") { return true }
        if let ck = error as? CKError {
            switch ck.code {
            case .notAuthenticated, .permissionFailure, .badDatabase:
                return true
            default:
                break
            }
        }
        return false
    }
}

enum SyncError: LocalizedError {
    case missingPayload

    var errorDescription: String? {
        switch self {
        case .missingPayload:
            return "The iCloud sync record had no payload."
        }
    }
}
