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

    /// One subdirectory per pane, named by that pane's stable history ID —
    /// without this, every `HTTPClientModel` read and wrote the same flat
    /// directory, so opening a second pane showed the first one's requests,
    /// and clearing history in either one cleared both.
    private static let rootDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("iTERMiNAL", isDirectory: true)
            .appendingPathComponent("HTTPHistory", isDirectory: true)
    }()

    private static func directory(for scope: UUID) -> URL {
        let directory = rootDirectory.appendingPathComponent(scope.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Redacts the request's own URL, headers, and body, then writes one
    /// new file into `scope`'s own directory, then prunes that directory
    /// down to `maxEntries` — oldest first, by modification date, not by
    /// trying to parse every file's own timestamp.
    static func append(_ entry: HTTPHistoryEntry, scope: UUID) {
        var redacted = entry
        redacted.url = SecretRedactor.redact(entry.url)
        redacted.headers = entry.headers.map { HTTPHeaderField(id: $0.id, name: $0.name, value: redactedHeaderValue(name: $0.name, value: $0.value)) }
        redacted.body = entry.body.map(SecretRedactor.redact)

        let directory = directory(for: scope)
        guard let data = try? JSONEncoder.httpHistory.encode(redacted) else { return }
        let fileURL = directory.appendingPathComponent("\(redacted.id.uuidString).json")
        try? data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        prune(in: directory)
    }

    /// `SecretRedactor`'s own patterns are context-dependent — they key off
    /// a header *name* next to its value, such as `Authorization: …` or
    /// `api_key=…` — so redacting a bare value alone, with no name beside
    /// it, never gives them anything to match. Redacting `"name: value"`
    /// together and then stripping the name back off recovers the redacted
    /// value with that context intact; if the known "name: " prefix somehow
    /// didn't survive (nothing in `SecretRedactor`'s patterns today would
    /// touch it, but this is cheap insurance against a future one that
    /// might), redacting the bare value is still strictly safer than
    /// skipping redaction outright.
    private static func redactedHeaderValue(name: String, value: String) -> String {
        let prefix = "\(name): "
        let redacted = SecretRedactor.redact(prefix + value)
        if redacted.hasPrefix(prefix) {
            return String(redacted.dropFirst(prefix.count))
        }
        return SecretRedactor.redact(value)
    }

    /// Every entry saved for `scope`, newest first.
    static func loadAll(scope: UUID) -> [HTTPHistoryEntry] {
        let directory = directory(for: scope)
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

    static func clear(scope: UUID) {
        let directory = directory(for: scope)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    /// Drops the oldest files once there are more than `maxEntries`, by
    /// each file's own modification date — cheaper than decoding every file
    /// just to read its `sentAt`, and just as correct, since `append`
    /// writes a fresh file for every new entry.
    private static func prune(in directory: URL) {
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
