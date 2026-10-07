import SwiftUI

/// A command line over the paths a site has published.
///
/// `open <address>` reads what the site itself declares — its robots.txt, the
/// sitemaps that file names, and the one page you typed — and builds a map.
/// `ls`, `cd`, `tree` and `find` then walk that map without sending anything.
/// `get` fetches one address you choose, and links in what comes back are added.
///
/// **It never guesses.** No path is requested unless the site named it or you
/// typed it: there is no probing for common directories, no wordlist, no
/// fall-back to `/sitemap.xml` when robots.txt doesn't declare one (see
/// `ExplorerPolicy`, whose rules the CI harness checks). Everything it
/// requests stays on the one site being mapped; a redirect elsewhere is shown,
/// not followed.
///
/// Not `@MainActor` as a type, for the same reason `HTTPClientModel` isn't:
/// it is held by a model that is read synchronously from nonisolated code.
/// Everything that touches published state is, individually.
final class SiteExplorerModel: ObservableObject {
    enum LineKind { case input, output, note, error }

    struct Line: Identifiable, Equatable {
        let id: Int
        let kind: LineKind
        let text: String
    }

    @Published private(set) var lines: [Line] = []
    @Published private(set) var origin: SiteOrigin?
    @Published private(set) var cwd: [String] = []
    @Published private(set) var isWorking = false
    /// The text being typed at the prompt.
    @Published var input = ""

    /// Set by the owning `HTTPClientModel`. Called for each request the
    /// person asked for by name (`get`), so it lands in the pane's history
    /// and on the API's `http.sent` event like any other. Not called for the
    /// requests `open` makes on its own — there are too many, and they are
    /// listed in the transcript instead.
    var recordRequest: ((HTTPRequestSpec, Int?, String?) -> Void)?
    /// Set by the owner: put this address in the request builder.
    var loadIntoBuilder: ((String) -> Void)?

    /// How a request is sent. The real one is `HTTPRequestExecutor`, with
    /// redirects that leave the origin not followed; a different one can be
    /// put here to drive the model without a network.
    typealias Fetcher = (HTTPRequestSpec, AppSettings) async throws -> HTTPResponseSummary
    var fetcher: Fetcher

    private var tree: SitePathTree?
    private var entryURL: URL?
    private var discoveryLog: [String] = []
    private var task: Task<Void, Never>?
    private var nextLineID = 0
    private var commandHistory: [String] = []
    private var historyCursor: Int?
    private var draft = ""

    init() {
        let executor = HTTPRequestExecutor()
        fetcher = { spec, settings in
            try await executor.execute(spec, settings: settings, sameOriginRedirectsOnly: true)
        }
    }

    var prompt: String { ExplorerFormat.prompt(origin: origin, cwd: cwd) }

    // MARK: Transcript

    func showGreetingIfNeeded() {
        guard lines.isEmpty, nextLineID == 0 else { return }
        append(.note, "Site explorer — maps what a site publishes, and lets you walk it like a directory.")
        append(.note, "Type an address to begin (example.com), or `help`. Nothing is requested until you press Return.")
    }

    private func append(_ kind: LineKind, _ text: String) {
        lines.append(Line(id: nextLineID, kind: kind, text: ExplorerFormat.sanitized(text)))
        nextLineID += 1
        let overflow = lines.count - ExplorerPolicy.maxTranscriptLines
        if overflow > 0 { lines.removeFirst(overflow) }
    }

    private func append(_ kind: LineKind, lines text: [String]) {
        for line in text { append(kind, line) }
    }

    // MARK: Prompt

    /// Return at the prompt.
    func submit(settings: AppSettings) {
        let line = input.trimmingCharacters(in: .whitespacesAndNewlines)
        input = ""
        historyCursor = nil
        guard !line.isEmpty else { return }
        if commandHistory.last != line {
            commandHistory.append(line)
            if commandHistory.count > 200 { commandHistory.removeFirst() }
        }
        append(.input, "\(prompt) \(line)")
        guard !isWorking else {
            append(.error, "still working — press Esc to cancel it first")
            return
        }
        run(ExplorerCommandParser.parse(line, siteIsOpen: tree != nil), settings: settings)
    }

