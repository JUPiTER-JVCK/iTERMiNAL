import Foundation

/// Masks values that look like credentials in terminal text before it goes to
/// an assistant.
///
/// Best effort, and only that: it knows the shapes of common tokens and the way
/// secrets are usually written (`password=…`, `Authorization: …`, a key in a
/// URL), not every secret there is. A credential in a form it does not
/// recognise still goes through, which is why nothing that uses it says "no
/// secrets are sent".
enum SecretRedactor {
    static let mask = "[redacted]"

    private struct Definition {
        let pattern: String
        let template: String
        var caseInsensitive = false
    }

    private static let definitions: [Definition] = [
        // A private key, from its header to its footer — or to the end of the
        // text, when what was captured stops in the middle of one.
        Definition(
            pattern: #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\z)"#,
            template: "[redacted private key]"
        ),
        // A password in a URL: scheme://user:password@host. The scheme is at most 32
        // characters (they are a dozen or so): unbounded, a long run of letters and
        // dots was read to its end from every word boundary in it, and a page of
        // those took minutes.
        Definition(pattern: #"(\b[A-Za-z][A-Za-z0-9+.-]{0,31}://[^\s/:@]+):[^\s/@]+@"#, template: "$1:[redacted]@"),
        // Authorization headers, whatever the scheme.
        Definition(
            pattern: #"(\bauthorization[ \t]*[:=][ \t]*)(?:(?:basic|bearer|token|digest)[ \t]+)?[^\s'"]+"#,
            template: "$1[redacted]",
            caseInsensitive: true
        ),
        Definition(pattern: #"\b(bearer)[ \t]+[A-Za-z0-9._~+/=-]{8,}"#, template: "$1 [redacted]", caseInsensitive: true),
        // Tokens with a shape of their own.
        Definition(pattern: #"\b(?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA|ANVA|AIPA)[A-Z0-9]{16}\b"#, template: mask),
        Definition(pattern: #"\bgh[pousr]_[A-Za-z0-9]{36,}\b"#, template: mask),
        Definition(pattern: #"\bgithub_pat_[A-Za-z0-9_]{22,}\b"#, template: mask),
        Definition(pattern: #"\bxox[abprs]-[A-Za-z0-9-]{10,}\b"#, template: mask),
        Definition(pattern: #"\bsk-[A-Za-z0-9_-]{20,}"#, template: mask),
        Definition(pattern: #"\bAIza[0-9A-Za-z_-]{35}\b"#, template: mask),
        Definition(pattern: #"\b[rs]k_(?:live|test)_[0-9A-Za-z]{16,}\b"#, template: mask),
        // A JWT's header is a hundred characters or so and its payload a few thousand;
        // the bounds keep `eyJ-eyJ-eyJ-…` from being read to its end from every `eyJ`.
        Definition(pattern: #"\beyJ[A-Za-z0-9_-]{8,1024}\.[A-Za-z0-9_-]{8,16384}\.[A-Za-z0-9_-]{8,}"#, template: mask),
        // A secret handed to a command as a flag: --password hunter2, --token=abc.
        // Not when what follows is another flag.
        Definition(
            pattern: #"(--?(?:password|passwd|pass|token|secret|api[-_]?key|apikey|access[-_]?key|auth[-_]?token)(?:=|[ \t]+))(?!-)(?:"[^"]*"|'[^']*'|\S+)"#,
            template: "$1[redacted]",
            caseInsensitive: true
        ),
        // A secret assigned to a name that says it is one: PASSWORD=…, "api_key": "…".
        // The value must be on the same line, so a prompt that ends in a colon
        // does not take the next line with it.
        //
        // The match begins at the word that says it (`PASSWORD` in `DB_PASSWORD`)
        // and not at the start of the name, which is left as it was: reading the
        // name from its start meant reading it to its end from every word boundary
        // in a long run of dots and hyphens, over and over. What follows the word is
        // read for at most 64 characters, for the same reason.
        Definition(
            pattern: #"((?:password|passwd|passphrase|secret|token|api[_-]?key|apikey|access[_-]?key|private[_-]?key|credentials?)[A-Za-z0-9_.-]{0,64}["']?[ \t]*[:=][ \t]*)(?:"[^"]*"|'[^']*'|[^\s,;]+)"#,
            template: "$1[redacted]",
            caseInsensitive: true
        ),
    ]

    private static let rules: [(regex: NSRegularExpression, template: String)] = definitions.compactMap { definition in
        let options: NSRegularExpression.Options = definition.caseInsensitive ? [.caseInsensitive] : []
        guard let regex = try? NSRegularExpression(pattern: definition.pattern, options: options) else { return nil }
        return (regex, definition.template)
    }

    /// False if any pattern failed to compile. Checked by the logic checks, and
    /// by `redact` itself: a redactor that silently does less than it claims is
    /// worse than one that refuses.
    static var isOperational: Bool { rules.count == definitions.count }

    static func redact(_ text: String) -> String {
        guard isOperational else {
            assertionFailure("SecretRedactor pattern failed to compile")
            return "[output withheld: it could not be checked for secrets]"
        }
        var result = text
        for rule in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = rule.regex.stringByReplacingMatches(in: result, range: range, withTemplate: rule.template)
        }
        return result
    }
}
