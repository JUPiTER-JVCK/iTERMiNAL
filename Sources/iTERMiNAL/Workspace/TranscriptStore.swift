import Foundation

/// Keeps the terminal contents of closed sessions on disk, so reopening one
/// from Recents shows what was on it rather than a blank shell.
///
/// A transcript lives exactly as long as its Recents entry: it is written when
/// the session closes and deleted when the entry leaves the list, whether that
/// is by reopening it, removing it, or falling off the end of the twenty the
/// list keeps.
///
/// Deliberately kept out of the exported workspace archive. That export is
/// documented as carrying no secrets, and terminal output is the least
/// predictable content in the app — tokens echoed by a failed command, `env`
/// dumps, connection strings. Those can be on this Mac, under the user's own
/// directory, without also travelling in a file meant to be shared.
enum TranscriptStore {
    /// Roughly a full screen of scrollback per entry. Twenty entries at this
    /// cap is a few megabytes at worst, which is proportionate for something
    /// the user never asked to store.
    static let maxBytes = 256 * 1024

    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base
            .appendingPathComponent("iTERMiNAL", isDirectory: true)
            .appendingPathComponent("Transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    private static func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).txt")
    }

    static func save(_ text: String, for id: UUID) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Owner-only: this is terminal output, and nothing else on the machine
        // has a reason to read it.
        try? text.data(using: .utf8)?.write(to: url(for: id), options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url(for: id).path
        )
    }

    static func load(for id: UUID) -> String? {
        try? String(contentsOf: url(for: id), encoding: .utf8)
    }

    static func remove(for id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// Drops transcripts whose Recents entry is gone — the sweep that catches
    /// entries evicted by the twenty-item cap, and anything left behind by a
    /// crash before `remove` ran.
    static func pruneAll(keeping ids: Set<UUID>) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for file in files {
            let name = file.deletingPathExtension().lastPathComponent
            guard let id = UUID(uuidString: name), ids.contains(id) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
        }
    }
}