    /// "Map" in the request toolbar: the address in the URL field, opened as if
    /// it had been typed at the prompt. An empty field just shows the prompt.
    func mapSite(_ address: String, settings: AppSettings) {
        showGreetingIfNeeded()
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isWorking else {
            append(.error, "still working — press Esc to cancel it first")
            return
        }
        append(.input, "\(prompt) open \(trimmed)")
        run(.open(trimmed), settings: settings)
    }

    /// ↑ at the prompt.
    func recallPrevious() {
        guard !commandHistory.isEmpty else { return }
        if historyCursor == nil {
            draft = input
            historyCursor = commandHistory.count - 1
        } else if let cursor = historyCursor, cursor > 0 {
            historyCursor = cursor - 1
        }
        if let cursor = historyCursor { input = commandHistory[cursor] }
    }

    /// ↓ at the prompt.
    func recallNext() {
        guard let cursor = historyCursor else { return }
        if cursor + 1 < commandHistory.count {
            historyCursor = cursor + 1
            input = commandHistory[cursor + 1]
        } else {
            historyCursor = nil
            input = draft
        }
    }

    /// Tab at the prompt. When several entries match, they are listed.
    func complete() {
        guard let completion = ExplorerCompleter.complete(line: input, cwd: cwd, tree: tree) else { return }
        let changed = completion.line != input
        input = completion.line
        if !completion.candidates.isEmpty, !changed {
            append(.note, completion.candidates.joined(separator: "   "))
        }
    }

    func cancel() {
        guard isWorking else { return }
        task?.cancel()
        task = nil
        isWorking = false
        append(.note, "cancelled")
    }

    // MARK: Commands

    private func run(_ command: ExplorerCommand, settings: AppSettings) {
        switch command {
        case .empty:
            break
        case .invalid(let message):
            append(.error, message)
        case .help:
            append(.note, lines: ExplorerFormat.helpLines)
        case .clear:
            lines = []
        case .open(let address):
            open(address, settings: settings)
        case .refresh:
            guard let entry = entryURL else { return needSite() }
            open(entry.absoluteString, settings: settings)
        case .pwd:
            guard let tree else { return needSite() }
            append(.output, SitePathTree.display(cwd))
            append(.note, tree.url(for: cwd))
        case .info:
            showInfo()
        case .ls(let path, let long):
            list(path: path, long: long)
        case .cd(let path):
            changeDirectory(path)
        case .tree(let path, let depth):
            showTree(path: path, depth: depth)
        case .find(let needle):
            find(needle)
        case .get(let path):
            guard let tree else { return needSite() }
            switch ExplorerTarget.resolve(argument: path, cwd: cwd, tree: tree) {
            case .error(let message): append(.error, "get: \(message)")
            case .url(let url): get(url, settings: settings)
            }
        case .request(let path):
            guard let tree else { return needSite() }
            switch ExplorerTarget.resolve(argument: path, cwd: cwd, tree: tree) {
            case .error(let message):
                append(.error, "req: \(message)")
            case .url(let url):
                loadIntoBuilder?(url)
                append(.note, "loaded \(url) into the request builder — nothing was sent")
            }
        }
    }

    private func needSite() {
        append(.error, "no site open — type an address (example.com) or `open <address>`")
    }

    private func list(path: String?, long: Bool) {
        guard let tree else { return needSite() }
        let target = path.map { tree.resolve($0, from: cwd) } ?? cwd
        guard let entries = tree.entries(at: target) else {
            append(.error, "ls: \(path ?? SitePathTree.display(target)): not on the map")
            return
        }
        if entries.isEmpty {
            append(.note, tree.isDirectory(target)
                ? "(nothing known inside — `get` a page in it and its links are added)"
                : "(a file — `get` fetches it)")
            return
        }
        append(.output, lines: ExplorerFormat.ls(entries, long: long))
    }

    private func changeDirectory(_ path: String?) {
        guard let tree else { return needSite() }
        let target = path.map { tree.resolve($0, from: cwd) } ?? []
        guard tree.contains(target) else {
            append(.error, "cd: \(path ?? ""): not on the map")
            return
        }
        guard target.isEmpty || tree.isDirectory(target) else {
            append(.error, "cd: \(path ?? ""): a file, not a directory")
            return
        }
        cwd = target
    }

