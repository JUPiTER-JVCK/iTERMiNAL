import Foundation
import CoreServices

/// Saves the files a page named, into a folder, a few at a time.
///
/// What it will and will not do is `DownloadPolicy`'s: it fetches only what it
/// is handed, only addresses the page may make this app fetch, and re-checks
/// every redirect against the same rule — a server that answers an image
/// request with a redirect to `http://192.168.1.1/…` gets nothing. Requests
/// carry no cookies, no credentials and none of the headers the page was
/// fetched with: a file on another site is not owed the login to this one.
///
/// Not `@MainActor`, like the models it sits beside: the work happens off the
/// main thread and every change to what the UI reads is handed to it.
final class AssetDownloader: ObservableObject {
    struct Entry: Identifiable, Equatable {
        enum State: Equatable {
            case waiting
            case receiving(received: Int64, expected: Int64?)
            case saved(path: String, bytes: Int64)
            case failed(String)
            case cancelled
        }

        let item: DownloadItem
        var state: State
        var id: String { item.url }
    }

    /// Fetches in flight at once. Low on purpose: this is someone else's server.
    static let concurrency = 3

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var isRunning = false
    @Published private(set) var folder: URL?

    private var task: Task<Void, Never>?

    var savedURLs: [URL] {
        entries.compactMap { entry in
            if case .saved(let path, _) = entry.state { return URL(fileURLWithPath: path) }
            return nil
        }
    }

    var summary: (saved: Int, failed: Int, cancelled: Int, bytes: Int64) {
        var saved = 0, failed = 0, cancelled = 0
        var bytes: Int64 = 0
        for entry in entries {
            switch entry.state {
            case .saved(_, let size): saved += 1; bytes += size
            case .failed: failed += 1
            case .cancelled: cancelled += 1
            default: break
            }
        }
        return (saved, failed, cancelled, bytes)
    }

    func start(items: [DownloadItem], pageURL: String, folder: URL, maxBytes: Int64, timeout: TimeInterval) {
        guard !isRunning, !items.isEmpty else { return }
        entries = items.map { Entry(item: $0, state: .waiting) }
        self.folder = folder
        isRunning = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                for item in items { self.update(item.url, .failed("couldn't create \(folder.path): \(error.localizedDescription)")) }
                await self.finish()
                return
            }
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                while next < min(Self.concurrency, items.count) {
                    let item = items[next]
                    next += 1
                    group.addTask { await self.download(item, pageURL: pageURL, folder: folder, maxBytes: maxBytes, timeout: timeout) }
                }
                while await group.next() != nil {
                    guard next < items.count else { continue }
                    let item = items[next]
                    next += 1
                    group.addTask { await self.download(item, pageURL: pageURL, folder: folder, maxBytes: maxBytes, timeout: timeout) }
                }
            }
            await self.finish()
        }
    }

    func cancel() {
        task?.cancel()
    }

    func reset() {
        guard !isRunning else { return }
        entries = []
        folder = nil
    }

    private func finish() async {
        await MainActor.run {
            // Whatever never started was cancelled.
            for index in entries.indices where entries[index].state == .waiting { entries[index].state = .cancelled }
            isRunning = false
            task = nil
        }
    }

    private func update(_ url: String, _ state: Entry.State) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let index = self.entries.firstIndex(where: { $0.id == url }) else { return }
            self.entries[index].state = state
        }
    }

    // MARK: One file

    private func download(_ item: DownloadItem, pageURL: String, folder: URL, maxBytes: Int64, timeout: TimeInterval) async {
        guard !Task.isCancelled else {
            update(item.url, .cancelled)
            return
        }
        // Checked again here, not only when the batch was planned: this is the
        // last place before a request leaves.
        if let reason = DownloadPolicy.refusal(for: item.url, from: pageURL) {
            update(item.url, .failed("not fetched: \(reason)"))
            return
        }
        guard let url = URL(string: item.url) else {
            update(item.url, .failed("not an address"))
            return
        }
        var request = URLRequest(url: url)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if let referer = DownloadPolicy.referer(page: pageURL, target: item.url) {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        update(item.url, .receiving(received: 0, expected: nil))
        let fetch = FileFetch(pageURL: pageURL, maxBytes: maxBytes) { [weak self] received, expected in
            self?.update(item.url, .receiving(received: received, expected: expected))
        }
        switch await fetch.run(request, timeout: timeout) {
        case .cancelled:
            update(item.url, .cancelled)
        case .failed(let reason):
            update(item.url, .failed(reason))
        case .file(let temporary, let response, let bytes):
            do {
                let saved = try Self.place(temporary, for: item, response: response, in: folder, pageURL: pageURL)
                update(item.url, .saved(path: saved.path, bytes: bytes))
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                update(item.url, .failed(error.localizedDescription))
            }
        }
    }

    /// Moves a finished download into the folder under a name that is not taken,
    /// and marks it as having come from the web, so macOS asks before it opens
    /// anything that could run.
    private static func place(_ temporary: URL, for item: DownloadItem, response: HTTPURLResponse, in folder: URL, pageURL: String) throws -> URL {
        let contentType = response.value(forHTTPHeaderField: "Content-Type")
        var name = item.fileName
        // A name with no ending gets one from the type the server declared.
        if (name as NSString).pathExtension.isEmpty {
            name = AssetNaming.fileName(
                for: response.url?.absoluteString ?? item.url, contentType: contentType,
                contentDisposition: response.value(forHTTPHeaderField: "Content-Disposition")
            )
        }
        let manager = FileManager.default
        let unique = AssetNaming.unique(name) { manager.fileExists(atPath: folder.appendingPathComponent($0).path) }
        let destination = folder.appendingPathComponent(unique)
        try manager.moveItem(at: temporary, to: destination)

        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
            kLSQuarantineAgentNameKey as String: "iTERMiNAL",
            kLSQuarantineDataURLKey as String: item.url,
            kLSQuarantineOriginURLKey as String: pageURL,
        ]
        var marked = destination
        try? marked.setResourceValues(values)
        return destination
    }
}

