import Foundation

/// What a site's robots.txt asks of one crawler, read the way RFC 9309 says to.
///
/// The site explorer reads robots.txt to find what a site *declares*, so
/// `RobotsTxtParser` takes every path in every group. A crawler needs the
/// opposite reading: it fetches pages, so it needs to know which of them the
/// site has asked *it* not to fetch — only the group that names it (or, failing
/// that, the one for everyone), and for any one address the most specific rule
/// that matches.
struct RobotsRules: Equatable {
    struct Rule: Equatable {
        var allow: Bool
        var pattern: String
    }

    var rules: [Rule]
    /// The seconds between requests the site asks for (`Crawl-delay`). RFC 9309
    /// doesn't define it, but many sites send it and asking is what it is for.
    var crawlDelay: TimeInterval?

    /// A site with no robots.txt asks nothing.
    static let allowAll = RobotsRules(rules: [], crawlDelay: nil)

    /// Only this much of the file is read, which is the most RFC 9309 asks a
    /// crawler to.
    static let maxBytes = 512 * 1024

    // MARK: Reading

    /// The rules in `text` for a crawler whose product token is `agent`
    /// (`iTERMiNAL`, not its whole `User-Agent` line). Anything that isn't a
    /// rule is ignored; a file that is not robots.txt at all asks nothing.
    static func parse(_ text: String, agent: String) -> RobotsRules {
        struct Group {
            var agents: [String] = []
            var rules: [Rule] = []
            var delay: TimeInterval?
        }

        var source = text
        if source.utf8.count > maxBytes {
            source = String(decoding: Array(source.utf8.prefix(maxBytes)), as: UTF8.self)
        }
        if source.hasPrefix("\u{FEFF}") { source.removeFirst() }

        var groups: [Group] = []
        var current: Group?
        // Consecutive `User-agent` lines share the rules that follow them; a
        // rule closes the list, and the next `User-agent` starts another group.
        var listingAgents = false

        for rawLine in source.components(separatedBy: .newlines) {
            var line = Substring(rawLine)
            if let hash = line.firstIndex(of: "#") { line = line[..<hash] }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let field = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)

            switch field {
            case "user-agent":
                if !listingAgents {
                    if let finished = current { groups.append(finished) }
                    current = Group()
                }
                current?.agents.append(value.lowercased())
                listingAgents = true
            case "allow", "disallow":
                guard current != nil else { continue }
                listingAgents = false
                // An empty Disallow disallows nothing; an empty Allow says nothing.
                guard !value.isEmpty else { continue }
                current?.rules.append(Rule(allow: field == "allow", pattern: value))
            case "crawl-delay":
                guard current != nil else { continue }
                listingAgents = false
                if let seconds = Double(value), seconds.isFinite, seconds >= 0 { current?.delay = seconds }
            default:
                break
            }
        }
        if let finished = current { groups.append(finished) }

        // The group that names this crawler wins outright; everyone's is the
        // fallback. Groups for the same crawler add up.
        let token = agent.lowercased()
        let named = groups.filter { $0.agents.contains(token) }
        let chosen = named.isEmpty ? groups.filter { $0.agents.contains("*") } : named
        return RobotsRules(
            rules: chosen.flatMap(\.rules),
            crawlDelay: chosen.compactMap(\.delay).max()
        )
    }

    // MARK: Asking

    /// Whether the address with this path (and query, as in a request line:
    /// `/search?q=x`) may be fetched. The longest rule that matches decides, and
    /// where an allow and a disallow match equally the allow wins; nothing
    /// matching means allowed. `/robots.txt` itself is always fetchable.
    func allows(path rawPath: String) -> Bool {
        let path = rawPath.hasPrefix("/") ? rawPath : "/" + rawPath
        if path == "/robots.txt" { return true }
        var best: Rule?
        for rule in rules where Self.matches(pattern: rule.pattern, path: path) {
            guard let held = best else {
                best = rule
                continue
            }
            let length = rule.pattern.utf8.count
            let heldLength = held.pattern.utf8.count
            if length > heldLength || (length == heldLength && rule.allow && !held.allow) { best = rule }
        }
        return best?.allow ?? true
    }

    /// The path and query of `address`, the way a request names them.
    static func requestPath(of address: String) -> String? {
        guard let components = URLComponents(string: address) else { return nil }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        guard let query = components.percentEncodedQuery else { return path }
        return path + "?" + query
    }

    /// `pattern` against `path`: a prefix match in which `*` is any run of
    /// characters and a final `$` ties the pattern to the end of the path.
    static func matches(pattern: String, path: String) -> Bool {
        var wanted = Array(pattern.utf8)
        let target = Array(path.utf8)
        var anchored = false
        if wanted.last == UInt8(ascii: "$") {
            anchored = true
            wanted.removeLast()
        }
        let star = UInt8(ascii: "*")
        var wantedIndex = 0
        var targetIndex = 0
        // Where the last `*` was, and how much of the path it has taken so far,
        // for stepping back when what follows it does not fit.
        var starIndex = -1
        var starTarget = 0

        while targetIndex < target.count {
            if wantedIndex < wanted.count, wanted[wantedIndex] == star {
                starIndex = wantedIndex
                starTarget = targetIndex
                wantedIndex += 1
            } else if wantedIndex < wanted.count, wanted[wantedIndex] == target[targetIndex] {
                wantedIndex += 1
                targetIndex += 1
            } else if wantedIndex == wanted.count, !anchored {
                return true
            } else if starIndex >= 0 {
                starTarget += 1
                targetIndex = starTarget
                wantedIndex = starIndex + 1
            } else {
                return false
            }
        }
        while wantedIndex < wanted.count, wanted[wantedIndex] == star { wantedIndex += 1 }
        return wantedIndex == wanted.count
    }
}
