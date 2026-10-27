import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

/// Which list the extract view is showing.
enum ExtractSection: Hashable, Identifiable {
    case overview, text, links, images, media, files, headings, tables, meta, structured, resources, forms
    /// One of the tables a data response (JSON, CSV, a feed) was laid out as.
    case records(Int)
    /// The addresses found in a response that is not a page.
    case addresses
    case query
    /// What a crawl of the site found, with its own lists inside.
    case crawl
    /// The pages a crawl came to, listed as the grid they are.
    case crawledPages
    /// The assistant's answer about the page, with the table inside.
    case ask
    /// The rows of that answer, listed as the grid they are.
    case askAnswer

    var id: String {
        switch self {
        case .records(let index): return "records-\(index)"
        default: return "\(self)"
        }
    }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .text: return "Text"
        case .links: return "Links"
        case .images: return "Images"
        case .media: return "Video & audio"
        case .files: return "Files"
        case .headings: return "Headings"
        case .tables: return "Tables"
        case .meta: return "Meta"
        case .structured: return "Structured data"
        case .resources: return "Scripts & styles"
        case .forms: return "Forms"
        case .records: return "Records"
        case .addresses: return "Addresses"
        case .query: return "Query"
        case .crawl: return "Crawl"
        case .crawledPages: return "Crawled pages"
        case .ask, .askAnswer: return "Answer"
        }
    }

    /// Whether its rows are best shown as a list of addresses rather than a grid.
    var isAddressList: Bool {
        switch self {
        case .links, .images, .media, .files, .resources, .addresses: return true
        default: return false
        }
    }
}

/// A batch waiting for a yes.
struct PendingDownload: Identifiable {
    let id = UUID()
    var plan: DownloadPlan
    var baseFolder: URL
    var title: String
    /// The folder the files will actually go in.
    var destination: URL
}

/// What the Extract tab knows: the response read into lists, which list is
/// showing, what is selected, the query box, and downloads.
///
/// Like `HTTPClientModel`, deliberately not `@MainActor`: it is held by a model
/// that nonisolated code reads. Everything that changes what a view shows is
/// done on the main thread.
final class PageExtractionModel: ObservableObject {
    enum Phase {
        case idle
        case working
        case ready(ResponseExtraction)
    }

    enum TextMode: String, CaseIterable, Identifiable {
        case reading = "Text"
        case markdown = "Markdown"
        var id: String { rawValue }
    }

    enum OutputChoice: String, CaseIterable, Identifiable {
        case text = "Text"
        case html = "HTML"
        case attribute = "Attribute"
        var id: String { rawValue }
    }

    @Published private(set) var phase: Phase = .idle
    @Published var section: ExtractSection = .overview
    @Published var filter = ""
    /// Ids of the selected rows of the list on screen.
    @Published var selection: Set<Int> = []
    @Published var tableIndex = 0
    @Published var textMode: TextMode = .reading

    // The query box.
    @Published var queryLanguage: QueryLanguage = .css
    @Published var queryText = ""
    @Published var queryOutput: OutputChoice = .text
    @Published var queryAttribute = "href"
    @Published var queryIgnoreCase = true
    @Published private(set) var queryResult: QueryOutcome?
    @Published private(set) var queryError: String?
    @Published private(set) var isQuerying = false

    // Downloads.
    @Published var pendingDownload: PendingDownload?
    @Published var showingDownloadProgress = false
    let downloader = AssetDownloader()

    /// Small pictures for the Images list, when the person has turned them on.
    let previews = ImagePreviewLoader()

    // Crawling.
    let crawler = SiteCrawler()
    @Published var crawlProposal: CrawlProposal?
    private var crawlWatch: AnyCancellable?

    // Asking the assistant about the page.
    let assistant = PageAssistant()
    @Published var askProposal: AskProposal?
    private var assistantWatch: AnyCancellable?

