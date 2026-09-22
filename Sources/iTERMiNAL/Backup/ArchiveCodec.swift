import Foundation

/// The one place that turns a `WorkspaceArchive` into bytes and back.
///
/// Export and Import both go through here so the wire format — ISO-8601 dates,
/// sorted keys — and the version guard cannot drift apart between the two
/// halves of a round trip.
enum ArchiveCodec {
    static func encode(_ archive: WorkspaceArchive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(archive)
    }

    /// Rejects an archive written by a newer build rather than decoding it
    /// partially: a snapshot that silently loses the fields this version does
    /// not know about would replace the user's layout with a lossy copy.
    static func decode(_ data: Data) throws -> WorkspaceArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(WorkspaceArchive.self, from: data)
        guard archive.version <= WorkspaceArchive.currentVersion else {
            throw ArchiveError.unsupportedVersion(archive.version)
        }
        return archive
    }
}
