import Foundation

/// Turning what a page wrote in an `href`, `src` or `srcset` into an address.
///
/// Everything here is about *reading* what the page declared. Nothing builds an
/// address from a guess, a convention or a list of likely names: an address
/// either appears in the markup, resolved against where the page is, or it does
/// not exist as far as this app is concerned.
enum PageURLs {
    enum Scheme: Equatable {
        case web          // http, https
        case mailto
        case tel
        case other(String)
    }

    struct Resolved: Equatable {
        /// Absolute, with any fragment left on only for a pure in-page link.
        let url: String
        let scheme: Scheme
        /// The part after `#`, when it is the whole point of the link.
        let isAnchor: Bool
    }

    private static let unwritable: CharacterSet = {
        var set = CharacterSet(charactersIn: "<>{}\"\\`^|")
        set.formUnion(.controlCharacters)
        return set
    }()

    /// `value` as the address it names, from a page at `base`.
    ///
    /// Browsers ignore tabs and newlines inside an address and encode a space,
    /// so this does too. `javascript:`, `data:` and `blob:` are not addresses
    /// of anything fetchable and come back nil.
    static func resolve(_ value: String, against base: URL) -> Resolved? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.filter { $0 != "\t" && $0 != "\n" && $0 != "\r" }
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("#") {
            return Resolved(url: base.absoluteString.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init).map { $0 + text } ?? text, scheme: .web, isAnchor: true)
        }
        let lower = text.lowercased()
        for blocked in ["javascript:", "data:", "blob:", "about:", "vbscript:"] where lower.hasPrefix(blocked) { return nil }
        if lower.hasPrefix("mailto:") { return Resolved(url: text, scheme: .mailto, isAnchor: false) }
        if lower.hasPrefix("tel:") || lower.hasPrefix("sms:") { return Resolved(url: text, scheme: .tel, isAnchor: false) }

        text = text.replacingOccurrences(of: " ", with: "%20")
        guard text.rangeOfCharacter(from: unwritable) == nil else { return nil }
        guard let url = URL(string: text, relativeTo: base)?.absoluteURL else { return nil }
        guard let scheme = url.scheme?.lowercased() else { return nil }
        guard scheme == "http" || scheme == "https" else {
            return Resolved(url: url.absoluteString, scheme: .other(scheme), isAnchor: false)
        }
        guard url.host?.isEmpty == false, var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        components.fragment = nil
        guard let clean = components.string else { return nil }
        return Resolved(url: clean, scheme: .web, isAnchor: false)
    }

    /// Whether `url` is on the same site as `base`: the same host, with a
    /// leading `www.` not counting. For labelling a link, nothing more — no
    /// request depends on the answer.
    static func isSameSite(_ url: String, as base: URL) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased(), let baseHost = base.host?.lowercased() else { return false }
        func bare(_ value: String) -> String { value.hasPrefix("www.") ? String(value.dropFirst(4)) : value }
        return bare(host) == bare(baseHost)
    }

    /// The candidates of an `srcset` (or `imagesrcset`) value, the way the
    /// specification reads it. An address may itself contain commas
    /// (`w_300,h_200`), so a comma only ends one when whitespace or the end
    /// follows it.
    static func parseSrcset(_ value: String) -> [(url: String, descriptor: String?)] {
        let chars = Array(value)
        var result: [(url: String, descriptor: String?)] = []
        var i = 0
        while i < chars.count {
            while i < chars.count, chars[i].isWhitespace || chars[i] == "," { i += 1 }
            guard i < chars.count else { break }
            let start = i
            while i < chars.count, !chars[i].isWhitespace { i += 1 }
            var url = String(chars[start..<i])
            if url.hasSuffix(",") {
                while url.hasSuffix(",") { url.removeLast() }
                if !url.isEmpty { result.append((url, nil)) }
                continue
            }
            // The descriptor runs to the next comma that is not inside parentheses.
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            let descriptorStart = i
            var depth = 0
            while i < chars.count {
                if chars[i] == "(" { depth += 1 }
                if chars[i] == ")" { depth = max(0, depth - 1) }
                if chars[i] == ",", depth == 0 { break }
                i += 1
            }
            let descriptor = String(chars[descriptorStart..<i]).trimmingCharacters(in: .whitespaces)
            if !url.isEmpty { result.append((url, descriptor.isEmpty ? nil : descriptor)) }
        }
        return result
    }

    /// Every `url(...)` in a style attribute or rule, unquoted.
    static func cssURLs(in css: String) -> [String] {
        guard css.contains("url(") || css.contains("URL(") else { return [] }
        guard let regex = try? NSRegularExpression(pattern: #"url\(\s*(?:"([^"]*)"|'([^']*)'|([^)\s]*))\s*\)"#, options: [.caseInsensitive]) else {
            return []
        }
        let text = css as NSString
        var found: [String] = []
        regex.enumerateMatches(in: css, range: NSRange(location: 0, length: text.length)) { match, _, _ in
            guard let match else { return }
            for group in 1...3 where match.range(at: group).location != NSNotFound {
                let value = text.substring(with: match.range(at: group))
                if !value.isEmpty { found.append(value) }
                break
            }
        }
        return found
    }
}