    init() {
        // The crawl changes as it goes — a page at a time — and the chips and
        // lists that show it are drawn from this model.
        crawlWatch = crawler.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        assistantWatch = assistant.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// Set by the model that owns this one: open an address in the app's own
    /// browser panel, and put one in the request builder (and send it).
    var openInBrowser: ((String) -> Void)?
    var loadRequest: ((String, Bool) -> Void)?

    private var response: HTTPResponseSummary?
    private var document: QueryDocument?
    private var generation = 0

    var isIdle: Bool {
        if case .idle = phase { return true }
        return false
    }

    var extraction: ResponseExtraction? {
        if case .ready(let value) = phase { return value }
        return nil
    }

    var pageURL: String { response?.finalURL ?? "" }

    // MARK: Reading a response

    /// A new response is in hand. The reading is done when someone looks.
    func attach(_ response: HTTPResponseSummary) {
        self.response = response
        document = nil
        generation += 1
        phase = .idle
        previews.reset()
        crawler.reset(keepingSite: URL(string: response.finalURL)?.host)
        // An answer is about the page it was asked of.
        assistant.reset()
        selection = []
        filter = ""
        tableIndex = 0
        queryResult = nil
        queryError = nil
    }

    func ensureExtracted() {
        guard case .idle = phase, let response else { return }
        phase = .working
        generation += 1
        let mine = generation
        let contentType = response.headers.first { $0.name.lowercased() == "content-type" }?.value
        Task.detached(priority: .userInitiated) { [weak self] in
            let kind = HTTPResponseFormatter.classify(contentTypeHeader: contentType, sampleBytes: response.body.prefix(256))
            let document = QueryDocument(body: response.body, contentType: contentType, url: response.finalURL)
            let result = ResponseExtractor.extract(body: response.body, contentType: contentType, url: response.finalURL, kind: kind)
            // A `let` for the hop to the main thread: a weak capture is a `var`,
            // and a closure that runs concurrently may not read one.
            guard let model = self else { return }
            await MainActor.run {
                guard model.generation == mine else { return }
                model.document = document
                model.phase = .ready(result)
                model.section = Self.firstSection(for: result)
                if let language = result.languages.first { model.queryLanguage = language }
            }
        }
    }

    private static func firstSection(for result: ResponseExtraction) -> ExtractSection {
        if result.page != nil { return .overview }
        if !result.tables.isEmpty { return .records(0) }
        if !result.links.isEmpty { return .addresses }
        return result.languages.isEmpty ? .overview : .query
    }

    // MARK: Sections

    struct Chip: Identifiable {
        let section: ExtractSection
        let title: String
        let count: Int?
        var id: String { section.id }
    }

    func chips(for result: ResponseExtraction) -> [Chip] {
        var chips: [Chip] = []
        if let page = result.page {
            chips.append(Chip(section: .overview, title: "Overview", count: nil))
            chips.append(Chip(section: .text, title: "Text", count: nil))
            let lists: [(ExtractSection, Int)] = [
                (.links, page.links.rows.count), (.images, page.images.rows.count), (.media, page.media.rows.count),
                (.files, page.files.rows.count), (.headings, page.headings.rows.count), (.tables, page.tables.count),
                (.structured, page.structured.rows.count), (.meta, page.meta.rows.count),
                (.resources, page.resources.rows.count), (.forms, page.forms.rows.count),
            ]
            for (section, count) in lists where count > 0 {
                chips.append(Chip(section: section, title: section.title, count: count))
            }
        } else {
            for (index, table) in result.tables.enumerated() {
                let name = table.caption ?? "Records"
                chips.append(Chip(section: .records(index), title: name, count: table.table.rows.count))
            }
            if !result.links.isEmpty { chips.append(Chip(section: .addresses, title: "Addresses", count: result.links.rows.count)) }
        }
        if !result.languages.isEmpty { chips.append(Chip(section: .query, title: "Query", count: nil)) }
        if !crawler.isIdle { chips.append(Chip(section: .crawl, title: "Crawl", count: crawler.results.pages.count)) }
        if !assistant.isIdle { chips.append(Chip(section: .ask, title: "Answer", count: assistant.table?.rows.count)) }
        return chips
    }

    /// The table behind a list section, if it has one.
    func table(for section: ExtractSection, in result: ResponseExtraction) -> ResultTable? {
        if let page = result.page {
            switch section {
            case .links: return page.links
            case .images: return page.images
            case .media: return page.media
            case .files: return page.files
            case .headings: return page.headings
            case .meta: return page.meta
            case .structured: return page.structured
            case .resources: return page.resources
            case .forms: return page.forms
            case .tables:
                guard !page.tables.isEmpty else { return nil }
                return page.tables[min(tableIndex, page.tables.count - 1)].table
            default: return nil
            }
        }
        switch section {
        case .records(let index): return result.tables.indices.contains(index) ? result.tables[index].table : nil
        case .addresses: return result.links
        default: return nil
        }
    }

    func select(_ section: ExtractSection) {
        guard self.section != section else { return }
        self.section = section
        selection = []
        filter = ""
        tableIndex = 0
    }

    // MARK: Row actions

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func open(_ address: String) {
        openInBrowser?(address)
    }

    /// Puts an address in the request builder; `send` also sends it. The one
    /// way from a list of a page's links to the next page — a click each.
    func request(_ address: String, send: Bool) {
        loadRequest?(address, send)
    }

    // MARK: Taking lists out

    /// A suggested name for a file made from this list: `host-links.csv`.
    func exportName(section: ExtractSection, ext: String) -> String {
        let host = URL(string: pageURL)?.host ?? "response"
        let stem = AssetNaming.sanitize("\(host)-\(section.title.lowercased().replacingOccurrences(of: " ", with: "-"))")
        return stem.isEmpty ? "export.\(ext)" : "\(stem).\(ext)"
    }

    func copyRows(_ rows: [ResultTable.Row], columns: [String], as format: ResultExport.Format) {
        copy(ResultExport.render(rows, columns: columns, as: format))
    }

    func saveRows(_ rows: [ResultTable.Row], columns: [String], as format: ResultExport.Format, section: ExtractSection) {
        saveText(ResultExport.render(rows, columns: columns, as: format), suggestedName: exportName(section: section, ext: format.fileExtension))
    }

    /// Asks where, and writes `text` there.
    func saveText(_ text: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        if let type = UTType(filenameExtension: (suggestedName as NSString).pathExtension) { panel.allowedContentTypes = [type] }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Self.presentSaveFailure(error, file: url)
        }
    }

