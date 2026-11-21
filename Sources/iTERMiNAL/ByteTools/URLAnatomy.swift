import Foundation

/// A URL split the way RFC 3986 splits it: scheme, userinfo, host, port, path,
/// query and fragment. Each part is kept exactly as written, with the
/// percent-decoded form beside it where decoding changes anything.
///
/// This is a reader for looking at a URL, not a validator: it says what it
/// found and never refuses a string, because a malformed URL is exactly what
/// someone opens this tool to understand.
struct URLAnatomy: Equatable {
    struct QueryItem: Equatable {
        let rawName: String
        let rawValue: String?
        let name: String
        let value: String?
    }

    enum PartKind: String, Equatable {
        case scheme, userinfo, host, port, path, query, fragment
    }

    /// One coloured piece of the URL in order, including its punctuation.
    struct Segment: Equatable {
        let kind: PartKind?
        let text: String
    }

    var scheme: String?
    var user: String?
    var password: String?
    var host: String?
    var port: String?
    var path: String = ""
    var query: String?
    var fragment: String?
    var queryItems: [QueryItem] = []
    /// What the reader noticed that deserves a second look.
    var notes: [String] = []

    var hasAuthority: Bool { host != nil || user != nil }

    var userinfo: String? {
        guard let user else { return nil }
        return password.map { user + ":" + $0 } ?? user
    }

    /// The port in use: the one written, or the scheme's own.
    var effectivePort: Int? {
        if let port, let number = Int(port) { return number }
        return scheme.flatMap { URLAnatomy.defaultPorts[$0.lowercased()] }
    }

    static let defaultPorts: [String: Int] = [
        "http": 80, "https": 443, "ftp": 21, "ssh": 22, "sftp": 22, "telnet": 23, "smtp": 25,
        "ws": 80, "wss": 443, "ldap": 389, "ldaps": 636, "imap": 143, "imaps": 993,
        "pop3": 110, "pop3s": 995, "redis": 6379, "postgres": 5432, "postgresql": 5432,
        "mysql": 3306, "mongodb": 27017, "git": 9418, "rdp": 3389, "vnc": 5900,
    ]

    /// Pieces in order, ready to colour.
    var segments: [Segment] {
        var out: [Segment] = []
        if let scheme {
            out.append(Segment(kind: .scheme, text: scheme))
            out.append(Segment(kind: nil, text: hasAuthority ? "://" : ":"))
        } else if hasAuthority {
            out.append(Segment(kind: nil, text: "//"))
        }
        if let userinfo {
            out.append(Segment(kind: .userinfo, text: userinfo))
            out.append(Segment(kind: nil, text: "@"))
        }
        if let host { out.append(Segment(kind: .host, text: host)) }
        if let port {
            out.append(Segment(kind: nil, text: ":"))
            out.append(Segment(kind: .port, text: port))
        }
        if !path.isEmpty { out.append(Segment(kind: .path, text: path)) }
        if let query {
            out.append(Segment(kind: nil, text: "?"))
            out.append(Segment(kind: .query, text: query))
        }
        if let fragment {
            out.append(Segment(kind: nil, text: "#"))
            out.append(Segment(kind: .fragment, text: fragment))
        }
        return out
    }

    // MARK: Reading

