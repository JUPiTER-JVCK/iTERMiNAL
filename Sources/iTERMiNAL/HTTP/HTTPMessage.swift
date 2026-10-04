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
struct HTTPHeaderField: Identifiable, Equatable {
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
        var parts = ["curl", "-X", shellQuote(spec.method.rawValue), shellQuote(spec.url)]
        for header in spec.headers where !header.name.isEmpty {
            parts.append("-H")
            parts.append(shellQuote("\(header.name): \(header.value)"))
        }
        if let body = spec.body, !body.isEmpty {
            parts.append("--data")
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
}
