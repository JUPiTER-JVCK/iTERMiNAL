import Foundation

/// What a person agrees to when they start a crawl.
///
/// Every limit has a ceiling that no setting or edited preference gets past:
/// a crawl is requests to somebody else's server, and "up to 200 pages, one at
/// a time, half a second apart" is as much as this app will ask of one on
/// behalf of a button.
struct CrawlLimits: Equatable {
    /// Pages in all, the one already in hand included.
    var maxPages = 25
    /// Links followed from the start: 1 is the pages it links to, 2 the pages
    /// those link to.
    var maxDepth = 2
    /// Seconds between one request and the next.
    var delay: TimeInterval = 1
    /// Only addresses whose path starts with this (`/docs/`), or the whole site.
    var stayUnder: String?

    static let pageChoices = [10, 25, 50, 100, 200]
    static let depthChoices = [1, 2, 3, 4]
    static let delayChoices: [TimeInterval] = [0.5, 1, 2, 5]
    static let hardMaxPages = 200
    static let hardMaxDepth = 4
    static let minDelay: TimeInterval = 0.5
    static let maxDelay: TimeInterval = 60
    /// The most of a site's own `Crawl-delay` that is waited out.
    static let longestSiteDelay: TimeInterval = 30

    /// These limits, brought inside the ceilings.
    func clamped() -> CrawlLimits {
        var scope = stayUnder?.trimmingCharacters(in: .whitespaces)
        if let value = scope {
            if value.isEmpty || value == "/" {
                scope = nil
            } else if !value.hasPrefix("/") {
                scope = "/" + value
            }
        }
        return CrawlLimits(
            maxPages: min(max(maxPages, 1), Self.hardMaxPages),
            maxDepth: min(max(maxDepth, 1), Self.hardMaxDepth),
            delay: delay.isFinite ? min(max(delay, Self.minDelay), Self.maxDelay) : 1,
            stayUnder: scope
        )
    }

    /// How long to wait before each request: what was chosen, or what the site
    /// asks for in its robots.txt if that is longer (up to a point).
    func wait(siteDelay: TimeInterval?) -> TimeInterval {
        let own = clamped().delay
        guard let siteDelay, siteDelay.isFinite else { return own }
        return max(own, min(siteDelay, Self.longestSiteDelay))
    }
}

/// The pages a crawl has yet to fetch, and the rules for what goes on the list.
///
/// A crawl follows links the pages it reads *declare*, and nothing else: it
/// guesses no address, and an address is queued only if it is on the same site
/// as the start (the same scheme, host and port, exactly — `www.` is another
/// host), inside the scope, a plausible web page by its ending, not seen
/// already, and no deeper than the limit. The first in is the first out, so
/// pages nearest the start come first.
struct CrawlFrontier {
    struct Entry: Equatable {
        var url: String
        var depth: Int
        /// The page whose link led here.
        var foundOn: String
    }

    /// Addresses remembered before the list stops growing, so a site with an
    /// endless calendar cannot fill memory while the page limit is far off.
    static let maxDiscovered = 5_000

    let limits: CrawlLimits
    let start: String
    private let scheme: String
    private let host: String
    private let port: Int
    private var queue: [Entry] = []
    private var head = 0
    private var seen: Set<String> = []
    /// Pages fetched or in hand: the start page is the first.
    private(set) var handedOut = 1

    /// Nil unless `start` is an address a crawl can begin from.
    init?(start rawStart: String, limits: CrawlLimits) {
        guard let normalized = Self.normalize(rawStart), let parts = URLComponents(string: normalized),
              let scheme = parts.scheme, let host = parts.host else { return nil }
        self.limits = limits.clamped()
        self.start = normalized
        self.scheme = scheme
        self.host = host
        self.port = Self.effectivePort(parts)
        seen.insert(normalized)
    }

    var pendingCount: Int { queue.count - head }

    /// Pages that may still be fetched under the page limit.
    var budgetLeft: Int { max(0, limits.maxPages - handedOut) }

    /// Queues the addresses a page at `depth` linked to, at the depth below it.
    mutating func offer(_ addresses: [String], foundOn: String, depth: Int) {
        let childDepth = depth + 1
        guard childDepth <= limits.maxDepth else { return }
        for address in addresses {
            guard seen.count < Self.maxDiscovered else { return }
            guard let normalized = Self.normalize(address), accepts(normalized), !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            queue.append(Entry(url: normalized, depth: childDepth, foundOn: foundOn))
        }
    }

    /// The next address to fetch, if there is one and the page limit allows.
    mutating func next() -> Entry? {
        guard handedOut < limits.maxPages, head < queue.count else { return nil }
        let entry = queue[head]
        head += 1
        handedOut += 1
        return entry
    }

    /// Puts back the page `next()` counted, because it was not fetched after all
    /// (robots.txt asks that it isn't).
    mutating func refund() {
        handedOut = max(1, handedOut - 1)
    }