    /// Says so when a save did not happen. One that quietly does nothing looks
    /// like one that worked, and the list or page it was of is still on screen.
    private static func presentSaveFailure(_ error: Error, file: URL) {
        let alert = NSAlert()
        alert.messageText = "\u{201C}\(file.lastPathComponent)\u{201D} could not be saved"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: Query

    var queryOutputValue: QueryOutput {
        switch queryOutput {
        case .text: return .text
        case .html: return .html
        case .attribute:
            let name = queryAttribute.trimmingCharacters(in: .whitespaces).lowercased()
            return .attribute(name.isEmpty ? "href" : name)
        }
    }

    func runQuery() {
        guard let document, !isQuerying else { return }
        let language = queryLanguage
        let text = queryText
        let output = queryOutputValue
        let ignoreCase = queryIgnoreCase
        isQuerying = true
        queryError = nil
        selection = []
        let mine = generation
        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: Result<QueryOutcome, Error> = Result {
                try QueryRunner.run(language, query: text, output: output, ignoreCase: ignoreCase, in: document)
            }
            guard let model = self else { return }
            await MainActor.run {
                guard model.generation == mine else { return }
                model.isQuerying = false
                switch outcome {
                case .success(let value):
                    model.queryResult = value
                    model.queryError = nil
                case .failure(let error):
                    model.queryResult = nil
                    model.queryError = error.localizedDescription
                }
            }
        }
    }

    // MARK: Downloads

