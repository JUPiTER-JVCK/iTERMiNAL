import Foundation

/// The one site a map is of: scheme, host and port, compared exactly.
///
/// "Exactly" is the point. `www.example.com` is not `example.com`, and
/// `http://` is not `https://` — folding them would be a guess about who
/// owns what. A page that points elsewhere is simply not part of this map.
struct SiteOrigin: Equatable, Hashable {
    let scheme: String
    let host: String
    let port: Int

    /// Nil for anything that isn't an http(s) URL with a host.
    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = url.port ?? (scheme == "https" ? 443 : 80)
    }

    init?(urlString: String) {
        guard let url = URL(string: urlString) else { return nil }
        self.init(url: url)
    }

    /// `https://example.com`, with the port only when it isn't the default.
    var root: String {
        let isDefault = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        let hostPart = host.contains(":") ? "[\(host)]" : host  // an IPv6 literal
        return "\(scheme)://\(hostPart)" + (isDefault ? "" : ":\(port)")
    }

    /// `example.com`, for a prompt.
    var display: String {
        let isDefault = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        return host + (isDefault ? "" : ":\(port)")
    }

    func contains(_ url: URL) -> Bool {
        SiteOrigin(url: url) == self
    }
}

/// How a path came to be on the map. A path can have several: listed in a
/// sitemap and also linked from a page.
struct SiteProvenance: OptionSet, Equatable, Hashable {
    let rawValue: Int
    /// Listed in a sitemap the site's robots.txt pointed at.
    static let sitemap = SiteProvenance(rawValue: 1)
    /// Named by an `Allow:` line in robots.txt.
    static let robotsAllow = SiteProvenance(rawValue: 2)
    /// Named by a `Disallow:` line in robots.txt.
    static let robotsDisallow = SiteProvenance(rawValue: 4)
    /// Linked from a page that was fetched, or fetched itself.
    static let discovered = SiteProvenance(rawValue: 8)

    /// Four columns — `S`itemap, `A`llow, `D`isallow, `L`ink — with `-` for
    /// each that doesn't apply, for `ls -l`.
    var flags: String {
        (contains(.sitemap) ? "S" : "-")
            + (contains(.robotsAllow) ? "A" : "-")
            + (contains(.robotsDisallow) ? "D" : "-")
            + (contains(.discovered) ? "L" : "-")
    }
}

/// One line of an `ls`.
struct SiteEntry: Equatable {
    /// How the name is shown: percent-decoded when that is safe to print.
    let name: String
    /// The segment as it appears in a URL, which is what `cd` and `get` act on.
    let rawName: String
    let isDirectory: Bool
    let provenance: SiteProvenance
    let childCount: Int
    /// How many `?query` variants of this path were seen. They are counted
    /// here rather than given a node each.
    let queryVariants: Int
}

/// The paths a site has declared or linked to, as a tree by path segment —
/// what `ls`, `cd` and `tree` walk.
///
/// A map of *what is known*. Nothing here asks a server anything, and nothing
/// is ever added that was not read from the site's own robots.txt, one of its
/// sitemaps, or a page the user fetched.
struct SitePathTree {
    let origin: SiteOrigin

    private struct Node {
        var children: [String: Node] = [:]
        var provenance: SiteProvenance = []
        /// Written with a trailing slash somewhere, so a directory even when
        /// nothing under it is known.
        var directoryHint = false
        var queryVariants = 0
    }

    private var root = Node()

    /// Paths that carry a provenance of their own, not counting directories
    /// that exist only because a deeper path passes through them.
    private(set) var declaredCount = 0
    /// Entries refused because they named another origin. Reported, so a
    /// sitemap that lists the wrong host reads as that rather than as empty.
    private(set) var foreignCount = 0
    private(set) var invalidCount = 0
    /// A sample of the first few foreign entries, for the report.
    private(set) var foreignSamples: [String] = []

    /// Longest path, in segments, that is stored. Deeper is not a real
    /// site; it is an attempt to make the tree deep.
    static let maxDepth = 64
    static let maxPathLength = 2_048

    init(origin: SiteOrigin) {
        self.origin = origin
    }

    enum InsertResult: Equatable {
        case added, merged, foreign, invalid
    }

    // MARK: Insert

    /// Adds a full URL. Only one on this tree's own origin is accepted.
    @discardableResult
    mutating func insert(url: String, provenance: SiteProvenance) -> InsertResult {
        guard let parsed = URL(string: url), let candidate = SiteOrigin(url: parsed) else {
            invalidCount += 1
            return .invalid
        }
        guard candidate == origin else {
            foreignCount += 1
            if foreignSamples.count < 3 { foreignSamples.append(url) }
            return .foreign
        }
        guard let components = URLComponents(url: parsed, resolvingAgainstBaseURL: false) else {
            invalidCount += 1
            return .invalid
        }
        // `percentEncodedPath` so segments stay as the URL wrote them.
        let hasQuery = !(components.percentEncodedQuery ?? "").isEmpty
        return insertPath(components.percentEncodedPath, provenance: provenance, hasQuery: hasQuery)
    }

