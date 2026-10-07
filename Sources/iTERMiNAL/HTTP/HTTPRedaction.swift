import Foundation

/// Masks credentials in the parts of a request this app writes to disk or
/// hands to API subscribers.
///
/// Best effort, like `SecretRedactor` underneath it — but with two
/// deterministic layers on top that regexes over free text can't give:
/// headers whose value is a credential *by definition* are masked whole,
/// whatever shape the value has, and a short list of query-parameter names
/// that carry credentials are masked by name.
enum HTTPRedaction {
    static let mask = SecretRedactor.mask

    /// Headers whose entire value is a credential. `SecretRedactor` can only
    /// recognise a secret by its shape or by a telling name, and a session
    /// cookie (`sessionid=3fa9…`) has neither.
    private static let credentialHeaders: Set<String> = [
        "authorization", "proxy-authorization", "cookie", "set-cookie",
    ]

    /// Query parameters that carry a credential or a signature. Lower case;
    /// compared after percent-decoding the name. Names `SecretRedactor`
    /// already catches (`token`, `password`, `api_key`, …) aren't repeated.
    private static let sensitiveQueryParameters: Set<String> = [
        "code", "key", "sig", "signature", "session", "sessionid", "sid", "auth",
        "x-amz-signature", "x-amz-credential", "x-amz-security-token",
    ]

    /// A header's value with its name as context: a credential header is
    /// masked whole, and any other header goes through `SecretRedactor`
    /// as `"name: value"` so patterns that key off the pair (`api_key: …`)
    /// have something to match, then has its name stripped back off.
    static func redactedHeaderValue(name: String, value: String) -> String {
        let normalizedName = name.trimmingCharacters(in: .whitespaces).lowercased()
        if credentialHeaders.contains(normalizedName) {
            return value.isEmpty ? value : mask
        }
        let prefix = "\(name): "
        let redacted = SecretRedactor.redact(prefix + value)
        if redacted.hasPrefix(prefix) {
            return String(redacted.dropFirst(prefix.count))
        }
        return SecretRedactor.redact(value)
    }

    /// A URL with credentials masked: `user:password@`, anything
    /// `SecretRedactor` recognises, and the value of each query parameter in
    /// `sensitiveQueryParameters`. Works on the string itself rather than
    /// round-tripping through `URLComponents`, so everything it doesn't
    /// touch comes back byte for byte.
    ///
    /// The query and the fragment are redacted one `name=value` pair at a
    /// time. `SecretRedactor`'s assignment pattern reads a value up to the
    /// next whitespace, which in a URL is the end of the string — run over
    /// the whole thing, `?token=abc&page=2` came back as `?token=[redacted]`
    /// with `page=2` swallowed along with the secret.
    static func redactedURL(_ url: String) -> String {
        let hash = url.firstIndex(of: "#")
        let mark = url.firstIndex(of: "?")

        let baseEnd: String.Index
        var query: Substring?
        var fragment: Substring?
        if let mark, hash == nil || mark < hash! {
            baseEnd = mark
            query = url[url.index(after: mark)..<(hash ?? url.endIndex)]
            fragment = hash.map { url[url.index(after: $0)...] }
        } else if let mark {
            // A `?` after the `#`: a hash-routed app (`/#/cb?code=…`), which
            // keeps its real query inside the fragment.
            baseEnd = mark
            query = url[url.index(after: mark)...]
        } else if let hash {
            baseEnd = hash
            fragment = url[url.index(after: hash)...]
        } else {
            baseEnd = url.endIndex
        }

        var result = SecretRedactor.redact(String(url[..<baseEnd]))
        if let query { result += "?" + redactedPairs(query) }
        if let fragment { result += "#" + redactedPairs(fragment) }
        return result
    }

    private static func redactedPairs(_ text: Substring) -> String {
        text.split(separator: "&", omittingEmptySubsequences: false)
            .map { pair -> String in
                if let equals = pair.firstIndex(of: "=") {
                    let name = String(pair[..<equals])
                    let decoded = (name.removingPercentEncoding ?? name).lowercased()
                    if sensitiveQueryParameters.contains(decoded) { return "\(name)=\(mask)" }
                }
                return SecretRedactor.redact(String(pair))
            }
            .joined(separator: "&")
    }
}
