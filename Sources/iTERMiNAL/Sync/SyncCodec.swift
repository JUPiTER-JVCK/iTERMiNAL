import Foundation

/// Pure helpers for encoding the sync payload and deciding which side wins.
///
/// Kept free of CloudKit and UI so the last-writer-wins rule and the archive
/// wire format stay easy to reason about (and, if a test target is added
/// later, easy to cover without spinning up a container).
enum SyncCodec {
    /// Builds the JSON bytes that go into the CloudKit `payload` field —
    /// identical to what Export writes to disk.
    static func encode(_ archive: WorkspaceArchive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(archive)
    }

    static func decode(_ data: Data) throws -> WorkspaceArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(WorkspaceArchive.self, from: data)
        guard archive.version <= WorkspaceArchive.currentVersion else {
            throw ArchiveError.unsupportedVersion(archive.version)
        }
        return archive
    }

    /// Last-writer-wins: apply the remote snapshot only when it is strictly
    /// newer than what this Mac last uploaded (or when this Mac has never
    /// synced). Equal timestamps are a no-op so two Macs that just agreed
    /// do not thrash.
    static func remoteIsNewer(localModified: Date?, remoteModified: Date) -> Bool {
        guard let localModified else { return true }
        return remoteModified > localModified
    }
}