    /// Adds a path from robots.txt (`/admin/`, `/private/file.txt`).
    @discardableResult
    mutating func insert(path: String, provenance: SiteProvenance) -> InsertResult {
        insertPath(path, provenance: provenance, hasQuery: false)
    }

    private mutating func insertPath(_ path: String, provenance: SiteProvenance, hasQuery: Bool) -> InsertResult {
        guard path.count <= Self.maxPathLength, path.hasPrefix("/") || path.isEmpty,
              let segments = Self.cleanSegments(path), segments.count <= Self.maxDepth else {
            invalidCount += 1
            return .invalid
        }
        let isDirectory = path.hasSuffix("/") && !segments.isEmpty
        var wasNew = false
        Self.insert(
            into: &root,
            segments: segments[...],
            provenance: provenance,
            directoryHint: isDirectory,
            hasQuery: hasQuery,
            wasNew: &wasNew
        )
        if wasNew { declaredCount += 1 }
        return wasNew ? .added : .merged
    }

    private static func insert(
        into node: inout Node,
        segments: ArraySlice<String>,
        provenance: SiteProvenance,
        directoryHint: Bool,
        hasQuery: Bool,
        wasNew: inout Bool
    ) {
        guard let first = segments.first else {
            wasNew = node.provenance.isEmpty
            node.provenance.formUnion(provenance)
            if directoryHint { node.directoryHint = true }
            if hasQuery { node.queryVariants += 1 }
            return
        }
        insert(
            into: &node.children[first, default: Node()],
            segments: segments.dropFirst(),
            provenance: provenance,
            directoryHint: directoryHint,
            hasQuery: hasQuery,
            wasNew: &wasNew
        )
    }

