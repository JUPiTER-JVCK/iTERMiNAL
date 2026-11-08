import Foundation

/// What becomes of a saved layout this build cannot read — one written by a
/// newer build, say, when an older one is opened after it.
///
/// `WorkspaceStore` starts a new layout then, and saves it a second later where
/// the old one was; the same launch used to prune every transcript and every
/// HTTP history the old one pointed at, so nothing of it was left to go back
/// to. So the file is moved aside first, under a name of its own in the same
/// folder, and kept — and while a copy is kept, nothing it may refer to is
/// pruned. Quit, rename it back to `state.json`, and a build that reads it has
/// everything. Foundation only, so it is checked off a Mac.
enum UnreadableState {
    /// The start of a kept copy's name; the rest says when it was kept.
    static let prefix = "state.unreadable-"

    /// `state.unreadable-20261108-143005.json`, in this Mac's time, with `-2`,
    /// `-3`… after the time for a later one in the same second.
    static func name(at date: Date, attempt: Int = 1) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: date)
        return attempt <= 1 ? "\(prefix)\(stamp).json" : "\(prefix)\(stamp)-\(attempt).json"
    }

    /// Moves `file` to a name of its own in the same folder, never over another
    /// copy, and returns where it went. Nil when there is no file, or it could
    /// not be moved — in which case it is where it was.
    @discardableResult
    static func keep(_ file: URL, at date: Date = Date()) -> URL? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: file.path) else { return nil }
        let folder = file.deletingLastPathComponent()
        for attempt in 1...100 {
            let target = folder.appendingPathComponent(name(at: date, attempt: attempt))
            guard !manager.fileExists(atPath: target.path) else { continue }
            do {
                try manager.moveItem(at: file, to: target)
                return target
            } catch {
                // Taken between the look and the move: try the next name.
                if manager.fileExists(atPath: target.path) { continue }
                return nil
            }
        }
        return nil
    }

    /// Whether a copy is kept in `folder`.
    static func isKept(in folder: URL) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.contains { $0.hasPrefix(prefix) }
    }
}