    private func showTree(path: String?, depth: Int) {
        guard let tree else { return needSite() }
        let target = path.map { tree.resolve($0, from: cwd) } ?? cwd
        guard tree.contains(target) else {
            append(.error, "tree: \(path ?? ""): not on the map")
            return
        }
        let output = ExplorerFormat.tree(at: target, in: tree, maxDepth: depth, maxLines: ExplorerPolicy.maxTreeLines)
        append(.output, lines: output.isEmpty ? ["(nothing known here)"] : [SitePathTree.display(target)] + output)
    }

    private func find(_ needle: String) {
        guard let tree else { return needSite() }
        let found = tree.paths(containing: needle, limit: ExplorerPolicy.maxFindResults)
        if found.isEmpty {
            append(.note, "no known path contains “\(needle)”")
            return
        }
        append(.output, lines: found)
        if found.count >= ExplorerPolicy.maxFindResults {
            append(.note, "… stopped at \(ExplorerPolicy.maxFindResults) matches")
        }
    }

    private func showInfo() {
        guard let tree, let origin else { return needSite() }
        append(.note, "site       \(origin.root)")
        let counts = tree.counts()
        append(.note, "paths      \(tree.declaredCount) — \(counts.sitemap) from sitemaps, \(counts.robots) from robots.txt, \(counts.discovered) from links")
        for line in discoveryLog { append(.note, "read       \(line)") }
        if tree.foreignCount > 0 {
            append(.note, "left out   \(tree.foreignCount) on another host or scheme, e.g. \(tree.foreignSamples.first ?? "")")
        }
        if tree.invalidCount > 0 {
            append(.note, "left out   \(tree.invalidCount) that weren't usable paths")
        }
    }

    // MARK: open

