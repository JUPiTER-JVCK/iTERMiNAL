import SwiftUI
import AppKit

/// Which list of a crawl is showing.
enum CrawlList: String, CaseIterable, Identifiable {
    case pages = "Pages"
    case links = "Links"
    case images = "Images"
    case media = "Video & audio"
    case files = "Files"

    var id: String { rawValue }

    /// The section whose rows these are, so they list the way that section's do.
    var section: ExtractSection {
        switch self {
        case .pages: return .crawledPages
        case .links: return .links
        case .images: return .images
        case .media: return .media
        case .files: return .files
        }
    }
}

/// What a crawl is about to do, shown for a yes before it does any of it.
struct CrawlProposal: Identifiable {
    let id = UUID()
    var startURL: String
    var host: String
    var limits: CrawlLimits
    /// The start page's folder, for "stay in this section".
    var directory: String
    /// Links on the page that are on this site and would join the queue.
    var candidates: Int
    /// Why this site cannot be crawled, when it cannot.
    var refusal: String?
}

/// A crawl of one site: the page in hand, the pages it links to on the same
/// site, and so on, up to limits a person chose and saw first.
///
/// It follows only addresses the pages it reads *declare* — no guessing, no
/// probing for common paths — and asks very little of the site: robots.txt is
/// read first and its rules for this crawler obeyed (and its `Crawl-delay`, if
/// longer than the person's own), one page at a time with a wait between, only
/// web pages (a response that says it is anything else is not downloaded), at
/// most a couple of megabytes of any one, nothing remembered from one request to
/// the next — no cookies, no login — and a redirect off the site is not
/// followed. What the rules are is in `RobotsRules`, `CrawlFrontier` and
/// `CrawlPolicy`, which a check runs without a network.
///
/// Like the models it sits beside, not `@MainActor`: it is held by one that
/// nonisolated code reads. Everything a view reads is changed on the main thread.
final class SiteCrawler: ObservableObject {
    enum Phase: Equatable {
        case idle
        case readingRobots
        case running
        case finished(String)
        case stopped(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var results = CrawlResults()
    /// Addresses queued and not yet fetched.
    @Published private(set) var waiting = 0
    /// The address being fetched right now.
    @Published private(set) var current: String?
    @Published private(set) var site = ""
    @Published private(set) var limits = CrawlLimits()
    /// What robots.txt asked, in a line.
    @Published private(set) var robotsNote = ""
    @Published var list: CrawlList = .pages

    private var task: Task<Void, Never>?
    private var generation = 0

    var isActive: Bool {
        switch phase {
        case .readingRobots, .running: return true
        default: return false
        }
    }

    var isIdle: Bool { phase == .idle }

    func table(for list: CrawlList) -> ResultTable {
        switch list {
        case .pages: return results.pagesTable()
        case .links: return results.links
        case .images: return results.images
        case .media: return results.media
        case .files: return results.files
        }
    }

    func count(for list: CrawlList) -> Int {
        switch list {
        case .pages: return results.pages.count
        case .links: return results.links.rows.count
        case .images: return results.images.rows.count
        case .media: return results.media.rows.count
        case .files: return results.files.rows.count
        }
    }

    // MARK: Running

    /// Begins a crawl from the page in hand: `page` is what was read from it,
    /// and the three numbers are what its own response said.
    func start(
        page: ExtractedPage, pageURL: String, status: Int, bytes: Int, milliseconds: Int,
        limits requested: CrawlLimits, settings: AppSettings
    ) {
        guard !isActive, var frontier = CrawlFrontier(start: pageURL, limits: requested) else { return }
        generation += 1
        let mine = generation
        limits = frontier.limits
        site = URL(string: frontier.start)?.host ?? ""
        results = CrawlResults()
        robotsNote = ""
        current = nil
        list = .pages
        phase = .readingRobots

        // The page already in hand is the first page of the crawl, and what it
        // links to is where the queue starts. It is not fetched again.
        results.record(
            url: frontier.start, status: status, note: "", depth: 0, foundOn: "",
            bytes: bytes, milliseconds: milliseconds, extracted: page
        )
        frontier.offer(page.links.rows.compactMap(\.url), foundOn: frontier.start, depth: 0)
        waiting = frontier.pendingCount

        let initial = frontier
        task = Task { [weak self] in
            await self?.run(initial, settings: settings, generation: mine)
        }
    }

    /// Ends the crawl after the request in flight; what was found stays.
    func stop() {
        guard isActive else { return }
        task?.cancel()
    }

    /// Forgets the crawl — unless it is of `host`, in which case it is kept: a
    /// page of the crawled site, fetched from a row of its results, is the
    /// reason to look at the results, not to lose them.
    func reset(keepingSite host: String?) {
        if let host, !site.isEmpty, host.lowercased() == site.lowercased() { return }
        generation += 1
        task?.cancel()
        task = nil
        phase = .idle
        results = CrawlResults()
        waiting = 0
        current = nil
        site = ""
        robotsNote = ""
    }

    private func run(_ initial: CrawlFrontier, settings: AppSettings, generation mine: Int) async {
        var frontier = initial
        let limits = frontier.limits
        let executor = HTTPRequestExecutor()
        let userAgent = CrawlPolicy.userAgent(version: Self.appVersion)
        let origin = Self.origin(of: frontier.start)
        let began = Date()

        // The site's rules come first, before any page is asked for.
        var rules = RobotsRules.allowAll
        do {
            let response = try await executor.execute(
                Self.spec(origin + "/robots.txt", userAgent: userAgent, accept: "text/plain,*/*;q=0.1"),
                settings: settings, sameOriginRedirectsOnly: true, maxResponseBytes: CrawlPolicy.maxRobotsBytes
            )
            if let problem = CrawlPolicy.robotsProblem(status: response.statusCode) {
                await finish(.failed("Nothing was crawled: \(problem)."), generation: mine)
                return
            }
            if (200..<300).contains(response.statusCode) {
                let type = response.headers.first { $0.name.lowercased() == "content-type" }?.value
                rules = RobotsRules.parse(
                    HTTPResponseFormatter.decodedText(response.body, contentType: type), agent: CrawlPolicy.agentToken
                )
            }
        } catch HTTPClientError.cancelled {
            await finish(.stopped("Stopped before it began."), generation: mine)
            return
        } catch {
            await finish(.failed("Nothing was crawled: robots.txt couldn't be read. \(error.localizedDescription)"), generation: mine)
            return
        }
        let note = Self.describe(rules)
        let wait = limits.wait(siteDelay: rules.crawlDelay)
        await publish(generation: mine) { crawler in
            crawler.robotsNote = note
            crawler.phase = .running
        }

        var blocked = 0
        var blockedRows = 0
        while !Task.isCancelled {
            guard let entry = frontier.next() else { break }

            // A page robots.txt asks to leave alone is listed and not fetched,
            // and does not use up a place in the limit.
            let path = RobotsRules.requestPath(of: entry.url) ?? "/"
            if !rules.allows(path: path) {
                frontier.refund()
                blocked += 1
                if blockedRows < CrawlPolicy.maxSkippedRows {
                    blockedRows += 1
                    await publish(generation: mine) { crawler in
                        crawler.results.record(
                            url: entry.url, status: 0, note: "robots.txt asks that it is left alone", depth: entry.depth,
                            foundOn: entry.foundOn, bytes: 0, milliseconds: 0, extracted: nil
                        )
                    }
                }
                continue
            }

            do {
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            } catch {
                break
            }
            let upcoming = frontier.pendingCount
            await publish(generation: mine) { crawler in
                crawler.current = entry.url
                crawler.waiting = upcoming
            }

            let asked = Date()
            var outcome = PageOutcome(url: entry.url)
            do {
                let response = try await executor.execute(
                    Self.spec(entry.url, userAgent: userAgent, accept: CrawlPolicy.accept),
                    settings: settings, sameOriginRedirectsOnly: true, maxResponseBytes: CrawlPolicy.maxPageBytes,
                    acceptResponse: { CrawlPolicy.isPage(contentType: $0.value(forHTTPHeaderField: "Content-Type")) }
                )
                outcome.status = response.statusCode
                outcome.bytes = response.body.count
                // A redirect within the site ends somewhere else: that is the
                // page, and it is not fetched a second time.
                outcome.url = CrawlFrontier.normalize(response.finalURL) ?? entry.url
                if outcome.url != entry.url { frontier.markSeen(outcome.url) }
                let type = response.headers.first { $0.name.lowercased() == "content-type" }?.value
                switch response.statusCode {
                case 200..<300:
                    if !CrawlPolicy.isPage(contentType: type) {
                        outcome.note = "not a web page (\(Self.mimeType(type)))"
                    } else if !frontier.accepts(outcome.url) || !rules.allows(path: RobotsRules.requestPath(of: outcome.url) ?? "/") {
                        outcome.note = "redirected outside what this crawl may read"
                    } else {
                        let text = HTTPResponseFormatter.decodedText(response.body, contentType: type)
                        let page = PageExtractor.extract(html: text, pageURL: outcome.url)
                        outcome.extracted = page
                        frontier.offer(page.links.rows.compactMap(\.url), foundOn: outcome.url, depth: entry.depth)
                    }
                case 300..<400:
                    let location = response.headers.first { $0.name.lowercased() == "location" }?.value ?? ""
                    outcome.note = location.isEmpty ? "redirects elsewhere, not followed" : "redirects to \(Self.shortLocation(location)), not followed"
                default:
                    break
                }
            } catch HTTPClientError.cancelled {
                break
            } catch {
                outcome.note = error.localizedDescription
            }

            let elapsed = Int(Date().timeIntervalSince(asked) * 1_000)
            let remaining = frontier.pendingCount
            let finished = outcome
            await publish(generation: mine) { crawler in
                crawler.results.record(
                    url: finished.url, status: finished.status, note: finished.note, depth: entry.depth,
                    foundOn: entry.foundOn, bytes: finished.bytes, milliseconds: elapsed, extracted: finished.extracted
                )
                crawler.waiting = remaining
                crawler.current = nil
            }
        }

        let cancelled = Task.isCancelled
        let leftover = frontier.pendingCount
        let leftAlone = blocked
        let seconds = Int(Date().timeIntervalSince(began).rounded())
        await publish(generation: mine) { crawler in
            crawler.current = nil
            crawler.waiting = leftover
            let fetched = crawler.results.fetchedCount
            var summary = "\(fetched) page\(fetched == 1 ? "" : "s") in \(seconds) s"
            if leftAlone > 0 { summary += " · \(leftAlone) left alone because of robots.txt" }
            if cancelled {
                crawler.phase = .stopped("Stopped. " + summary + ".")
            } else if leftover > 0 {
                crawler.phase = .finished("Reached the limit of \(limits.maxPages) pages: " + summary + "; \(leftover) more were waiting.")
            } else {
                crawler.phase = .finished("Done: " + summary + ". There were no more pages to follow.")
            }
        }
    }

    private struct PageOutcome {
        var url: String
        var status = 0
        var note = ""
        var bytes = 0
        var extracted: ExtractedPage?
    }

    // MARK: Pieces

    private func publish(generation mine: Int, _ change: @escaping @MainActor (SiteCrawler) -> Void) async {
        await MainActor.run {
            guard self.generation == mine else { return }
            change(self)
        }
    }

    private func finish(_ phase: Phase, generation mine: Int) async {
        await publish(generation: mine) { crawler in
            crawler.phase = phase
            crawler.current = nil
        }
    }

    private static func spec(_ url: String, userAgent: String, accept: String) -> HTTPRequestSpec {
        HTTPRequestSpec(
            method: .get, url: url,
            headers: [
                HTTPHeaderField(name: "User-Agent", value: userAgent),
                HTTPHeaderField(name: "Accept", value: accept),
            ],
            body: nil
        )
    }

    private static func origin(of address: String) -> String {
        guard let parts = URLComponents(string: address), let scheme = parts.scheme, let host = parts.host else { return address }
        return scheme + "://" + host + (parts.port.map { ":\($0)" } ?? "")
    }

    private static var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }

    private static func mimeType(_ contentType: String?) -> String {
        contentType?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? "no type"
    }

    private static func shortLocation(_ location: String) -> String {
        URL(string: location)?.host ?? location
    }

    /// What robots.txt asked of this crawler, in a line.
    static func describe(_ rules: RobotsRules) -> String {
        var parts: [String] = []
        if rules.rules.isEmpty {
            parts.append("robots.txt asks nothing of this crawler")
        } else {
            let disallowed = rules.rules.filter { !$0.allow }.count
            parts.append("robots.txt: \(disallowed) disallowed pattern\(disallowed == 1 ? "" : "s")")
        }
        if let delay = rules.crawlDelay {
            parts.append("asks for \(delay.formatted()) s between requests")
        }
        return parts.joined(separator: ", ")
    }
}
