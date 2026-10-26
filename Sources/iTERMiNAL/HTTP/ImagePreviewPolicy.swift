import Foundation

/// What an image preview may ask for, and of what.
///
/// A preview is a request to whoever hosts the image — one nobody typed — so it
/// is held to the rules downloads are (`DownloadPolicy`: a page from the
/// internet cannot aim it at this Mac or its network) and kept small on every
/// side: how many, how big, how long, how many at once. Decoding a picture a
/// stranger made is also not free of risk, which is why previews are off until
/// they are asked for.
enum ImagePreviewPolicy {
    /// Previews fetched for one response. Scrolling a long page is never
    /// hundreds of requests to someone else's server.
    static let perResponse = 60
    /// In flight at once. The same as downloads: this is someone else's server.
    static let concurrency = 3
    /// The most a preview will take of one image, in bytes. A response is
    /// stopped the moment it passes this.
    static let maxBytes: Int64 = 5_000_000
    /// The most pixels a picture may have to be decoded. A file of five
    /// megabytes can unpack to several gigabytes of bitmap.
    static let maxPixels = 40_000_000
    /// The longer side of a thumbnail, in pixels: twice what a row shows, so it
    /// is sharp on a Retina screen.
    static let thumbnailPixels = 160
    /// A preview is not worth a long wait.
    static let timeout: TimeInterval = 15

    enum Decision: Equatable {
        case fetch
        /// Not fetched, and why, in words that fit a tooltip.
        case skip(String)
    }

    /// Whether the picture at `address`, named by the page at `pageURL`, gets a
    /// preview, given how many have been asked for already.
    static func decide(address: String, pageURL: String, alreadyRequested: Int) -> Decision {
        if let reason = DownloadPolicy.refusal(for: address, from: pageURL) { return .skip(reason) }
        guard alreadyRequested < perResponse else {
            return .skip("only the first \(perResponse) pictures on a page get a preview")
        }
        return .fetch
    }

    /// Why a response of this type cannot be a preview; nil if it can. No type
    /// at all is let through for the decoder to judge. SVG is a document that
    /// can carry script and is not drawn here, and a page of text is what a
    /// site sends in place of a picture it will not give away.
    static func refusal(contentType: String?) -> String? {
        guard let declared = contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased(),
              !declared.isEmpty else { return nil }
        if declared == "image/svg+xml" { return "SVG isn't previewed" }
        if declared.hasPrefix("image/") || declared == "application/octet-stream" || declared == "binary/octet-stream" {
            return nil
        }
        return "the site sent \(declared), not a picture"
    }

    /// Whether a picture of this size may be decoded. Written so it cannot
    /// overflow: the sides come out of the file.
    static func withinPixelLimit(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width <= maxPixels / height
    }
}