    private func open(_ address: String, settings: AppSettings) {
        guard let url = HTTPMessage.normalizedURL(from: address), let newOrigin = SiteOrigin(url: url) else {
            append(.error, "open: that doesn't look like an address: \(address)")
            return
        }
        // Refused before the current map is thrown away, with the same rule
        // the executor applies to every request.
        if newOrigin.scheme == "http", !AssistantDestination.isLoopback(host: newOrigin.host) {
            append(.error, HTTPClientError.plainHTTPBlocked(host: newOrigin.host).errorDescription ?? "plain http is not allowed")
            return
        }
        origin = newOrigin
        tree = SitePathTree(origin: newOrigin)
        cwd = []
        entryURL = url
        discoveryLog = []
        isWorking = true
        append(.note, "mapping \(newOrigin.display) — reading what the site publishes")

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.discover(origin: newOrigin, entry: url, settings: settings)
            if !Task.isCancelled { self.isWorking = false }
        }
    }

    /// robots.txt, then the sitemaps it names, then the page that was typed.
    /// Each step is something the site published or the person entered.
    ///
    /// `mayMove` is true once: if the site's own redirect says its front door
    /// is its `www.` twin (or the reverse), the map is of that host instead —
    /// and a second such redirect is just a redirect, so two hosts that point
    /// at each other can't send this around in a circle.
    @MainActor
    private func discover(origin: SiteOrigin, entry: URL, settings: AppSettings, mayMove: Bool = true) async {
        // 1. robots.txt, from its standard place at the root.
        var declaredSitemaps: [String] = []
        let robotsURL = ExplorerPolicy.robotsURL(for: origin)
        switch await fetch(robotsURL, settings: settings) {
        case .cancelled:
            return
        case .failure(let message):
            note("robots.txt  \(message)")
        case .response(let response):
            if (200..<300).contains(response.statusCode) {
                let text = HTTPResponseFormatter.decodedText(response.body, contentType: header(response, "content-type"))
                let robots = RobotsTxtParser.parse(text)
                for path in robots.allowed { tree?.insert(path: path, provenance: .robotsAllow) }
                for path in robots.disallowed { tree?.insert(path: path, provenance: .robotsDisallow) }
                declaredSitemaps = robots.sitemaps
                var detail = "\(robots.allowed.count + robots.disallowed.count) paths, \(robots.sitemaps.count) sitemaps"
                if robots.patternsSkipped > 0 { detail += ", \(robots.patternsSkipped) patterns left out" }
                note("robots.txt  \(response.statusCode)  \(detail)")
            } else if (300..<400).contains(response.statusCode) {
                if mayMove, let moved = canonicalMove(response, from: origin, requested: robotsURL) {
                    let newEntry = move(to: moved, from: origin, entry: entry)
                    await discover(origin: moved, entry: newEntry, settings: settings, mayMove: false)
                    return
                }
                noteRedirect(response, what: "robots.txt", origin: origin, requested: robotsURL)
            } else {
                note("robots.txt  \(response.statusCode)  none published")
            }
        }
        guard !Task.isCancelled else { return }

        // 2. The sitemaps it declared — nothing else.
        await readSitemaps(declared: declaredSitemaps, origin: origin, settings: settings)
        guard !Task.isCancelled else { return }

        // 3. The page that was typed, which is how a site with no robots.txt
        //    and no sitemap still gets a start: its own links.
        if settings.httpRecordDiscoveredLinks {
            append(.note, "reading the page you entered for links")
            switch await fetch(entry.absoluteString, settings: settings) {
            case .cancelled:
                return
            case .failure(let message):
                note("page  \(message)")
            case .response(let response):
                if (200..<300).contains(response.statusCode) {
                    let added = await addPageAndLinks(from: response)
                    note("page  \(response.statusCode)  \(added) links added")
                } else if (300..<400).contains(response.statusCode) {
                    if mayMove, let moved = canonicalMove(response, from: origin, requested: entry.absoluteString) {
                        let newEntry = move(to: moved, from: origin, entry: entry)
                        await discover(origin: moved, entry: newEntry, settings: settings, mayMove: false)
                        return
                    }
                    noteRedirect(response, what: "the page", origin: origin, requested: entry.absoluteString)
                } else {
                    note("page  \(response.statusCode)")
                }
            }
        }
        guard !Task.isCancelled, let tree else { return }

        // 4. Where that leaves things.
        if tree.declaredCount == 0 {
            append(.note, "Nothing to map: this site publishes no robots.txt paths or sitemap, and the page had no links on this host.")
            append(.note, "`get <path>` fetches one address at a time, and the links in what comes back are added.")
        } else {
            let counts = tree.counts()
            append(.output, "mapped \(tree.declaredCount) paths — \(counts.sitemap) from sitemaps, \(counts.robots) from robots.txt, \(counts.discovered) from links")
            if tree.foreignCount > 0 {
                append(.note, "\(tree.foreignCount) entries on another host or scheme were left out (e.g. \(tree.foreignSamples.first ?? ""))")
            }
            append(.note, "try `ls`, `cd`, `tree`, or `help`")
        }
    }

    /// The sitemaps a site declared, level by level for an index, a few at a
    /// time. Same origin only; bounded in files, depth and entries.
    @MainActor
    private func readSitemaps(declared: [String], origin: SiteOrigin, settings: AppSettings) async {
        var queue = declared
        var seen = Set<String>()
        var filesRead = 0
        var inserted = 0
        var level = 0
        var warnedCap = false

        while !queue.isEmpty, level < ExplorerPolicy.maxSitemapDepth, !Task.isCancelled {
            let targets = ExplorerPolicy.sitemapTargets(
                declared: queue,
                origin: origin,
                alreadySeen: seen,
                budget: ExplorerPolicy.maxSitemapFiles - filesRead
            )
            if !targets.foreign.isEmpty {
                note("sitemap  \(targets.foreign.count) declared on another host or scheme — not requested")
            }
            if !targets.invalid.isEmpty { note("sitemap  \(targets.invalid.count) declared that aren't addresses — skipped") }
            if targets.overBudget > 0 {
                note("sitemap  \(targets.overBudget) more than the \(ExplorerPolicy.maxSitemapFiles)-file limit — not read")
            }
            seen.formUnion(targets.fetch)
            filesRead += targets.fetch.count

            var nextQueue: [String] = []
            var index = 0
            while index < targets.fetch.count, !Task.isCancelled {
                let chunk = Array(targets.fetch[index..<min(index + ExplorerPolicy.sitemapConcurrency, targets.fetch.count)])
                index += chunk.count
                let fetcher = self.fetcher
                let results = await withTaskGroup(of: SitemapResult.self) { group -> [SitemapResult] in
                    for url in chunk {
                        group.addTask { await SiteExplorerModel.readSitemap(url, fetcher: fetcher, settings: settings) }
                    }
                    var collected: [SitemapResult] = []
                    for await result in group { collected.append(result) }
                    return collected.sorted { $0.url < $1.url }
                }
                guard !Task.isCancelled else { return }

                for result in results {
                    let shown = String(result.url.dropFirst(origin.root.count))
                    guard let contents = result.contents else {
                        note("sitemap  \(shown)  \(result.problem ?? "not read")")
                        continue
                    }
                    for url in contents.urls {
                        if inserted >= ExplorerPolicy.maxEntries {
                            if !warnedCap {
                                note("sitemap  stopped taking paths at \(ExplorerPolicy.maxEntries) — the site lists more")
                                warnedCap = true
                            }
                            break
                        }
                        if tree?.insert(url: url, provenance: .sitemap) != nil { inserted += 1 }
                    }
                    nextQueue.append(contentsOf: contents.childSitemaps)
                    if contents.childSitemaps.isEmpty {
                        note("sitemap  \(shown)  \(contents.urls.count) paths\(contents.wasCapped ? " (file cut at its limit)" : "")")
                    } else {
                        note("sitemap  \(shown)  index of \(contents.childSitemaps.count) sitemaps")
                    }
                }
            }
            queue = nextQueue
            level += 1
        }
        if !queue.isEmpty, level >= ExplorerPolicy.maxSitemapDepth {
            note("sitemap  indexes nested deeper than \(ExplorerPolicy.maxSitemapDepth) levels — not followed")
        }
    }

    private struct SitemapResult {
        let url: String
        var contents: SitemapContents?
        var problem: String?
    }

    /// One sitemap, fetched and parsed off the main actor.
    private static func readSitemap(_ url: String, fetcher: Fetcher, settings: AppSettings) async -> SitemapResult {
        var result = SitemapResult(url: url)
        let spec = HTTPRequestSpec(method: .get, url: url, headers: [], body: nil)
        do {
            let response = try await fetcher(spec, settings)
            guard (200..<300).contains(response.statusCode) else {
                if (300..<400).contains(response.statusCode) {
                    result.problem = "redirects off this site (\(response.statusCode)) — not followed"
                } else {
                    result.problem = "\(response.statusCode)"
                }
                return result
            }
            if response.body.starts(with: [0x1F, 0x8B]) {
                result.problem = "compressed (.gz) — not read"
                return result
            }
            guard let contents = SitemapParser.parse(response.body) else {
                result.problem = "200, but not a sitemap"
                return result
            }
            result.contents = contents
        } catch is CancellationError {
            result.problem = "cancelled"
        } catch {
            result.problem = (error as? HTTPClientError)?.errorDescription ?? error.localizedDescription
        }
        return result
    }

    // MARK: get

    private func get(_ url: String, settings: AppSettings) {
        isWorking = true
        let spec = HTTPRequestSpec(method: .get, url: url, headers: [], body: nil)
        append(.note, "GET \(url)")
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            switch await self.fetch(url, settings: settings) {
            case .cancelled:
                return
            case .failure(let message):
                self.append(.error, message)
                self.recordRequest?(spec, nil, message)
            case .response(let response):
                self.recordRequest?(spec, response.statusCode, nil)
                await self.show(response, settings: settings)
            }
            if !Task.isCancelled { self.isWorking = false }
        }
    }

    /// What came back, as a CLI would print it, and the links in it.
    @MainActor
    private func show(_ response: HTTPResponseSummary, settings: AppSettings) async {
        let contentType = header(response, "content-type")
        append(.output, ExplorerFormat.responseSummary(
            status: response.statusCode,
            contentType: contentType,
            byteCount: response.body.count,
            milliseconds: Int(response.duration * 1000)
        ))
        append(.note, lines: ExplorerFormat.headerLines(response.headers))

        if (300..<400).contains(response.statusCode) {
            noteRedirect(response, what: "this address")
        } else {
            let formatted = await Task.detached(priority: .userInitiated) {
                HTTPResponseFormatter.format(response.body, contentType: contentType, maxCharacters: 20_000)
            }.value
            guard !Task.isCancelled else { return }
            append(.output, lines: ExplorerFormat.bodyPreview(
                formatted.text,
                maxLines: ExplorerPolicy.bodyPreviewLines,
                maxLength: ExplorerPolicy.maxLineLength
            ))
        }

        if settings.httpRecordDiscoveredLinks, (200..<300).contains(response.statusCode) {
            let added = await addPageAndLinks(from: response)
            if added > 0 { append(.note, "+\(added) new paths on the map") }
        }
    }

    // MARK: Enrichment

    /// A page the person fetched in the request view, added to the map when it
    /// is on the site being explored. Does nothing otherwise.
    func recordDiscovered(from response: HTTPResponseSummary, settings: AppSettings) {
        guard settings.httpRecordDiscoveredLinks, tree != nil, (200..<300).contains(response.statusCode),
              let url = URL(string: response.finalURL), origin?.contains(url) == true else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let added = await self.addPageAndLinks(from: response)
            if added > 0 { self.append(.note, "+\(added) new paths from the page you fetched in the request view") }
        }
    }

    /// The page's own address, and the links in it that are on this site.
    /// Returns how many paths were new. Links to anywhere else are dropped by
    /// the tree, not followed.
    @MainActor
    private func addPageAndLinks(from response: HTTPResponseSummary) async -> Int {
        let contentType = header(response, "content-type")
        let links = await Task.detached(priority: .userInitiated) { () -> [String] in
            let kind = HTTPResponseFormatter.classify(contentTypeHeader: contentType, sampleBytes: response.body.prefix(256))
            return ResponseLinkScanner.links(in: response.body, contentKind: kind, baseURL: response.finalURL)
        }.value
        var added = 0
        if tree?.insert(url: response.finalURL, provenance: .discovered) == .added { added += 1 }
        for link in links where tree?.insert(url: link, provenance: .discovered) == .added { added += 1 }
        return added
    }

    // MARK: Requests

    private enum FetchOutcome {
        case response(HTTPResponseSummary)
        case failure(String)
        case cancelled
    }

    /// One GET with no headers and no body, that doesn't leave the site.
    @MainActor
    private func fetch(_ url: String, settings: AppSettings) async -> FetchOutcome {
        let spec = HTTPRequestSpec(method: .get, url: url, headers: [], body: nil)
        do {
            return .response(try await fetcher(spec, settings))
        } catch is CancellationError {
            return .cancelled
        } catch let error as HTTPClientError {
            if case .cancelled = error { return .cancelled }
            return .failure(error.errorDescription ?? "request failed")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func note(_ text: String) {
        append(.note, text)
        discoveryLog.append(text)
        if discoveryLog.count > 100 { discoveryLog.removeFirst() }
    }

    private func noteRedirect(_ response: HTTPResponseSummary, what: String, origin: SiteOrigin? = nil, requested: String? = nil) {
        let location = header(response, "location")
        let target = location.map { " to \($0)" } ?? ""
        // A redirect that stays on the site isn't followed when the
        // "Follow redirects" setting is off — say that, not "off this site".
        if let origin, let requested, let location,
           let base = URL(string: requested), let url = URL(string: location, relativeTo: base)?.absoluteURL,
           origin.contains(url) {
            note("\(what)  \(response.statusCode)  redirects\(target) — not followed (Settings → HTTP Client → Follow redirects is off)")
            return
        }
        note("\(what)  \(response.statusCode)  redirects\(target) — not followed off this site. `open` that address to map it instead.")
    }

    /// Where a 3xx says the site's front door really is, when that is the
    /// same site's `www.` twin — see `ExplorerPolicy.canonicalOrigin`.
    private func canonicalMove(_ response: HTTPResponseSummary, from origin: SiteOrigin, requested: String) -> SiteOrigin? {
        guard let location = header(response, "location") else { return nil }
        return ExplorerPolicy.canonicalOrigin(for: origin, location: location, requestedURL: requested)
    }

    /// Starts the map over at the host the site sent us to, keeping the path
    /// and query that were typed. Said out loud, so it is never a surprise.
    private func move(to moved: SiteOrigin, from old: SiteOrigin, entry: URL) -> URL {
        note("\(old.display) redirects to \(moved.display) — mapping \(moved.display) instead")
        origin = moved
        tree = SitePathTree(origin: moved)
        cwd = []
        var components = URLComponents(url: entry, resolvingAgainstBaseURL: false)
        components?.host = moved.host
        let newEntry = components?.url ?? URL(string: moved.root + "/") ?? entry
        entryURL = newEntry
        return newEntry
    }

    private func header(_ response: HTTPResponseSummary, _ name: String) -> String? {
        response.headers.first { $0.name.lowercased() == name }?.value
    }
}
