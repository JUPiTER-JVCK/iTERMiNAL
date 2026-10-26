import Foundation

/// What to call a file that came from an address, and what kind of thing an
/// address looks like it names.
///
/// A name is built from text a web page supplied, so everything here treats it
/// as hostile: it never contains a slash, never starts with a dot, never climbs
/// out of the folder it is written into, and is never so long the file system
/// refuses it.
enum AssetNaming {
    /// A file system name for `url`, from what the server said (a
    /// `Content-Disposition` filename), else the last part of the path, with an
    /// extension taken from `contentType` if the name has none.
    static func fileName(for url: String, contentType: String? = nil, contentDisposition: String? = nil) -> String {
        var name = contentDisposition.flatMap(dispositionFileName)
        if name == nil || name?.isEmpty == true {
            name = lastPathComponent(of: url)
        }
        var clean = sanitize(name ?? "")
        if clean.isEmpty { clean = "download" }
        if (clean as NSString).pathExtension.isEmpty, let ext = fileExtension(forMimeType: contentType) {
            clean = limited(clean, reserving: ext.count + 1) + "." + ext
        }
        return clean
    }

    /// The part of the path after the last `/`, percent-decoded.
    static func lastPathComponent(of url: String) -> String {
        let path: String
        if let components = URLComponents(string: url) {
            path = components.percentEncodedPath
        } else {
            path = String(url.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        }
        let last = path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        return last.removingPercentEncoding ?? last
    }

    /// `name` made safe to use as a single file name.
    static func sanitize(_ name: String) -> String {
        // A path in a header or a decoded `%2F`: only the last part is a name,
        // whichever way the slashes lean.
        let lastPart = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        var scalars = String.UnicodeScalarView()
        for scalar in lastPart.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F || ":*?\"<>|".unicodeScalars.contains(scalar) {
                scalars.append("_")
            } else {
                scalars.append(scalar)
            }
        }
        var clean = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        // No hidden files, and no `.` or `..`.
        while clean.hasPrefix(".") { clean.removeFirst() }
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        return limited(clean, reserving: 0)
    }

    /// Cuts a name to a length every file system takes, keeping the extension.
    /// By bytes, not characters: 255 UTF-8 bytes is the limit that bites, and a
    /// name of emoji reaches it at a quarter of that many characters. This stops
    /// well short, so a `-12` added to make a name unique still fits.
    static func limited(_ name: String, reserving extra: Int) -> String {
        let budget = 200 - extra
        guard name.utf8.count > budget else { return name }
        let ext = (name as NSString).pathExtension
        var stem = name
        var suffix = ""
        if !ext.isEmpty, ext.utf8.count <= 12 {
            stem = (name as NSString).deletingPathExtension
            suffix = "." + ext
        }
        while !stem.isEmpty, stem.utf8.count + suffix.utf8.count > budget { stem.removeLast() }
        return (stem.isEmpty ? "download" : stem) + suffix
    }

    /// `name` if nothing has it yet, else `name-1`, `name-2`… with the
    /// extension kept at the end.
    static func unique(_ name: String, taken: (String) -> Bool) -> String {
        guard taken(name) else { return name }
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var counter = 1
        while true {
            let candidate = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
            if !taken(candidate) { return candidate }
            counter += 1
        }
    }

    // MARK: Content-Disposition

    /// The file name in a `Content-Disposition` header: `filename*` (RFC 5987,
    /// percent-encoded with a charset) when there is one, else `filename`.
    static func dispositionFileName(_ header: String) -> String? {
        if let extended = parameter("filename\\*", in: header) {
            // `UTF-8''caf%C3%A9.pdf` — charset, optional language, value.
            let parts = extended.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
            let encoded = parts.count == 3 ? String(parts[2]) : extended
            if let decoded = encoded.removingPercentEncoding, !decoded.isEmpty { return decoded }
        }
        return parameter("filename", in: header)
    }

    private static func parameter(_ name: String, in header: String) -> String? {
        let pattern = "(?:^|;)\\s*\(name)\\s*=\\s*(?:\"((?:[^\"\\\\]|\\\\.)*)\"|([^;\\s]+))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: header, range: NSRange(location: 0, length: (header as NSString).length))
        else { return nil }
        for group in 1...2 where match.range(at: group).location != NSNotFound {
            let value = (header as NSString).substring(with: match.range(at: group))
            return value.replacingOccurrences(of: "\\\"", with: "\"")
        }
        return nil
    }

    // MARK: Kinds

    enum Kind: String, CaseIterable {
        case image, video, audio, document, archive, other
    }

    private static let extensions: [Kind: Set<String>] = [
        .image: ["png", "jpg", "jpeg", "gif", "svg", "webp", "avif", "heic", "heif", "bmp", "ico", "tif", "tiff"],
        .video: ["mp4", "m4v", "mov", "webm", "mkv", "avi", "ogv", "mpg", "mpeg", "wmv", "flv", "m3u8"],
        .audio: ["mp3", "m4a", "wav", "flac", "ogg", "oga", "opus", "aac", "wma", "aiff"],
        .document: [
            "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "rtf", "txt", "csv", "tsv",
            "json", "xml", "epub", "mobi", "md", "pages", "numbers", "key",
        ],
        .archive: ["zip", "gz", "tgz", "tar", "bz2", "xz", "zst", "7z", "rar", "dmg", "pkg", "iso", "deb", "rpm", "apk", "exe", "msi", "jar"],
    ]

    /// What the ending of the address says the file is — a hint only, since an
    /// address is free to lie. `.other` for anything with no known ending.
    static func kind(ofURL url: String) -> Kind {
        let ext = pathExtension(ofURL: url)
        guard !ext.isEmpty else { return .other }
        for (kind, endings) in extensions where endings.contains(ext) { return kind }
        return .other
    }

    /// The lower-cased ending of the path, without the dot.
    static func pathExtension(ofURL url: String) -> String {
        let name = lastPathComponent(of: url)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return String(name[name.index(after: dot)...]).lowercased()
    }

    /// An extension for a media type, for a name that has none.
    static func fileExtension(forMimeType mime: String?) -> String? {
        guard let mime else { return nil }
        let type = mime.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        switch type {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/svg+xml": return "svg"
        case "image/avif": return "avif"
        case "image/heic": return "heic"
        case "image/x-icon", "image/vnd.microsoft.icon": return "ico"
        case "video/mp4": return "mp4"
        case "video/webm": return "webm"
        case "video/quicktime": return "mov"
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/ogg": return "ogg"
        case "audio/wav", "audio/x-wav": return "wav"
        case "audio/mp4", "audio/x-m4a": return "m4a"
        case "application/pdf": return "pdf"
        case "application/zip": return "zip"
        case "application/json": return "json"
        case "application/xml", "text/xml": return "xml"
        case "text/html": return "html"
        case "text/plain": return "txt"
        case "text/csv": return "csv"
        case "text/css": return "css"
        case "application/javascript", "text/javascript": return "js"
        case "font/woff2": return "woff2"
        case "font/woff": return "woff"
        default: return nil
        }
    }
}
