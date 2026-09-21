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

    /// CloudKit rejects records much past 1 MB. Above this the payload travels
    /// as a CKAsset instead, which the reader already accepted but nothing
    /// ever produced — so a large enough workspace set simply failed to upload,
    /// permanently and with a generic error.
    private static let inlinePayloadLimit = 700_000

    let displayName = "iCloud"

    private let container: CKContainer
    private let database: CKDatabase

    /// Wall-clock of the last successful fetch or upload, for the Settings
    /// status line. Not persisted across launches — CloudKit is the source
    /// of truth for what is newer.
    private(set) var lastSyncedAt: Date?

    private(set) var lastErrorDescription: String?

    /// A newer layout from another Mac, held back because shells are running
    /// here. Adopting it would drop the panes those processes live in.
    struct PendingRemoteLayout {
        let state: AppStateSnapshot
        let deviceName: String
        let modifiedAt: Date
        let liveSessions: Int
    }

    private(set) var pendingRemoteLayout: PendingRemoteLayout?

    /// Cached account / entitlement probe. Refreshed on sync and when
    /// Settings asks for status.
    private var accountStatus: CKAccountStatus = .couldNotDetermine
    private var containerUsable = true
    private var probed = false

    /// True while applying a remote snapshot, so the ensuing local save does
    /// not count as a newer local edit (which would immediately re-upload).
    private var isApplyingRemote = false

    /// One sync at a time. Launch delivers both didFinishLaunching and
    /// didBecomeActive, so two syncs used to race on the same record: both
    /// took the upload branch, and the loser came back with
    /// `serverRecordChanged` — a red status line on a launch where nothing
    /// was wrong.
    private var isSyncing = false

    /// Timestamp of this Mac's syncable content for last-writer-wins.
    /// Bumped on local edits; set to the remote value after a successful
    /// apply; set to the upload time after a successful push.
    private var localModifiedAt: Date? {
        get {
            UserDefaults.standard.object(forKey: "icloudSync.localModifiedAt") as? Date
        }
        set {
            // This lives in UserDefaults, so writing it posts
            // didChangeNotification — which the preference observer would read
            // back as a user edit.
            SyncEngineProvider.suppressingPush {
                UserDefaults.standard.set(newValue, forKey: "icloudSync.localModifiedAt")
            }
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
        if let pendingRemoteLayout {
            let shells = pendingRemoteLayout.liveSessions == 1 ? "shell is" : "shells are"
            parts.append("A newer layout from \(pendingRemoteLayout.deviceName) is waiting: \(pendingRemoteLayout.liveSessions) \(shells) still running here, and adopting it would close them.")
        }
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
        // Never move the stamp backwards. Two Macs rarely agree on the clock,
        // and adopting a remote stamp from a Mac that runs fast used to make
        // every subsequent local edit look older than what it replaced — so
        // the next sync threw the edit away and re-applied the remote, for the
        // whole duration of the skew.
        let now = Date()
        if let current = localModifiedAt, current > now {
            localModifiedAt = current.addingTimeInterval(0.001)
        } else {
            localModifiedAt = now
        }
    }

    func prepareForEnablingICloud() {
        if localModifiedAt == nil {
            localModifiedAt = Date()
        }
        refreshAvailability()
    }

    func refreshAvailability(completion: (() -> Void)? = nil) {
        container.accountStatus { [weak self] status, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.probed = true
                if let error {
                    NSLog("CloudKit accountStatus failed: \(error.localizedDescription)")
                    self.lastErrorDescription = error.localizedDescription
                    // The probe failed, so we no longer know the account
                    // state. Leaving the previous value made Settings report
                    // "Available: Yes" through an entire offline session.
                    self.accountStatus = .couldNotDetermine
                    if Self.looksLikeMissingEntitlement(error) {
                        self.containerUsable = false
                    }
                } else {
                    self.accountStatus = status
                    // A successful probe clears a stale error. Otherwise one
                    // network blip left "Last error: …" pinned to the status
                    // text for the rest of the session.
                    self.lastErrorDescription = nil
                    // Reaching the container at all disproves the entitlement
                    // diagnosis, whatever an earlier transient error implied.
                    self.containerUsable = true
                }
                completion?()
            }
        }
    }

    func syncNow(completion: @escaping (Result<Void, Error>) -> Void) {
        guard !isSyncing else {
            completion(.success(()))
            return
        }
        isSyncing = true
        let finish: (Result<Void, Error>) -> Void = { [weak self] result in
            self?.isSyncing = false
            completion(result)
        }

        // Always persist locally first so a CloudKit outage never loses work.
        // Suppressed because this is sync's own write, not a user edit.
        SyncEngineProvider.suppressingPush {
            WorkspaceStore.shared.saveNow()
        }

        refreshAvailability { [weak self] in
            guard let self else {
                finish(.success(()))
                return
            }

            guard self.isAvailable else {
                finish(.success(()))
                return
            }

            self.performSync(completion: finish)
        }
    }

    /// Adopts a layout that was held back while shells were running. Explicit
    /// user action, so closing those shells is now what they asked for.
    func applyPendingLayout() {
        guard let pending = pendingRemoteLayout else { return }
        isApplyingRemote = true
        SyncEngineProvider.suppressingPush {
            WorkspaceStore.shared.applySnapshot(pending.state)
        }
        isApplyingRemote = false
        localModifiedAt = pending.modifiedAt
        pendingRemoteLayout = nil
        lastSyncedAt = Date()
    }

    func discardPendingLayout() {
        guard let pending = pendingRemoteLayout else { return }
        // Keeping this Mac's layout is a local edit: it has to win the next
        // round, or the same remote comes straight back.
        pendingRemoteLayout = nil
        localModifiedAt = pending.modifiedAt.addingTimeInterval(1)
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
                    self.applyRemote(record: remoteRecord, remoteModified: remoteModified, completion: completion)
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

    private func applyRemote(
        record: CKRecord,
        remoteModified: Date,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let payload = Self.payloadData(from: record) else {
            let error = SyncError.missingPayload
            lastErrorDescription = error.localizedDescription
            completion(.failure(error))
            return
        }

        let device = record["deviceName"] as? String ?? "another Mac"

        // Already held back at this exact stamp — nothing new to do, and
        // re-applying preferences every poll is just churn.
        if let pending = pendingRemoteLayout, pending.modifiedAt == remoteModified {
            completion(.success(()))
            return
        }

        do {
            let archive = try SyncCodec.decode(payload)
            isApplyingRemote = true
            var outcome = WorkspaceStore.RemoteApplyOutcome.applied
            SyncEngineProvider.suppressingPush {
                archive.preferences.apply(to: AppSettings.shared)
                outcome = WorkspaceStore.shared.applyRemoteSnapshot(archive.state)
            }
            isApplyingRemote = false

            switch outcome {
            case .applied:
                pendingRemoteLayout = nil
                // Use the stamp already read for the comparison. Re-reading the
                // raw field here meant a record without `modifiedAt` set this
                // to nil, which made the same remote look newer forever and
                // re-applied it on every poll.
                localModifiedAt = remoteModified
                NSLog("iCloud sync applied remote state from \(device)")
            case .deferredLiveSessions(let count):
                // Preferences and recents landed; the layout waits. The stamp
                // is deliberately NOT advanced — this Mac has not adopted the
                // remote state, and pretending otherwise would lose it.
                pendingRemoteLayout = PendingRemoteLayout(
                    state: archive.state,
                    deviceName: device,
                    modifiedAt: remoteModified,
                    liveSessions: count
                )
                NSLog("iCloud sync held back a layout from \(device): \(count) live shell(s)")
            }

            lastSyncedAt = Date()
            lastErrorDescription = nil
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

        // Large payloads travel as an asset; CloudKit refuses the record
        // outright past roughly 1 MB.
        var assetURL: URL?
        if payload.count > Self.inlinePayloadLimit {
            do {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("iterminal-sync-\(UUID().uuidString).json")
                try payload.write(to: url, options: .atomic)
                assetURL = url
                record["payload"] = CKAsset(fileURL: url)
            } catch {
                NSLog("iCloud sync could not stage the payload: \(error.localizedDescription)")
                lastErrorDescription = error.localizedDescription
                completion(.failure(error))
                return
            }
        } else {
            record["payload"] = payload as CKRecordValue
        }

        record["schemaVersion"] = WorkspaceArchive.currentVersion as CKRecordValue
        record["modifiedAt"] = modifiedAt as CKRecordValue
        record["deviceName"] = (Host.current().localizedName ?? "Mac") as CKRecordValue

        database.save(record) { [weak self] _, error in
            DispatchQueue.main.async {
                if let assetURL {
                    try? FileManager.default.removeItem(at: assetURL)
                }
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

    /// Whether an error means this build simply cannot reach CloudKit, as
    /// opposed to something the user can fix right now.
    ///
    /// Deliberately excludes `.notAuthenticated` and `.permissionFailure`:
    /// both are what a signed-out account looks like. Counting them here
    /// latched the container unusable for the life of the process and told the
    /// user to go and fix their code signing, when all they had to do was sign
    /// in to iCloud — which the next probe would have seen.
    private static func looksLikeMissingEntitlement(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        if text.contains("entitlement") { return true }
        if text.contains("container"), text.contains("not available") { return true }
        if let ck = error as? CKError, ck.code == .badContainer || ck.code == .badDatabase {
            return true
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
