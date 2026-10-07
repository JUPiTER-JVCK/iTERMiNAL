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

    /// Only names the directory. Creating it here made every pane — including
    /// every one that never sent anything — leave an empty folder behind just
    /// by being opened; `append` creates it when there is something to put in
    /// it.
    private static func directory(for scope: UUID) -> URL {
        rootDirectory.appendingPathComponent(scope.uuidString, isDirectory: true)
    }

    /// Redacts the request's own URL, headers, and body, then writes one
    /// new file into `scope`'s own directory, then prunes that directory
    /// down to `maxEntries` — oldest first, by modification date, not by
    /// trying to parse every file's own timestamp.
    static func append(_ entry: HTTPHistoryEntry, scope: UUID) {
        var redacted = entry
        redacted.url = HTTPRedaction.redactedURL(entry.url)
        redacted.headers = entry.headers.map {
            HTTPHeaderField(id: $0.id, name: $0.name, value: HTTPRedaction.redactedHeaderValue(name: $0.name, value: $0.value))
        }
        redacted.body = entry.body.map(SecretRedactor.redact)

        let directory = directory(for: scope)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder.httpHistory.encode(redacted) else { return }
        let fileURL = directory.appendingPathComponent("\(redacted.id.uuidString).json")
        try? data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        prune(in: directory)
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

    /// Removes the history of every pane that isn't in `ids`: panes closed
    /// since the last launch, an import that replaced the layout, a previous
    /// launch's side panel, and the flat files the pre-scoping layout left
    /// directly under the root. A closed pane's history is unreachable —
    /// nothing in the UI can name it again — so keeping it would only be
    /// keeping a (redacted, best-effort) record of requests on disk for no
    /// one.
    static func pruneAll(keeping ids: Set<UUID>) {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        for item in items {
            guard let id = UUID(uuidString: item.lastPathComponent), ids.contains(id) else {
                try? FileManager.default.removeItem(at: item)
                continue
            }
        }
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
