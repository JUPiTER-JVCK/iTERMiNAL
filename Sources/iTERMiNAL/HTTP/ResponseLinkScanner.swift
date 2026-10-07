import Foundation

/// Pulls links out of a response body the user already fetched.
///
/// This is enrichment of data in hand, not a network action: it reads bytes
/// that are already here and returns addresses as text. Nothing is requested
/// from here, and what is returned is only ever a candidate for the site map
/// — the map decides which belong to the site being explored.
///
/// Best effort, and deliberately not a real HTML parser: it reads `href` and
/// `src` attributes with a pattern. It misses links a script builds, can
/// misread broken markup, and ignores `<base>`. Those are the right
/// trade-offs for a map that says which of its entries were found this way.
enum ResponseLinkScanner {
    /// Links beyond this many in one body are dropped. A page with more is
    /// generated noise, and an unbounded list is an unbounded cost.
    static let maxLinks = 5_000

    /// Only the first part of a body is read. The cap is on work, not on
    /// what is reported: a page's navigation is near its top.
    static let maxScannedBytes = 2_000_000

    /// Absolute `http(s)` URLs found in `body`, resolved against `baseURL`,
    /// fragments removed, without repeats, in order of appearance.
    static func links(in body: Data, contentKind: HTTPContentKind, baseURL: String) -> [String] {
        guard let base = URL(string: baseURL) else { return [] }
        let sample = body.count > maxScannedBytes ? body.prefix(maxScannedBytes) : body
        switch contentKind {
        case .html:
            return htmlLinks(String(decoding: sample, as: UTF8.self), base: base)
        case .json:
            return jsonLinks(Data(sample), base: base)
        default:
            return []
        }
    }

    // MARK: HTML

    // `href`/`src`, quoted either way or bare. Case-insensitive; the value
    // is whichever of the three groups matched.
    private static let attributePattern = try! NSRegularExpression(
        pattern: #"(?:href|src)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>"']+))"#,
        options: [.caseInsensitive]
    )

    private static func htmlLinks(_ html: String, base: URL) -> [String] {
        let ns = html as NSString
        var collector = Collector(limit: maxLinks)
        attributePattern.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { match, _, stop in
            guard let match else { return }
            for group in 1...3 where match.range(at: group).location != NSNotFound {
                let raw = ns.substring(with: match.range(at: group))
                collector.add(resolve(decodeEntities(raw), against: base))
                break
            }
            if collector.isFull { stop.pointee = true }
        }
        return collector.links
    }

    /// The handful of entities an attribute value realistically carries.
    /// `&amp;` is the one that matters: `?a=1&amp;b=2` is how a query string
    /// is written in markup.
    private static func decodeEntities(_ value: String) -> String {
        guard value.contains("&") else { return value }
        return value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: JSON

    /// Keys under which a root-relative string (`"/v1/items"`) is read as a
    /// link. Anywhere else such a string is as likely a file path or a
    /// label as an address, so only absolute URLs are taken there.
    private static let linkKeys: Set<String> = [
        "url", "uri", "href", "link", "links", "next", "prev", "previous",
        "self", "first", "last", "related", "canonical", "location",
    ]

    private static func jsonLinks(_ data: Data, base: URL) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return []
        }
        var collector = Collector(limit: maxLinks)
        walk(root, key: nil, base: base, into: &collector, depth: 0)
        return collector.links
    }

    private static func walk(_ node: Any, key: String?, base: URL, into collector: inout Collector, depth: Int) {
        // A hostile document can nest arbitrarily; stop well short of the
        // stack.
        guard depth < 64, !collector.isFull else { return }
        switch node {
        case let dict as [String: Any]:
            // Sorted, so the same document always yields the same order.
            for name in dict.keys.sorted() {
                walk(dict[name]!, key: name.lowercased(), base: base, into: &collector, depth: depth + 1)
            }
        case let array as [Any]:
            for item in array { walk(item, key: key, base: base, into: &collector, depth: depth + 1) }
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
                collector.add(resolve(trimmed, against: base))
            } else if trimmed.hasPrefix("/"), !trimmed.hasPrefix("//"), let key, linkKeys.contains(key) {
                collector.add(resolve(trimmed, against: base))
            }
        default:
            break
        }
    }

    // MARK: Shared

    private struct Collector {
        let limit: Int
        private(set) var links: [String] = []
        private var seen = Set<String>()
        var isFull: Bool { links.count >= limit }

        init(limit: Int) { self.limit = limit }

        mutating func add(_ link: String?) {
            guard let link, !isFull, seen.insert(link).inserted else { return }
            links.append(link)
        }
    }

    /// `value` as an absolute http(s) URL with no fragment, or nil for
    /// anything else — `mailto:`, `javascript:`, `data:`, a bare `#anchor`.
    private static func resolve(_ value: String, against base: URL) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let url = URL(string: trimmed, relativeTo: base)?.absoluteURL else { return nil }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        guard url.host?.isEmpty == false else { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        components.fragment = nil
        return components.string
    }
}