    /// The folder files go in unless the person picks another: Downloads, in a
    /// folder of this app's own, so a batch is never mixed into their files.
    static func defaultDownloadFolder(preferred: String) -> URL {
        let trimmed = preferred.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true) }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        return downloads.appendingPathComponent("iTERMiNAL", isDirectory: true)
    }

    /// A folder per site inside the chosen one, so two pages' `logo.png` never
    /// meet.
    static func destination(base: URL, pageURL: String) -> URL {
        let host = AssetNaming.sanitize(URL(string: pageURL)?.host ?? "")
        return base.appendingPathComponent(host.isEmpty ? "downloads" : host, isDirectory: true)
    }

    /// Plans a batch from addresses and asks first. Nothing is fetched until
    /// the person agrees to what the sheet shows: the files, the sites, the
    /// folder.
    func prepareDownload(urls: [String], title: String, settings: AppSettings) {
        let base = Self.defaultDownloadFolder(preferred: settings.httpDownloadFolder)
        let destination = Self.destination(base: base, pageURL: pageURL)
        let taken = Set((try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? [])
        let plan = DownloadPlan.make(urls: urls, pageURL: pageURL, taken: taken)
        pendingDownload = PendingDownload(plan: plan, baseFolder: base, title: title, destination: destination)
    }

    func chooseDownloadFolder(settings: AppSettings) {
        guard var pending = pendingDownload else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = pending.baseFolder
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.httpDownloadFolder = url.path
        pending.baseFolder = url
        pending.destination = Self.destination(base: url, pageURL: pageURL)
        let taken = Set((try? FileManager.default.contentsOfDirectory(atPath: pending.destination.path)) ?? [])
        pending.plan = DownloadPlan.make(urls: pending.plan.items.map(\.url), pageURL: pageURL, taken: taken)
        pendingDownload = pending
    }

    func confirmDownload(settings: AppSettings) {
        guard let pending = pendingDownload else { return }
        pendingDownload = nil
        downloader.start(
            items: pending.plan.items, pageURL: pageURL, folder: pending.destination,
            maxBytes: Int64(settings.httpMaxDownloadMB) * 1_000_000, timeout: settings.httpRequestTimeout
        )
        showingDownloadProgress = true
    }

    // MARK: Crawling

    /// Asks what a crawl from this page would do. Nothing is requested until the
    /// person has seen it and said yes.
    func proposeCrawl(settings: AppSettings) {
        guard let page = extraction?.page, !crawler.isActive else { return }
        let limits = CrawlLimits(
            maxPages: settings.httpCrawlPages, maxDepth: settings.httpCrawlDepth, delay: settings.httpCrawlDelay
        ).clamped()
        guard var frontier = CrawlFrontier(start: pageURL, limits: limits) else {
            crawlProposal = CrawlProposal(
                startURL: pageURL, host: URL(string: pageURL)?.host ?? "", limits: limits, directory: "/", candidates: 0,
                refusal: "This page's address can't be crawled from."
            )
            return
        }
        frontier.offer(page.links.rows.compactMap(\.url), foundOn: frontier.start, depth: 0)
        crawlProposal = CrawlProposal(
            startURL: frontier.start, host: URL(string: frontier.start)?.host ?? "", limits: limits,
            directory: CrawlFrontier.directory(of: frontier.start), candidates: frontier.pendingCount,
            refusal: DownloadPolicy.refusal(for: frontier.start, from: frontier.start)
        )
    }

    func confirmCrawl(limits: CrawlLimits, settings: AppSettings) {
        guard let page = extraction?.page, let response else { return }
        crawlProposal = nil
        let chosen = limits.clamped()
        settings.httpCrawlPages = chosen.maxPages
        settings.httpCrawlDepth = chosen.maxDepth
        settings.httpCrawlDelay = chosen.delay
        crawler.start(
            page: page, pageURL: pageURL, status: response.statusCode, bytes: response.body.count,
            milliseconds: Int(response.duration * 1_000), limits: chosen, settings: settings
        )
        select(.crawl)
    }

    // MARK: Asking the assistant

    /// Opens the sheet that says what would be sent and where. Nothing is sent
    /// until the person presses Ask there.
    func proposeAsk(settings: AppSettings, question: String? = nil) {
        guard let page = extraction?.page, assistant.phase != .asking else { return }
        // The addresses the page itself names: an answer's cells are addresses to
        // act on only if they are among these.
        var known = Set<String>()
        for table in [page.links, page.images, page.media, page.files, page.feeds, page.resources] {
            for row in table.rows { if let url = row.url { known.insert(url) } }
        }
        askProposal = AskProposal(page: page, known: known, question: question ?? assistant.asked)
    }

    /// Sends what the sheet showed: built again here from the same page and the
    /// same settings, so it is the same text.
    func confirmAsk(question: String) {
        guard let proposal = askProposal,
              let request = AIExtractionRequest.make(question: question, page: proposal.page, baseURL: AppSettings.shared.assistantBaseURL)
        else { return }
        askProposal = nil
        assistant.ask(request, known: proposal.known)
        select(.ask)
    }

    // MARK: Saving the response itself

    func saveBody(_ response: HTTPResponseSummary) {
        let contentType = response.headers.first { $0.name.lowercased() == "content-type" }?.value
        let disposition = response.headers.first { $0.name.lowercased() == "content-disposition" }?.value
        let panel = NSSavePanel()
        panel.nameFieldStringValue = AssetNaming.fileName(for: response.finalURL, contentType: contentType, contentDisposition: disposition)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try response.body.write(to: url, options: .atomic)
        } catch {
            Self.presentSaveFailure(error, file: url)
        }
    }
}
