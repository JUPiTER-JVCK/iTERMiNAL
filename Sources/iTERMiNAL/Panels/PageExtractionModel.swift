import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Which list the extract view is showing.
enum ExtractSection: Hashable, Identifiable {
    case overview, text, links, images, media, files, headings, tables, meta, structured, resources, forms
    /// One of the tables a data response (JSON, CSV, a feed) was laid out as.
    case records(Int)
    /// The addresses found in a response that is not a page.
    case addresses
    case query

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
            await MainActor.run {
                guard let self, self.generation == mine else { return }
                self.document = document
                self.phase = .ready(result)
                self.section = Self.firstSection(for: result)
                if let language = result.languages.first { self.queryLanguage = language }
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
        try? text.write(to: url, atomically: true, encoding: .utf8)
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
            await MainActor.run {
                guard let self, self.generation == mine else { return }
                self.isQuerying = false
                switch outcome {
                case .success(let value):
                    self.queryResult = value
                    self.queryError = nil
                case .failure(let error):
                    self.queryResult = nil
                    self.queryError = error.localizedDescription
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

    // MARK: Saving the response itself

    func saveBody(_ response: HTTPResponseSummary) {
        let contentType = response.headers.first { $0.name.lowercased() == "content-type" }?.value
        let disposition = response.headers.first { $0.name.lowercased() == "content-disposition" }?.value
        let panel = NSSavePanel()
        panel.nameFieldStringValue = AssetNaming.fileName(for: response.finalURL, contentType: contentType, contentDisposition: disposition)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? response.body.write(to: url, options: .atomic)
    }
}
