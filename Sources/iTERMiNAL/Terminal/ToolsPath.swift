import Foundation

/// Adding the bundled command-line tools' folder to a shell's `PATH`. Foundation
/// only, so what it will and will not do is checked off a Mac.
enum ToolsPath {
    /// `path` with `directory` added at the *end*, so anything the person has
    /// installed — their own `rg`, a newer `bat` — is found first and the bundled
    /// copy is only what is there when nothing else is.
    ///
    /// Returns `path` as it was when there is nothing to add or nothing safe to
    /// add it to, and nil only when `path` is nil or empty: an environment with
    /// no `PATH` gets none from here, because a `PATH` of one folder would be
    /// worse than none — the shell falls back to its own default only when the
    /// variable is missing.
    ///
    /// A folder is not added when:
    /// - it is empty, or has a character that cannot be in one `PATH` entry (a
    ///   colon splits it in two; a newline or NUL ends it);
    /// - it is not absolute, which would depend on the shell's working folder;
    /// - it is already an entry, with or without a trailing slash.
    static func appending(_ directory: String?, to path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        guard let directory, !directory.isEmpty,
              directory.hasPrefix("/"),
              !directory.contains(":"), !directory.contains("\n"), !directory.contains("\0") else {
            return path
        }
        func trimmed(_ entry: String) -> String {
            var entry = entry
            while entry.count > 1, entry.hasSuffix("/") { entry.removeLast() }
            return entry
        }
        let wanted = trimmed(directory)
        if path.split(separator: ":", omittingEmptySubsequences: false).contains(where: { trimmed(String($0)) == wanted }) {
            return path
        }
        return path + ":" + directory
    }
}