    static func parse(_ input: String) -> URLAnatomy {
        var result = URLAnatomy()
        var rest = input.trimmingCharacters(in: .whitespacesAndNewlines)

        if let hash = rest.firstIndex(of: "#") {
            result.fragment = String(rest[rest.index(after: hash)...])
            rest = String(rest[..<hash])
        }
        if let question = rest.firstIndex(of: "?") {
            result.query = String(rest[rest.index(after: question)...])
            rest = String(rest[..<question])
        }
        if let colon = rest.firstIndex(of: ":") {
            let candidate = rest[..<colon]
            let valid = candidate.first.map { $0.isASCII && $0.isLetter } ?? false
                && candidate.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }
            if valid {
                result.scheme = String(candidate)
                rest = String(rest[rest.index(after: colon)...])
            }
        }
        if rest.hasPrefix("//") {
            rest.removeFirst(2)
            let end = rest.firstIndex(of: "/") ?? rest.endIndex
            var authority = String(rest[..<end])
            rest = String(rest[end...])
            if let at = authority.lastIndex(of: "@") {
                let info = String(authority[..<at])
                authority = String(authority[authority.index(after: at)...])
                if let colon = info.firstIndex(of: ":") {
                    result.user = String(info[..<colon])
                    result.password = String(info[info.index(after: colon)...])
                } else {
                    result.user = info
                }
            }
            if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
                result.host = String(authority[...close])
                let after = authority[authority.index(after: close)...]
                if after.hasPrefix(":") { result.port = String(after.dropFirst()) }
            } else if let colon = authority.lastIndex(of: ":") {
                let candidate = String(authority[authority.index(after: colon)...])
                if candidate.allSatisfy({ $0.isASCII && $0.isNumber }) {
                    result.host = String(authority[..<colon])
                    result.port = candidate
                } else {
                    result.host = authority
                }
            } else {
                result.host = authority
            }
            if result.host == nil { result.host = "" }
        }
        result.path = rest
        if let query = result.query {
            result.queryItems = query.split(separator: "&", omittingEmptySubsequences: true).map { pair in
                let text = String(pair)
                if let equals = text.firstIndex(of: "=") {
                    let rawName = String(text[..<equals])
                    let rawValue = String(text[text.index(after: equals)...])
                    return QueryItem(rawName: rawName, rawValue: rawValue,
                                     name: decodeComponent(rawName), value: decodeComponent(rawValue))
                }
                return QueryItem(rawName: text, rawValue: nil, name: decodeComponent(text), value: nil)
            }
        }
        result.notes = result.makeNotes()
        return result
    }

    /// Percent-decoded, with `+` as a space (how a query string is read). Text
    /// that is not valid percent-encoding is returned as it is.
    static func decodeComponent(_ text: String) -> String {
        guard case .success(let bytes) = PercentEncoding.decode(text, plusIsSpace: true) else { return text }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func makeNotes() -> [String] {
        var notes: [String] = []
        if user != nil {
            notes.append("A username or password in a URL is deprecated and unsafe: it is sent to the server and kept in history.")
        }
        if let port {
            if port.isEmpty {
                notes.append("The port is empty, so the scheme's default is used.")
            } else if let number = Int(port), !(0...65535).contains(number) {
                notes.append("Port \(number) is outside 0–65535.")
            }
        }
        if let host, !host.isEmpty, host.unicodeScalars.contains(where: { $0.value > 127 }) {
            notes.append("The host has non-ASCII characters; it is sent as Punycode: \(Punycode.toASCII(host)).")
        }
        if let host, host.lowercased().contains("xn--") {
            let unicode = Punycode.toUnicode(host)
            notes.append("The host is Punycode for “\(unicode)”. Check it is the name you expect.")
            if Punycode.labels(of: host).contains(where: { Punycode.mixesScripts($0.unicode) }) {
                notes.append("A label mixes alphabets — the shape of a look-alike (homograph) domain.")
            }
        }
        if let scheme, hasAuthority == false, !scheme.isEmpty, ["http", "https", "ftp", "ws", "wss"].contains(scheme.lowercased()) {
            notes.append("\(scheme) URLs normally have // and a host after the colon.")
        }
        if fragment != nil {
            notes.append("The #fragment is for the browser only: it is never sent to the server.")
        }
        return notes
    }

    /// A short line saying what a part is for.
    static func role(of kind: PartKind) -> String {
        switch kind {
        case .scheme: return "the protocol — how to talk to the host"
        case .userinfo: return "username[:password] — deprecated and unsafe in real URLs"
        case .host: return "the server to connect to (DNS name or IP literal)"
        case .port: return "TCP port; omitted means the scheme's default"
        case .path: return "the resource on the host"
        case .query: return "key=value parameters, joined by &"
        case .fragment: return "client-only anchor — never sent to the server"
        }
    }
}

/// What percent-encoding does to each character, for the URL-encoding tool.
struct PercentBreakdown: Equatable {
    struct Piece: Equatable {
        /// The character as typed.
        let character: String
        /// What it became.
        let encoded: String
        /// Its UTF-8 bytes in hex, so a multi-byte character shows its parts.
        let bytes: [UInt8]
        var changed: Bool { character != encoded }
    }

    static func pieces(of text: String, allowed: PercentEncoding.Allowed, spaceAsPlus: Bool, limit: Int = 400) -> [Piece] {
        text.prefix(limit).map { char in
            let bytes = Array(String(char).utf8)
            return Piece(character: String(char),
                         encoded: PercentEncoding.encode(bytes, allowed: allowed, spaceAsPlus: spaceAsPlus),
                         bytes: bytes)
        }
    }
}