/// One download task, with the policy applied as the bytes arrive. Shared with
/// the image previews, which are the same kind of request under a smaller cap.
final class FileFetch: NSObject, URLSessionDownloadDelegate {
    enum Outcome {
        case file(URL, HTTPURLResponse, Int64)
        case failed(String)
        case cancelled
    }

    private let pageURL: String
    private let maxBytes: Int64
    private let onProgress: (Int64, Int64?) -> Void
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var exceeded = false
    private var refusedRedirect: String?
    private var keptFile: URL?
    private var moveFailure: String?
    private var lastReport = Date.distantPast

    init(pageURL: String, maxBytes: Int64, onProgress: @escaping (Int64, Int64?) -> Void) {
        self.pageURL = pageURL
        self.maxBytes = maxBytes
        self.onProgress = onProgress
    }

    func run(_ request: URLRequest, timeout: TimeInterval, resourceTimeout: TimeInterval = 3_600) async -> Outcome {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Nothing of the person's goes along with a request a page chose.
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.downloadTask(with: request)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                if Task.isCancelled {
                    task.cancel()
                    session.invalidateAndCancel()
                    self.continuation = nil
                    continuation.resume(returning: .cancelled)
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: Delegate

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        let expected: Int64? = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        if totalBytesWritten > maxBytes || (expected ?? 0) > maxBytes {
            exceeded = true
            downloadTask.cancel()
            return
        }
        // Progress is for a person's eyes: ten times a second is plenty.
        let now = Date()
        if now.timeIntervalSince(lastReport) > 0.1 {
            lastReport = now
            onProgress(totalBytesWritten, expected)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system deletes this file the moment the method returns.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("iTERMiNAL-download-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            keptFile = kept
        } catch {
            moveFailure = error.localizedDescription
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Where the redirect points is judged the way the first address was.
        guard let target = request.url?.absoluteString, DownloadPolicy.refusal(for: target, from: pageURL) == nil else {
            refusedRedirect = request.url?.absoluteString ?? "an unreadable address"
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        let outcome = outcome(for: task, error: error)
        continuation?.resume(returning: outcome)
        continuation = nil
    }

    private func outcome(for task: URLSessionTask, error: Error?) -> Outcome {
        func discard() { if let keptFile { try? FileManager.default.removeItem(at: keptFile) } }
        if exceeded {
            discard()
            return .failed("larger than the limit of \(ByteCountFormatter.string(fromByteCount: maxBytes, countStyle: .file))")
        }
        if let refusedRedirect {
            discard()
            return .failed("redirected to \(refusedRedirect), which this app won't fetch from a page")
        }
        if let error {
            discard()
            if (error as NSError).code == NSURLErrorCancelled { return .cancelled }
            return .failed(error.localizedDescription)
        }
        guard let response = task.response as? HTTPURLResponse else {
            discard()
            return .failed("no response")
        }
        guard (200..<300).contains(response.statusCode) else {
            discard()
            return .failed("the server said \(response.statusCode)")
        }
        guard let keptFile else { return .failed(moveFailure ?? "the file was not kept") }
        let attributes = try? FileManager.default.attributesOfItem(atPath: keptFile.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        return .file(keptFile, response, size)
    }
}
