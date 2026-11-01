import Foundation

/// The files found under a folder, as paths from it.
struct FileScan: Equatable {
    var root: String
    /// Paths relative to `root`, `/`-separated. Shallower files come first.
    var files: [String]
    /// The scan stopped at `FileSearch.maxFiles`: there are more it did not list.
    var truncated: Bool
}

/// A file the palette found, split for showing.
struct FileHit: Equatable {
    /// Relative to the folder that was scanned.
    var path: String
    var name: String
    /// The folder it is in, relative to the scanned one; empty for the top.
    var folder: String
    var score: Int
}

/// Finding a file by part of its name from the command palette: a bounded walk
/// of the folder the focused terminal is in, and a fuzzy ranking of what it
/// found. Foundation only, so the rules are checked in CI.
///
/// The walk is bounded in every direction — files, depth, and the places it
/// will not go — because it runs on a person's whole project folder, which can
/// hold a million files that are nobody's to search (`node_modules`, a build).
enum FileSearch {
    /// Files listed before the walk stops.
    static let maxFiles = 20_000
    /// How many folders down it goes: the folder it starts in is 0.
    static let maxDepth = 6
    static let maxResults = 20
    /// Fewer characters than this match nearly everything.
    static let minQueryLength = 2

    /// Folders never entered. Generated, vendored or someone else's: a match
    /// inside them is noise nearly every time. A folder whose name starts with
    /// a dot is skipped too (`.git`, `.cache`), though a dotfile is listed.
    static let skippedDirectories: Set<String> = [
        "node_modules", "build", "dist", "target", "Pods", "DerivedData",
        "__pycache__", "venv", "Library", "Carthage", ".build",
    ]

    /// Whether a folder may be searched at all. Not the top of the disk, not
    /// the home folder, and not a folder that holds the home folder: a walk
    /// from there would reach Desktop, Documents and Downloads, and macOS asks
    /// the person to allow each — for a search they asked about one project.
    static func isSearchable(root: String, home: String) -> Bool {
        let folder = (root as NSString).standardizingPath
        let homeFolder = (home as NSString).standardizingPath
        guard folder.hasPrefix("/"), folder != "/" else { return false }
        if folder == homeFolder { return false }
        if homeFolder.hasPrefix(folder + "/") { return false }
        return true
    }

    // MARK: Walking

    /// The files under `root`, breadth first and each folder in name order, so
    /// the files nearest the top are the ones kept when the limit is reached.
    ///
    /// Symbolic links to folders are not followed, so a loop is not a problem;
    /// a link to a file is listed as the file. Sockets, pipes and devices are
    /// not listed, and neither is a name with a control character in it, which
    /// could not be typed into a terminal safely anyway.
    static func scan(root: String, maxFiles: Int = FileSearch.maxFiles, maxDepth: Int = FileSearch.maxDepth) -> FileScan {
        let base = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
        let manager = FileManager.default
        var files: [String] = []
        var truncated = false
        var queue: [(folder: String, depth: Int)] = [("", 0)]
        var head = 0

        walk: while head < queue.count {
            let (folder, depth) = queue[head]
            head += 1
            let absolute = folder.isEmpty ? base : base + "/" + folder
            guard let names = try? manager.contentsOfDirectory(atPath: absolute) else { continue }
            for name in names.sorted() {
                if name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { continue }
                let relative = folder.isEmpty ? name : folder + "/" + name
                let full = absolute + "/" + name
                guard let type = (try? manager.attributesOfItem(atPath: full))?[.type] as? FileAttributeType else { continue }
                switch type {
                case .typeDirectory:
                    if depth < maxDepth, !name.hasPrefix("."), !skippedDirectories.contains(name) {
                        queue.append((relative, depth + 1))
                    }
                case .typeRegular, .typeSymbolicLink:
                    if type == .typeSymbolicLink {
                        var isFolder: ObjCBool = false
                        // A link that goes nowhere, or to a folder, is not a file.
                        guard manager.fileExists(atPath: full, isDirectory: &isFolder), !isFolder.boolValue else { continue }
                    }
                    if files.count >= maxFiles {
                        truncated = true
                        break walk
                    }
                    files.append(relative)
                default:
                    continue
                }
            }
        }
        return FileScan(root: base, files: files, truncated: truncated)
    }

    // MARK: Ranking

    /// A match in the file's name is worth more than one spread over the
    /// folders in front of it.
    private static let nameBonus = 100

    /// The files that match `query`, best first. The query is matched the way
    /// the palette matches everything (every character in order, case aside,
    /// spaces ignored) against the file's name, and failing that against its
    /// whole path; ties go to the shorter path, then to name order.
    static func rank(query: String, in files: [String], limit: Int = FileSearch.maxResults) -> [FileHit] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= minQueryLength, limit > 0 else { return [] }
        let needle = FuzzyMatcher.needle(trimmed)
        guard !needle.isEmpty else { return [] }

        var hits: [FileHit] = []
        for path in files {
            let (folder, name) = split(path)
            let nameCharacters = Array(name)
            var score: Int?
            if let match = FuzzyMatcher.match(
                needle: needle, folded: FuzzyMatcher.folded(name), original: nameCharacters
            ) {
                score = match.score + nameBonus
            } else {
                let characters = Array(path)
                score = FuzzyMatcher.match(
                    needle: needle, folded: FuzzyMatcher.folded(path), original: characters
                )?.score
            }
            if let score {
                hits.append(FileHit(path: path, name: name, folder: folder, score: score))
            }
        }
        hits.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.path.count != $1.path.count { return $0.path.count < $1.path.count }
            return $0.path < $1.path
        }
        return Array(hits.prefix(limit))
    }

    /// A relative path as its folder (empty for the top) and its name.
    static func split(_ path: String) -> (folder: String, name: String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        return (String(path[..<slash]), String(path[path.index(after: slash)...]))
    }

    // MARK: The query

    /// What was typed into the palette, read for files: a leading "/" asks for
    /// files alone, and is not part of what to look for.
    static func parse(_ typed: String) -> (text: String, filesOnly: Bool) {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("/") else { return (trimmed, false) }
        return (String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces), true)
    }

    // MARK: Words

    /// 20000 as "20,000".
    static func thousands(_ number: Int) -> String {
        let digits = String(abs(number))
        var grouped = ""
        for (offset, digit) in digits.reversed().enumerated() {
            if offset > 0, offset % 3 == 0 { grouped.append(",") }
            grouped.append(digit)
        }
        return (number < 0 ? "-" : "") + String(grouped.reversed())
    }

    static var truncationTitle: String {
        "Only the first \(thousands(maxFiles)) files were searched"
    }

    static let truncationSubtitle = "Open the palette from a folder further into the project to search the rest"
}
