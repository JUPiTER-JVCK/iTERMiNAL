import SwiftUI
import AppKit
import ImageIO

/// Small pictures of the images a page lists, fetched as their rows are looked
/// at — and only once previews have been turned on.
///
/// Every picture is a request to the site that hosts it, so this goes by the
/// rules downloads follow (`ImagePreviewPolicy`, which defers to
/// `DownloadPolicy`): nothing a page names can send it to this Mac or its
/// network, no cookies or credentials go with a request, a redirect is judged
/// again, and a response is cut off at a small size. At most a few run at once,
/// and only so many for one page.
///
/// Like the models it sits beside, not `@MainActor`: it is held by one that
/// nonisolated code reads. Everything a view reads is changed on the main
/// thread.
final class ImagePreviewLoader: ObservableObject {
    enum Thumbnail {
        case loading
        case ready(NSImage)
        case failed(String)
    }

    @Published private(set) var thumbnails: [String: Thumbnail] = [:]
    /// The cap on previews for this page has been reached.
    @Published private(set) var limitReached = false

    private var requested = 0
    private var queue: [(address: String, pageURL: String)] = []
    private var inFlight = 0
    private var tasks: [String: Task<Void, Never>] = [:]
    private var generation = 0

    /// Asks for the picture at `address`, which `pageURL` named. Already asked
    /// for, refused, or finished, it does nothing.
    func request(_ address: String, pageURL: String) {
        guard thumbnails[address] == nil else { return }
        switch ImagePreviewPolicy.decide(address: address, pageURL: pageURL, alreadyRequested: requested) {
        case .skip(let reason):
            thumbnails[address] = .failed(reason)
            return
        case .fetch:
            break
        }
        requested += 1
        limitReached = requested >= ImagePreviewPolicy.perResponse
        thumbnails[address] = .loading
        queue.append((address: address, pageURL: pageURL))
        pump()
    }

    /// A new response is in hand: what was asked for the last one is dropped,
    /// and what is still on its way is stopped.
    func reset() {
        generation += 1
        for task in tasks.values { task.cancel() }
        tasks = [:]
        queue = []
        inFlight = 0
        requested = 0
        limitReached = false
        thumbnails = [:]
    }

    private func pump() {
        while inFlight < ImagePreviewPolicy.concurrency, !queue.isEmpty {
            let next = queue.removeFirst()
            inFlight += 1
            let mine = generation
            tasks[next.address] = Task { [weak self] in
                let result = await Self.fetch(next.address, pageURL: next.pageURL)
                await MainActor.run {
                    guard let self, self.generation == mine else { return }
                    self.inFlight -= 1
                    self.tasks[next.address] = nil
                    self.thumbnails[next.address] = result
                    self.pump()
                }
            }
        }
    }

    private static func fetch(_ address: String, pageURL: String) async -> Thumbnail {
        guard let url = URL(string: address) else { return .failed("not an address") }
        var request = URLRequest(url: url)
        request.setValue("image/png,image/jpeg,image/gif,image/webp,image/*;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
        if let referer = DownloadPolicy.referer(page: pageURL, target: address) {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        let fetch = FileFetch(pageURL: pageURL, maxBytes: ImagePreviewPolicy.maxBytes) { _, _ in }
        switch await fetch.run(request, timeout: ImagePreviewPolicy.timeout, resourceTimeout: ImagePreviewPolicy.timeout * 2) {
        case .cancelled:
            return .failed("cancelled")
        case .failed(let reason):
            return .failed(reason)
        case .file(let temporary, let response, _):
            defer { try? FileManager.default.removeItem(at: temporary) }
            if let reason = ImagePreviewPolicy.refusal(contentType: response.value(forHTTPHeaderField: "Content-Type")) {
                return .failed(reason)
            }
            switch ImageThumbnail.make(from: temporary) {
            case .success(let image): return .ready(image)
            case .failure(let failure): return .failed(failure.message)
            }
        }
    }
}

/// A small picture made from a file the system's image code can read.
///
/// Read through ImageIO's thumbnail path, which for most formats decodes at the
/// reduced size and not in full, after a look at the picture's dimensions: a
/// small file can describe a bitmap of gigabytes.
enum ImageThumbnail {
    struct Failure: Error {
        let message: String
    }

    static func make(from file: URL) -> Result<NSImage, Failure> {
        let unreadable = Failure(message: "not a picture this Mac can show")
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(file as CFURL, sourceOptions as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { return .failure(unreadable) }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard width > 0, height > 0 else { return .failure(unreadable) }
        guard ImagePreviewPolicy.withinPixelLimit(width: width, height: height) else {
            return .failure(Failure(message: "too many pixels to preview (\(width) × \(height))"))
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: ImagePreviewPolicy.thumbnailPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return .failure(unreadable)
        }
        return .success(NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
    }
}

/// The picture beside an image's row, or why there isn't one.
struct ImagePreviewThumb: View {
    @ObservedObject var loader: ImagePreviewLoader
    let address: String
    let theme: Theme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(theme.surface)
            switch loader.thumbnails[address] {
            case .ready(let image)?:
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(2)
            case .failed(let reason)?:
                Image(systemName: "photo")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary.opacity(0.6))
                    .help(reason)
            case .loading?, nil:
                Image(systemName: "photo")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSecondary.opacity(0.3))
            }
        }
        .frame(width: 44, height: 44)
        .accessibilityHidden(true)
    }
}

/// A line under the list when the cap on previews has been reached.
struct ImagePreviewNote: View {
    @ObservedObject var loader: ImagePreviewLoader
    let theme: Theme

    var body: some View {
        if loader.limitReached {
            Text("Previews are loaded for the first \(ImagePreviewPolicy.perResponse) pictures on a page.")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
