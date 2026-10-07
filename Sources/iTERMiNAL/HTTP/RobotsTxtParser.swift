import Foundation

/// What a site's own `robots.txt` says about itself: the paths it names and
/// the sitemaps it points at.
///
/// This is read as a *declaration*, not as crawl rules. A real crawler obeys
/// the one group that matches its user-agent; this parser flattens every
/// group, because the site explorer is harvesting what the operator wrote
/// down — and a `Disallow: /admin/` line is the operator saying that `/admin/`
/// exists, in a file published for anyone to read.
struct RobotsTxt: Equatable {
    /// Paths from `Allow:` lines, as written, in file order, without repeats.
    var allowed: [String] = []
    /// Paths from `Disallow:` lines.
    var disallowed: [String] = []
    /// `Sitemap:` values, as written. Not yet checked for which host they
    /// name — `ExplorerPolicy` decides which of them may be fetched.
    var sitemaps: [String] = []
    /// Path lines left out because they were patterns (`*`, `$`) rather than
    /// paths. They say "everything matching this", which names nothing.
    var patternsSkipped = 0
}

enum RobotsTxtParser {
    /// A line-by-line read. Directive names are case-insensitive, `#` starts
    /// a comment, anything unrecognised is ignored, and nothing here throws:
    /// a robots.txt that is HTML, binary, or nonsense simply yields an empty
    /// result.
    static func parse(_ text: String) -> RobotsTxt {
        var result = RobotsTxt()
        var seenAllow = Set<String>()
        var seenDisallow = Set<String>()
        var seenSitemaps = Set<String>()

        // `components(separatedBy:)` on newlines, not `.lines`: a file with
        // bare `\r` endings (it happens) should still split.
        for rawLine in text.components(separatedBy: CharacterSet.newlines) {
            var line = rawLine
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }
            line = line.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }

            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }  // `Disallow:` alone means "nothing"

            switch name {
            case "allow", "disallow":
                guard let path = concretePath(value) else {
                    // Only a pattern is worth counting: a value that is just
                    // not a path (no leading slash) is noise, not a skipped
                    // declaration.
                    if value.hasPrefix("/") || value.hasPrefix("*") { result.patternsSkipped += 1 }
                    continue
                }
                if name == "allow", seenAllow.insert(path).inserted {
                    result.allowed.append(path)
                } else if name == "disallow", seenDisallow.insert(path).inserted {
                    result.disallowed.append(path)
                }
            case "sitemap":
                if seenSitemaps.insert(value).inserted { result.sitemaps.append(value) }
            default:
                continue
            }
        }
        return result
    }

    /// The path part of a rule, or nil when the rule is a pattern or isn't a
    /// path. A query on a path is dropped: `Disallow: /search?q=` names
    /// `/search`.
    private static func concretePath(_ value: String) -> String? {
        guard value.hasPrefix("/") else { return nil }
        guard !value.contains("*"), !value.contains("$") else { return nil }
        var path = value
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        if let fragment = path.firstIndex(of: "#") { path = String(path[..<fragment]) }
        return path.isEmpty ? nil : path
    }
}