    /// Splits a path into its segments, dropping empty ones (`//`) and `.`,
    /// and resolving `..` — so `/a/../b` is `/b`, and a map can't be given a
    /// path that reads one way and means another. Nil when `..` climbs out of
    /// the root, which is not a path on this site.
    static func cleanSegments(_ path: String) -> [String]? {
        var result: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..":
                guard !result.isEmpty else { return nil }
                result.removeLast()
            default:
                result.append(String(part))
            }
        }
        return result
    }

    // MARK: Read

    /// Whether `segments` names a node on the map, implied directories included.
    func contains(_ segments: [String]) -> Bool {
        node(at: segments) != nil
    }

    /// Whether `segments` is a directory: it has children, or was written as one.
    func isDirectory(_ segments: [String]) -> Bool {
        guard let node = node(at: segments) else { return false }
        return !node.children.isEmpty || node.directoryHint
    }

    func provenance(of segments: [String]) -> SiteProvenance? {
        node(at: segments)?.provenance
    }

    /// The entries directly under `segments`, directories first and then by
    /// name. Nil when there is no such path.
    func entries(at segments: [String]) -> [SiteEntry]? {
        guard let parent = node(at: segments) else { return nil }
        return Self.sortedEntries(of: parent)
    }

    /// How many paths came from each source.
    func counts() -> (sitemap: Int, robots: Int, discovered: Int) {
        var sitemap = 0, robots = 0, discovered = 0
        func visit(_ node: Node) {
            if node.provenance.contains(.sitemap) { sitemap += 1 }
            if !node.provenance.isDisjoint(with: [.robotsAllow, .robotsDisallow]) { robots += 1 }
            if node.provenance.contains(.discovered) { discovered += 1 }
            node.children.values.forEach(visit)
        }
        visit(root)
        return (sitemap, robots, discovered)
    }

    /// Every known path whose displayed text contains `needle`, as
    /// `/a/b/c` strings, sorted, up to `limit`.
    func paths(containing needle: String, limit: Int) -> [String] {
        let lowered = needle.lowercased()
        var found: [String] = []
        func visit(_ node: Node, trail: [String]) {
            guard found.count < limit else { return }
            for rawName in node.children.keys.sorted() {
                guard found.count < limit, let child = node.children[rawName] else { break }
                let next = trail + [rawName]
                let text = "/" + next.map(Self.displayName).joined(separator: "/")
                if !child.provenance.isEmpty, text.lowercased().contains(lowered) {
                    found.append(text + (child.children.isEmpty && !child.directoryHint ? "" : "/"))
                }
                visit(child, trail: next)
            }
        }
        visit(root, trail: [])
        return found
    }

    /// Every entry under `segments` down to `maxDepth`, depth-first in the
    /// order `ls` lists them, for `tree`. `visit` returns false to stop —
    /// the caller caps how much it prints, and the walk stops with it.
    func walk(from segments: [String], maxDepth: Int, _ visit: (_ depth: Int, _ entry: SiteEntry) -> Bool) {
        guard let start = node(at: segments) else { return }
        func recurse(_ node: Node, depth: Int) -> Bool {
            guard depth <= maxDepth else { return true }
            for entry in SitePathTree.sortedEntries(of: node) {
                guard visit(depth, entry) else { return false }
                if let child = node.children[entry.rawName], !child.children.isEmpty {
                    if !recurse(child, depth: depth + 1) { return false }
                }
            }
            return true
        }
        _ = recurse(start, depth: 1)
    }

    private static func sortedEntries(of node: Node) -> [SiteEntry] {
        node.children.map { rawName, child in
            SiteEntry(
                name: displayName(rawName),
                rawName: rawName,
                isDirectory: !child.children.isEmpty || child.directoryHint,
                provenance: child.provenance,
                childCount: child.children.count,
                queryVariants: child.queryVariants
            )
        }.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            return order == .orderedSame ? lhs.rawName < rhs.rawName : order == .orderedAscending
        }
    }

    private func node(at segments: [String]) -> Node? {
        var current = root
        for segment in segments {
            guard let next = current.children[segment] else { return nil }
            current = next
        }
        return current
    }

    // MARK: Names

    /// A segment as it should be shown: percent-decoded, unless that would
    /// put something in the listing that isn't a plain name — a newline that
    /// splits a line in two, or a bidirectional override that makes
    /// `evil‮txt.exe` read as `evilexe.txt`.
    static func displayName(_ rawName: String) -> String {
        guard rawName.contains("%"), let decoded = rawName.removingPercentEncoding else { return rawName }
        return isPlainText(decoded) ? decoded : rawName
    }

    static func isPlainText(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) { return false }
            switch scalar.value {
            case 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x2069, 0xFEFF:
                return false
            default:
                continue
            }
        }
        return true
    }

    /// The raw segment on the map that `input` means under `parent`: the
    /// segment itself, or the one that decodes to it. Nil when none does.
    func rawSegment(matching input: String, under parent: [String]) -> String? {
        guard let node = node(at: parent) else { return nil }
        if node.children[input] != nil { return input }
        return node.children.keys.sorted().first { Self.displayName($0) == input }
    }

    // MARK: Paths and URLs

    /// A path typed at the prompt, resolved against the current directory:
    /// `..`, `.`, absolute, `~` and relative forms. Each segment is mapped to
    /// the raw one on the map when it names one, and percent-encoded
    /// otherwise — so `cd "my docs"` finds `my%20docs`, and `get "a b"` sends
    /// `a%20b`. `..` at the root stays at the root, as in a shell.
    func resolve(_ input: String, from current: [String]) -> [String] {
        var result: [String] = input.hasPrefix("/") || input.hasPrefix("~") ? [] : current
        let body = input.hasPrefix("~") ? String(input.dropFirst()) : input
        for part in body.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..":
                if !result.isEmpty { result.removeLast() }
            default:
                let text = String(part)
                if let raw = rawSegment(matching: text, under: result) {
                    result.append(raw)
                } else {
                    result.append(Self.encodeSegment(text))
                }
            }
        }
        return result
    }

    /// Percent-encodes one path segment typed by a person. A `%` that is
    /// already followed by two hex digits is taken as an escape and left
    /// alone, rather than encoded a second time.
    static func encodeSegment(_ text: String) -> String {
        encode(text, allowed: segmentAllowed)
    }

    /// The same for a query string typed by a person.
    static func encodeQuery(_ text: String) -> String {
        encode(text, allowed: .urlQueryAllowed)
    }

    private static func encode(_ text: String, allowed: CharacterSet) -> String {
        var out = ""
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "%", index + 2 < scalars.count,
               isHex(scalars[index + 1]), isHex(scalars[index + 2]) {
                out.unicodeScalars.append(contentsOf: scalars[index...(index + 2)])
                index += 3
            } else {
                out += String(scalar).addingPercentEncoding(withAllowedCharacters: allowed) ?? String(scalar)
                index += 1
            }
        }
        return out
    }

    private static let segmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove("/")
        return set
    }()

    private static func isHex(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "0"..."9", "a"..."f", "A"..."F": return true
        default: return false
        }
    }

    /// `https://example.com/a/b` (with a trailing slash for a directory).
    func url(for segments: [String], query: String? = nil, asDirectory: Bool? = nil) -> String {
        let directory = asDirectory ?? isDirectory(segments)
        var text = origin.root + "/" + segments.joined(separator: "/")
        if directory && !segments.isEmpty { text += "/" }
        if let query, !query.isEmpty { text += "?" + query }
        return text
    }

    /// The path as shown at a prompt: `/`, `/blog`, `/blog/2024`.
    static func display(_ segments: [String]) -> String {
        "/" + segments.map(displayName).joined(separator: "/")
    }
}
