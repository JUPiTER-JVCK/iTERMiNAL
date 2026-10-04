import Foundation

/// One request that was sent, kept for the history list and for loading
/// back into the builder.
///
/// Deliberately slim: no response headers or body, and no record of which
/// values (if any) came from a saved collection's `{{variable}}` — that
/// redaction scheme arrives with collections themselves. What *is* kept
/// here — the request's own headers and body — is run through
/// `SecretRedactor` before `HTTPHistoryStore.append` ever writes it, the
/// same way `ContextSanitizer` redacts before the AI assistant's path sends
/// anything anywhere. The in-session builder and response view still show
/// the real, unredacted values; only the persisted copy is masked.
struct HTTPHistoryEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var sentAt: Date
    var method: String
    var url: String
    var headers: [HTTPHeaderField]
    var body: String?
    var statusCode: Int?
    var errorDescription: String?
}

/// Keeps sent requests on disk as small, individual files, the way
/// `TranscriptStore` keeps closed-session transcripts — one file per entry,
/// not one growing array in one file, so a single bad write can't corrupt
/// the whole history.
///
/// Excluded from the exported workspace archive, for the same reason
/// `TranscriptStore` gives for terminal transcripts: this is the least
/// predictable content in the app. A typed header or body can hold anything
/// a person pastes, redaction is best-effort, and none of that belongs in a
/// file meant to be shared.
enum HTTPHistoryStore {
    /// Plenty for a useful history list without growing without bound.
    static let maxEntries = 200

    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base
            .appendingPathComponent("iTERMiNAL", isDirectory: true)
            .appendingPathComponent("HTTPHistory", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private static func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    /// Redacts the request's own headers and body, then writes one new
    /// file, then prunes down to `maxEntries` — oldest first, by
    /// modification date, not by trying to parse every file's own
    /// timestamp.
    static func append(_ entry: HTTPHistoryEntry) {
        var redacted = entry
        redacted.headers = entry.headers.map { HTTPHeaderField(id: $0.id, name: $0.name, value: SecretRedactor.redact($0.value)) }
        redacted.body = entry.body.map(SecretRedactor.redact)

        guard let data = try? JSONEncoder.httpHistory.encode(redacted) else { return }
        let fileURL = url(for: redacted.id)
        try? data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        prune()
    }

    /// Every saved entry, newest first.
    static func loadAll() -> [HTTPHistoryEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        let entries = files.compactMap { file -> HTTPHistoryEntry? in
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONDecoder.httpHistory.decode(HTTPHistoryEntry.self, from: data)
        }
        return entries.sorted { $0.sentAt > $1.sentAt }
    }

    static func clear() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    /// Drops the oldest files once there are more than `maxEntries`, by
    /// each file's own modification date — cheaper than decoding every file
    /// just to read its `sentAt`, and just as correct, since `append`
    /// writes a fresh file for every new entry.
    private static func prune() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        guard files.count > maxEntries else { return }
        let sorted = files.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return lhsDate < rhsDate
        }
        for file in sorted.prefix(sorted.count - maxEntries) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}

private extension JSONEncoder {
    static let httpHistory: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let httpHistory: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