    /// Remembers an address that was reached by another route — where a redirect
    /// ended up — so it is not fetched a second time.
    mutating func markSeen(_ address: String) {
        if let normalized = Self.normalize(address) { seen.insert(normalized) }
    }

    func hasSeen(_ address: String) -> Bool {
        Self.normalize(address).map { seen.contains($0) } ?? false
    }

    /// Whether `normalized` is on the site being crawled, inside the scope, and
    /// looks like a web page.
    func accepts(_ normalized: String) -> Bool {
        guard let parts = URLComponents(string: normalized),
              parts.scheme == scheme, parts.host == host, Self.effectivePort(parts) == port else { return false }
        let path = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
        if let scope = limits.stayUnder, !path.hasPrefix(scope) { return false }
        return Self.looksLikePage(path: path)
    }

    // MARK: Addresses

    /// One spelling of an address for comparing: the scheme and host in lower
    /// case, no fragment, no default port, `/` for an empty path. Nil for
    /// anything that isn't http or https, carries a user name or password, or is
    /// absurdly long.
    static func normalize(_ address: String) -> String? {
        guard address.utf8.count <= 2_000, var parts = URLComponents(string: address),
              let scheme = parts.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        parts.scheme = scheme
        parts.host = host
        parts.fragment = nil
        if (scheme == "http" && parts.port == 80) || (scheme == "https" && parts.port == 443) { parts.port = nil }
        if parts.path.isEmpty { parts.path = "/" }
        return parts.string
    }

    private static func effectivePort(_ parts: URLComponents) -> Int {
        parts.port ?? (parts.scheme?.lowercased() == "https" ? 443 : 80)
    }

    /// The folder a crawl "stays under" when asked to stay in the start page's
    /// section: `/blog/post` is `/blog/`, `/docs/` is `/docs/`, `/` is the site.
    static func directory(of address: String) -> String {
        guard let parts = URLComponents(string: address) else { return "/" }
        let path = parts.percentEncodedPath
        guard let slash = path.lastIndex(of: "/") else { return "/" }
        return String(path[...slash])
    }

    /// Endings that name something other than a page. Fetching these would
    /// download a file to throw it away; the page that linked to them has them
    /// in its Files and Images lists already.
    static let nonPageEndings: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "svg", "ico", "bmp", "tif", "tiff", "avif", "heic",
        "pdf", "zip", "gz", "tgz", "tar", "bz2", "xz", "7z", "rar", "dmg", "pkg", "exe", "msi", "apk", "iso",
        "mp3", "mp4", "m4a", "m4v", "mov", "avi", "mkv", "webm", "ogg", "wav", "flac",
        "css", "js", "mjs", "map", "json", "xml", "rss", "atom", "txt", "csv", "tsv",
        "woff", "woff2", "ttf", "otf", "eot",
        "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "epub",
    ]

    static func looksLikePage(path: String) -> Bool {
        guard let last = path.split(separator: "/", omittingEmptySubsequences: true).last,
              let dot = last.lastIndex(of: "."), dot != last.startIndex else { return true }
        return !nonPageEndings.contains(last[last.index(after: dot)...].lowercased())
    }
}

/// What the crawl sends and takes, apart from the limits a person chooses.
enum CrawlPolicy {
    /// The name robots.txt files know this crawler by.
    static let agentToken = "iTERMiNAL"
    /// The most of one page that is read. A page is markup; a megabyte or two
    /// is a long one, and more is not worth waiting for.
    static let maxPageBytes = 2_000_000
    /// The most of a robots.txt that is read.
    static let maxRobotsBytes = RobotsRules.maxBytes
    /// Rows of the pages table kept for addresses the crawl was asked not to
    /// fetch; past this they are only counted.
    static let maxSkippedRows = 100

    /// `User-Agent` for a crawl: the product, its version and where to read
    /// about it, so a site's owner can see who is asking.
    static func userAgent(version: String) -> String {
        "\(agentToken)/\(version) (+https://github.com/JUPiTER-JVCK/iTERMiNAL)"
    }

    /// The `Accept` header: pages, and nothing else by preference.
    static let accept = "text/html,application/xhtml+xml;q=0.9,*/*;q=0.1"

    /// Whether a response of this declared type is read as a page. No type is
    /// let through; the markup parser takes whatever it is given.
    static func isPage(contentType: String?) -> Bool {
        guard let declared = contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased(),
              !declared.isEmpty else { return true }
        return declared == "text/html" || declared == "application/xhtml+xml"
    }

    /// Why robots.txt, from what the site answered, means no crawl can begin;
    /// nil if it can. RFC 9309: a file that is there is read, one that is not
    /// (any 4xx) asks nothing, and a server that could not answer is a reason
    /// to ask nothing of it.
    static func robotsProblem(status: Int) -> String? {
        switch status {
        case 200..<300, 400..<500: return nil
        case 300..<400: return "robots.txt is somewhere else (\(status)), outside this site"
        default: return "the server answered \(status) for robots.txt"
        }
    }
}
