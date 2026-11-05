import Foundation

/// The registries' delegation files on this Mac: where they are kept, the
/// download that refreshes them, and the searchable table built from them.
/// What the files say and how they are searched is `RIRDelegationTable`'s.
///
/// The download asks each registry for its whole published file — nothing
/// about any address the Lookup tab is used for — and is made only when the
/// person presses Download in Settings → HTTP Client.
///
/// Not `@MainActor`, like the other models here: the work is done off the main
/// thread and what it found is published on it.
final class RIRDelegationStore: ObservableObject {
    static let shared = RIRDelegationStore()

    /// How many of the five files are on this Mac.
    @Published private(set) var fileCount = 0
    /// When the oldest of them was downloaded.
    @Published private(set) var oldestDownload: Date?
    /// Changes whenever the files do, so answers read from older ones are
    /// not reused.
    @Published private(set) var stamp = ""
    @Published private(set) var isDownloading = false
    @Published private(set) var progress: String?
    @Published private(set) var problem: String?

    let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("iTERMiNAL", isDirectory: true)
            .appendingPathComponent("RIR", isDirectory: true)
    }()

    private init() {
        rescan()
    }

    func fileURL(_ registry: RIRRegistry) -> URL {
        directory.appendingPathComponent(registry.fileName)
    }

    /// Reads which files are here and when each was written.
    func rescan() {
        var count = 0
        var oldest: Date?
        var parts: [String] = []
        for registry in RIRRegistry.allCases {
            let path = fileURL(registry).path
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let modified = attributes[.modificationDate] as? Date else { continue }
            count += 1
            oldest = min(oldest ?? modified, modified)
            parts.append("\(registry.rawValue)@\(modified.timeIntervalSince1970)")
        }
        fileCount = count
        oldestDownload = oldest
        stamp = parts.joined(separator: ",")
    }

    // MARK: Download

    /// Fetches all five files again, one after another. A file is put in
    /// place only once it has been read and found to be that registry's
    /// delegation file, so a failed or odd download leaves the old one.
    func download() {
        guard !isDownloading else { return }
        isDownloading = true
        problem = nil
        progress = "Starting…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var failed: [String] = []
            do {
                try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            } catch {
                DispatchQueue.main.async {
                    self.isDownloading = false
                    self.progress = nil
                    self.problem = "Couldn't make the folder for the files: \(error.localizedDescription)"
                }
                return
            }
            for (index, registry) in RIRRegistry.allCases.enumerated() {
                DispatchQueue.main.async {
                    self.progress = "\(registry.title) (\(index + 1) of \(RIRRegistry.allCases.count))…"
                }
                if let message = self.fetch(registry) {
                    failed.append("\(registry.title): \(message)")
                }
            }
            RIRTableCache.invalidate()
            let problem = failed.isEmpty ? nil : failed.joined(separator: "\n")
            DispatchQueue.main.async {
                self.isDownloading = false
                self.progress = nil
                self.problem = problem
                self.rescan()
            }
        }
    }

    /// Deletes the files.
    func remove() {
        guard !isDownloading else { return }
        try? FileManager.default.removeItem(at: directory)
        RIRTableCache.invalidate()
        problem = nil
        rescan()
    }

    /// Downloads one file and puts it in place. Nil when that worked,
    /// otherwise what went wrong.
    private func fetch(_ registry: RIRRegistry) -> String? {
        var request = URLRequest(url: registry.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("iTERMiNAL", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: HTTPSRedirectsOnly(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var downloaded: URL?
        var response: HTTPURLResponse?
        var transportError: String?
        let done = DispatchSemaphore(value: 0)
        let staging = directory.appendingPathComponent(".\(registry.fileName).\(UUID().uuidString)")
        session.downloadTask(with: request) { location, urlResponse, error in
            response = urlResponse as? HTTPURLResponse
            transportError = error?.localizedDescription
            // The system deletes `location` when this returns, so it is moved
            // aside before anything else.
            if let location, (try? FileManager.default.moveItem(at: location, to: staging)) != nil {
                downloaded = staging
            }
            done.signal()
        }.resume()
        done.wait()
        defer { if let downloaded { try? FileManager.default.removeItem(at: downloaded) } }

        if let transportError { return transportError }
        guard let response, response.statusCode == 200 else {
            return "the registry answered HTTP \(response?.statusCode ?? 0)."
        }
        // Redirects are followed only while they stay on https.
        guard response.url?.scheme == "https" else { return "the download was redirected off https." }
        guard let downloaded,
              let size = (try? FileManager.default.attributesOfItem(atPath: downloaded.path))?[.size] as? Int,
              size <= RIRDelegationTable.maxFileBytes,
              let data = try? Data(contentsOf: downloaded, options: .alwaysMapped) else {
            return "the file was missing or larger than \(RIRDelegationTable.maxFileBytes / 1_048_576) MB."
        }
        guard Self.looksLikeDelegationFile(data, from: registry) else {
            return "what came back isn't that registry's delegation file."
        }
        let target = fileURL(registry)
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: downloaded)
            } else {
                try FileManager.default.moveItem(at: downloaded, to: target)
            }
        } catch {
            return "couldn't save it: \(error.localizedDescription)"
        }
        return nil
    }

    /// The file starts with its version line (`2.3|ripencc|…`) and has at
    /// least one block this app can use.
    static func looksLikeDelegationFile(_ data: Data, from registry: RIRRegistry) -> Bool {
        let head = String(decoding: data.prefix(4096), as: UTF8.self)
        let firstLine = head.split(whereSeparator: \.isNewline)
            .first { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let fields = firstLine?.split(separator: "|", omittingEmptySubsequences: false),
              fields.count >= 2, fields[0].first?.isNumber == true,
              fields[1].lowercased() == registry.rawValue else { return false }
        var table = RIRDelegationTable()
        table.add(data)
        return !table.isEmpty
    }

    // MARK: Reading

    /// The table built from whichever files are here, built once per change
    /// to them. Call off the main thread: the first build reads every file.
    func table() -> RIRDelegationTable {
        RIRTableCache.table(store: self)
    }
}

/// Follows a registry's redirect — they move their files between mirrors —
/// only to another https address.
private final class HTTPSRedirectsOnly: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
}

/// Keeps the built table between lookups, so the files are read once.
private enum RIRTableCache {
    private static let lock = NSLock()
    private static var current: (stamp: String, table: RIRDelegationTable)?

    static func invalidate() {
        lock.lock()
        current = nil
        lock.unlock()
    }

    static func table(store: RIRDelegationStore) -> RIRDelegationTable {
        lock.lock()
        defer { lock.unlock() }
        var stamp: [String] = []
        var present: [URL] = []
        for registry in RIRRegistry.allCases {
            let url = store.fileURL(registry)
            guard let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date else { continue }
            stamp.append("\(registry.rawValue)@\(modified.timeIntervalSince1970)")
            present.append(url)
        }
        let key = stamp.joined(separator: ",")
        if let current, current.stamp == key { return current.table }
        let files = present.compactMap { try? Data(contentsOf: $0, options: .alwaysMapped) }
        let table = RIRDelegationTable(files: files)
        current = (key, table)
        return table
    }
}
