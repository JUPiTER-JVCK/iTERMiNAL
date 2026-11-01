import Foundation

/// Which folders to open when something outside the window asks iTERMiNAL to
/// open some: a folder dropped on the Dock icon, Open With in Finder, the
/// Services menu, `open -a iTERMiNAL <path>`.
///
/// Foundation only, and it never looks at the disk itself — what a path is on
/// disk is passed in — so the rules are checked off a Mac.
enum OpenFolders {
    /// The most tabs one request opens. A tab is a shell, which is a process:
    /// selecting a few hundred files in Finder and choosing the service should
    /// not start a few hundred of them.
    static let limit = 8

    /// The most lines of text read for paths.
    static let maxLines = 50

    /// What a path is on disk.
    enum Kind: Equatable {
        case folder
        case file
        case missing
    }

    struct Plan: Equatable {
        /// The folders to open, in the order they were asked for, each once.
        var folders: [String]
        /// Folders that were asked for and left out because of `limit`.
        var leftOut: Int
    }

    /// The folders to open for `paths`.
    ///
    /// A folder opens as itself and a file opens the folder it is in, which is
    /// what the file browser already does. A path that is not absolute, that has
    /// a control character in it, or that is not on disk is ignored. Two paths
    /// that come to the same folder open it once.
    static func plan(for paths: [String], kind: (String) -> Kind) -> Plan {
        var seen = Set<String>()
        var folders: [String] = []
        for raw in paths {
            guard let path = tidy(raw) else { continue }
            let folder: String
            switch kind(path) {
            case .folder: folder = path
            case .file: folder = (path as NSString).deletingLastPathComponent
            case .missing: continue
            }
            if seen.insert(folder).inserted { folders.append(folder) }
        }
        return Plan(folders: Array(folders.prefix(limit)), leftOut: max(0, folders.count - limit))
    }

    /// An absolute path with no control character in it and no trailing slash,
    /// or nil. Nothing is resolved — `.` and `..` stay as written, since what
    /// they mean depends on the disk.
    static func tidy(_ path: String) -> String? {
        guard path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        var trimmed = Substring(path)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }

    /// Paths written out in text, one to a line, as a selection in another app
    /// gives them to a Service. A pair of quotes around a line is taken off, and
    /// a leading `~` stands for `home`. What is not an absolute path afterwards
    /// is left for `plan` to ignore.
    static func paths(inText text: String, home: String) -> [String] {
        var found: [String] = []
        for line in text.components(separatedBy: .newlines).prefix(maxLines) {
            var candidate = line.trimmingCharacters(in: .whitespaces)
            if candidate.count >= 2, let first = candidate.first, first == "\"" || first == "'", candidate.last == first {
                candidate = String(candidate.dropFirst().dropLast())
            }
            if candidate == "~" {
                candidate = home
            } else if candidate.hasPrefix("~/") {
                candidate = home + String(candidate.dropFirst())
            }
            if !candidate.isEmpty { found.append(candidate) }
        }
        return found
    }
}
