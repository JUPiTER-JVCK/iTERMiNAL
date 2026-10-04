import Foundation

/// What a response body looks like, for choosing how to render it.
/// `.other` carries the media type the server declared when it doesn't match
/// any case this app treats specially — shown as-is rather than discarded,
/// so "this was `image/png`" still reaches the response view even with no
/// image renderer behind it.
enum HTTPContentKind: Equatable {
    case json
    case html
    case xml
    case plainText
    case binary
    case other(String)
}

/// Turns raw response bytes into something a response viewer can put on
/// screen: what kind of content it is, decoded (and, for JSON, pretty-printed)
/// text, and a size limit enforced on the *rendered* text.
///
/// This limit is deliberately separate from whatever byte cap stopped the
/// download in the networking layer — that one protects memory and the
/// network; this one protects the UI from a huge string, as a second,
/// cheap layer of defense in depth, not a replacement for the first.
enum HTTPResponseFormatter {
    /// Classifies by the `Content-Type` header when there is one — a server
    /// mislabeling its own response, and doing so on purpose, are both rare
    /// enough that trusting what it says is the right default — and falls
    /// back to sniffing the first bytes only when there is no header at all
    /// or it names nothing recognised.
    static func classify(contentTypeHeader: String?, sampleBytes: Data) -> HTTPContentKind {
        if let header = contentTypeHeader {
            // `split` omits empty subsequences by default, so an empty or
            // `;`-leading header would leave an empty array and crash a
            // bare `[0]` subscript — `omittingEmptySubsequences: false` plus
            // a safe `.first` keeps every shape of header, including an
            // empty string, falling through to sniffing below instead.
            let rawMediaType = header
                .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map(String.init) ?? ""
            let mediaType = rawMediaType.trimmingCharacters(in: .whitespaces).lowercased()
            if !mediaType.isEmpty {
                if mediaType.contains("json") { return .json }
                if mediaType.contains("html") { return .html }
                if mediaType.contains("xml") { return .xml }
                if mediaType.hasPrefix("text/") { return .plainText }
                // A declared binary type otherwise fell through to `.other`,
                // which `format` decodes as text — not a crash, since a
                // lossy decode always produces *some* string, but a long,
                // garbled one for what is almost always a short, useless
                // render of an image or a font. Known families only: this
                // is a recognised-binary list, not an attempt to name every
                // binary type that exists.
                let binaryPrefixes = ["image/", "video/", "audio/", "font/"]
                let binaryExactTypes: Set<String> = [
                    "application/octet-stream", "application/pdf", "application/zip",
                    "application/gzip", "application/x-gzip", "application/x-tar",
                    "application/wasm", "application/x-protobuf",
                ]
                if binaryPrefixes.contains(where: mediaType.hasPrefix) || binaryExactTypes.contains(mediaType) {
                    return .binary
                }
                return .other(mediaType)
            }
            // An empty Content-Type is as good as no header — fall through.
        }
        return sniff(sampleBytes)
    }

    /// No declared type: guess from the first non-whitespace byte, the way a
    /// JSON parser itself would skip leading whitespace before deciding.
    private static func sniff(_ data: Data) -> HTTPContentKind {
        guard !data.isEmpty else { return .plainText }
        let whitespaceBytes: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        var index = data.startIndex
        while index < data.endIndex, whitespaceBytes.contains(data[index]) {
            index = data.index(after: index)
        }
        if index < data.endIndex {
            let byte = data[index]
            if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
                return .json
            }
        }
        if String(data: data, encoding: .utf8) != nil {
            return .plainText
        }
        return .binary
    }

    /// Re-encodes a JSON body with readable indentation and sorted keys.
    ///
    /// The server's own key order is *not* recoverable here, on purpose —
    /// not a choice this function makes, but a fact about the round trip:
    /// `JSONSerialization.jsonObject` hands back a plain `Dictionary`, which
    /// has no concept of source order, and Swift randomises a dictionary's
    /// hash seed per process for hash-flooding resistance. Re-serializing
    /// without `.sortedKeys` doesn't preserve anything — it reproduces
    /// whichever order that process's random seed happens to produce, which
    /// can (and, checked directly while writing this, does) differ between
    /// runs of the very same binary on the very same input. `.sortedKeys`
    /// trades a server's real order, already lost by this point regardless,
    /// for one a person can actually read and expect to see again.
    /// `nil` on anything that doesn't parse as JSON at all, including a body
    /// this function was never meant to see.
    static func prettyPrintJSON(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        guard let pretty = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .fragmentsAllowed, .sortedKeys]
        ) else {
            return nil
        }
        return String(data: pretty, encoding: .utf8)
    }

    /// Decodes response bytes to text: the charset the server declared, if
    /// any and if recognised, else UTF-8, else a lossy decode — so a
    /// binary-ish body still renders as *something* rather than nothing.
    static func decodedText(_ data: Data, contentType: String?) -> String {
        if let contentType, let range = contentType.range(of: "charset=", options: .caseInsensitive) {
            var charset = String(contentType[range.upperBound...])
            if let semicolon = charset.firstIndex(of: ";") {
                charset = String(charset[..<semicolon])
            }
            charset = charset
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if let encoding = stringEncoding(forCharset: charset), let decoded = String(data: data, encoding: encoding) {
                return decoded
            }
        }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// A small, named table rather than an exhaustive one — the charsets
    /// that actually show up on the modern web, not every charset there has
    /// ever been. Anything else falls through to the UTF-8/lossy path above.
    private static func stringEncoding(forCharset charset: String) -> String.Encoding? {
        switch charset.lowercased() {
        case "utf-8", "utf8": return .utf8
        case "iso-8859-1", "latin1": return .isoLatin1
        case "us-ascii", "ascii": return .ascii
        case "utf-16": return .utf16
        default: return nil
        }
    }

    /// Caps rendered text at `maxCharacters`, with a trailing marker naming
    /// how much was cut, so a truncated view is never mistaken for the whole
    /// response.
    static func truncated(_ text: String, maxCharacters: Int) -> (text: String, wasTruncated: Bool) {
        guard text.count > maxCharacters else { return (text, false) }
        let cutoff = text.index(text.startIndex, offsetBy: maxCharacters)
        let shown = String(text[..<cutoff])
        let marker = "\n\u{2026} truncated (showing first \(maxCharacters) of \(text.count) characters) \u{2026}"
        return (shown + marker, true)
    }

    struct FormattedBody: Equatable {
        var text: String
        var kind: HTTPContentKind
        var wasTruncated: Bool
        var originalByteCount: Int
    }

    /// The one entry point: classify, decode (pretty-printing when it parses
    /// as JSON, falling back to plain decoding when it doesn't), then
    /// truncate for display.
    static func format(_ data: Data, contentType: String?, maxCharacters: Int) -> FormattedBody {
        let kind = classify(contentTypeHeader: contentType, sampleBytes: data.prefix(256))
        let rawText: String
        switch kind {
        case .json:
            rawText = prettyPrintJSON(data) ?? decodedText(data, contentType: contentType)
        case .binary:
            let label = contentType.map { ": \($0)" } ?? ""
            rawText = "[binary data\(label), \(data.count) bytes]"
        case .html, .xml, .plainText, .other:
            rawText = decodedText(data, contentType: contentType)
        }
        let (shown, wasTruncated) = truncated(rawText, maxCharacters: maxCharacters)
        return FormattedBody(text: shown, kind: kind, wasTruncated: wasTruncated, originalByteCount: data.count)
    }
}
