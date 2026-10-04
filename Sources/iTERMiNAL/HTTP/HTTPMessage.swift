import Foundation

/// An HTTP method, kept as a wrapper around its own text rather than a closed
/// `enum`. A person typing `PROPFIND` or `REPORT` into the method field is
/// not a bug to route through a `default` case — every method this type
/// doesn't already name is still a first-class value.
struct HTTPMethod: RawRepresentable, Hashable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue.uppercased()
    }

    init(_ rawValue: String) {
        self.init(rawValue: rawValue)
    }

    static let get = HTTPMethod("GET")
    static let post = HTTPMethod("POST")
    static let put = HTTPMethod("PUT")
    static let patch = HTTPMethod("PATCH")
    static let delete = HTTPMethod("DELETE")
    static let head = HTTPMethod("HEAD")
    static let options = HTTPMethod("OPTIONS")

    /// The methods offered first in the builder's picker. Anything else can
    /// still be typed; this is a shortlist, not a whitelist.
    static let common: [HTTPMethod] = [.get, .post, .put, .patch, .delete, .head, .options]

    /// Methods a body is never meaningful for. The builder hides the body
    /// editor for these rather than merely allowing an empty one.
    static let bodylessByConvention: Set<HTTPMethod> = [.get, .head]
}

/// One header row. `name`/`value` are `var` because the row is edited in
/// place in a form; `id` is stable across those edits so SwiftUI's list
/// diffing never confuses an edited row for a different one.
struct HTTPHeaderField: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var value: String

    init(id: UUID = UUID(), name: String, value: String) {
        self.id = id
        self.name = name
        self.value = value
    }
}

/// A fully *resolved* request, ready to send: every `{{variable}}` has
/// already been substituted. Nothing downstream of this type ever sees a
/// placeholder.
struct HTTPRequestSpec: Equatable {
    var method: HTTPMethod
    var url: String
    var headers: [HTTPHeaderField]
    var body: String?
}

/// What came back. There is no `statusText` field on purpose:
/// `HTTPURLResponse` does not reliably expose a reason phrase on Apple
/// platforms, so a field that is usually empty would be worse than no field.
struct HTTPResponseSummary: Equatable {
    var statusCode: Int
    var headers: [HTTPHeaderField]
    var body: Data
    /// The URL actually reached, after any redirects were followed.
    var finalURL: String
    var startedAt: Date
    var duration: TimeInterval
}

/// Free helpers over a request that don't belong to the struct itself.
enum HTTPMessage {
    /// A `curl` invocation that reproduces `spec`, for a "Copy as cURL"
    /// action. Every value is single-quoted for a POSIX shell, so the result
    /// is safe to paste even when a header or the body itself contains a
    /// quote, a space, or a `$`.
    static func curlCommand(for spec: HTTPRequestSpec) -> String {
        // `normalizedURL` is the same resolution `execute` sends to the
        // network — without it, a bare `example.com` (no scheme typed)
        // copies as a curl command that defaults to plain HTTP, downgrading
        // a request this app actually sent over HTTPS.
        let url = normalizedURL(from: spec.url)?.absoluteString ?? spec.url
        var parts = ["curl", "-X", shellQuote(spec.method.rawValue), shellQuote(url)]
        for header in spec.headers where !header.name.isEmpty {
            parts.append("-H")
            parts.append(shellQuote("\(header.name): \(header.value)"))
        }
        if let body = spec.body, !body.isEmpty {
            // `--data-raw`, not `--data`: curl treats a `--data` value that
            // starts with `@` as a filename to read instead of literal text,
            // even single-quoted — a body that happens to start with `@`
            // would otherwise exfiltrate a local file instead of
            // reproducing the request.
            parts.append("--data-raw")
            parts.append(shellQuote(body))
        }
        return parts.joined(separator: " ")
    }

    /// Wraps `value` in single quotes, escaping any single quote it contains
    /// as `'"'"'` — the standard POSIX trick: close the quoted string, emit a
    /// double-quoted single quote, reopen. Nothing else needs escaping inside
    /// single quotes.
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// Turns what a person typed into the URL field into a real URL: adds
    /// `https://` when there is no scheme at all, the way an address bar
    /// would, and otherwise leaves an explicit scheme exactly as written —
    /// including a plain `http://`, which the networking layer decides
    /// whether to allow, not this function.
    ///
    /// Deliberately checks for a literal `"://"` rather than trusting
    /// `URL`'s own `scheme` — checked directly while writing this:
    /// `URL(string: "localhost:8080")` parses with `scheme == "localhost"`
    /// and `host == nil`, reading the port as a bogus scheme. Trusting that
    /// would reject the single most common thing to type here — a bare
    /// local address with a port — as invalid.
    static func normalizedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") {
            guard let url = URL(string: trimmed), url.host != nil else { return nil }
            return url
        }
        return URL(string: "https://" + trimmed)
    }
}
