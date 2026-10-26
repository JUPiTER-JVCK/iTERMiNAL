import SwiftUI
import AppKit

/// Shown before a crawl asks anything of anyone: which site, how far, how
/// fast, and what the crawl will and will not do. Nothing is requested until
/// the person presses Start.
struct CrawlConfirmSheet: View {
    @ObservedObject var extraction: PageExtractionModel
    let proposal: CrawlProposal

    @EnvironmentObject private var settings: AppSettings
    @State private var pages: Int
    @State private var depth: Int
    @State private var delay: Double
    @State private var sectionOnly = false

    init(extraction: PageExtractionModel, proposal: CrawlProposal) {
        self.extraction = extraction
        self.proposal = proposal
        // A saved value that is not one the pickers offer is shown as the
        // nearest one that is, so the pickers never show nothing.
        func nearest<T: BinaryFloatingPoint>(_ choices: [T], to value: T) -> T {
            choices.min { abs($0 - value) < abs($1 - value) } ?? value
        }
        _pages = State(initialValue: CrawlLimits.pageChoices.min { abs($0 - proposal.limits.maxPages) < abs($1 - proposal.limits.maxPages) } ?? 25)
        _depth = State(initialValue: CrawlLimits.depthChoices.min { abs($0 - proposal.limits.maxDepth) < abs($1 - proposal.limits.maxDepth) } ?? 2)
        _delay = State(initialValue: nearest(CrawlLimits.delayChoices, to: proposal.limits.delay))
    }

    private var limits: CrawlLimits {
        CrawlLimits(maxPages: pages, maxDepth: depth, delay: delay, stayUnder: sectionOnly ? proposal.directory : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Crawl \(proposal.host)")
                .font(.headline)

            if let refusal = proposal.refusal {
                Text(refusal)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    fact("From", proposal.startURL, monospaced: true)
                    fact("Stays on", "\(proposal.host) only. A link to another site, or to another subdomain such as www., is listed and not followed.")
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        label("Pages")
                        Picker("Pages", selection: $pages) {
                            ForEach(CrawlLimits.pageChoices, id: \.self) { Text("up to \($0)").tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Text("counting this one")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        label("Depth")
                        Picker("Depth", selection: $depth) {
                            ForEach(CrawlLimits.depthChoices, id: \.self) { value in
                                Text(value == 1 ? "1 — the pages this one links to" : "\(value) links from here").tag(value)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        label("Wait")
                        Picker("Wait", selection: $delay) {
                            ForEach(CrawlLimits.delayChoices, id: \.self) { value in
                                Text(Self.delayLabel(value)).tag(value)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Text("between requests")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        label("Scope")
                        Toggle("Only pages under \(proposal.directory)", isOn: $sectionOnly)
                            .disabled(proposal.directory == "/")
                    }
                }

                Text("\(proposal.candidates) link\(proposal.candidates == 1 ? "" : "s") on this page lead to pages on this site. At most \(pages) pages at one request every \(Self.delayLabel(delay)) is about \(Self.duration(Double(pages - 1) * delay)), plus the time the site takes to answer.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 4) {
                    bullet("The site's robots.txt is read first. Pages it asks crawlers to leave alone are listed and not fetched, and a Crawl-delay longer than the wait above is waited out.")
                    bullet("One page at a time. Only web pages: anything the server says is a picture, a file or a download is not taken, and no page is read past 2 MB.")
                    bullet("Only addresses the pages themselves link to. Nothing is guessed, and a link to another site is listed, not followed.")
                    bullet("Each request stands alone: no cookies, no login, nothing carried from one to the next. It says who is asking — iTERMiNAL, with this app's address.")
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { extraction.crawlProposal = nil }
                    .keyboardShortcut(.cancelAction)
                if proposal.refusal == nil {
                    Button("Start Crawl") { extraction.confirmCrawl(limits: limits, settings: settings) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(16)
        .frame(width: 500)
        .tint(settings.accentColor)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 56, alignment: .trailing)
    }

    private func fact(_ name: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            label(name)
            Text(value)
                .font(.system(size: monospaced ? 11 : 12, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("•").foregroundStyle(.secondary)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    static func delayLabel(_ seconds: Double) -> String {
        seconds < 1 ? "\(Int(seconds * 1_000)) ms" : "\(Int(seconds)) s"
    }

    private static func duration(_ seconds: Double) -> String {
        seconds < 90 ? "\(Int(seconds.rounded(.up))) seconds" : "\(Int((seconds / 60).rounded(.up))) minutes"
    }
}

/// What a crawl is doing and has found: where it is, the lists, and Stop.
struct CrawlView: View {
    @ObservedObject var extraction: PageExtractionModel
    @ObservedObject var crawler: SiteCrawler
    let theme: Theme

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            status
            FadedDivider()
            listRow
            ExtractResults(
                extraction: extraction, table: crawler.table(for: crawler.list), section: crawler.list.section, theme: theme,
                noteOverride: note(for: crawler.list)
            )
            .id(crawler.list)
        }
    }

    // MARK: Where it is

    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                switch crawler.phase {
                case .idle:
                    EmptyView()
                case .readingRobots:
                    ProgressView().controlSize(.small)
                    Text("Reading robots.txt of \(crawler.site)…")
                case .running:
                    ProgressView().controlSize(.small)
                    Text("Crawling \(crawler.site): \(crawler.results.fetchedCount) of up to \(crawler.limits.maxPages) pages, \(crawler.waiting) waiting")
                case .finished(let text):
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(text)
                case .stopped(let text):
                    Image(systemName: "stop.circle").foregroundStyle(theme.textSecondary)
                    Text(text)
                case .failed(let text):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(text)
                }
                Spacer(minLength: 6)
                if crawler.isActive {
                    Button("Stop") { crawler.stop() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                } else {
                    Button("New Crawl…") { extraction.proposeCrawl(settings: settings) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                    Button("Clear") { crawler.reset(keepingSite: nil) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(theme.textPrimary)

            if crawler.isActive, let current = crawler.current {
                Text(current)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !crawler.robotsNote.isEmpty {
                Text(crawler.robotsNote)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: The lists

    /// What a list of the crawl says about itself; nil for the ones whose usual
    /// note is right.
    private func note(for list: CrawlList) -> String? {
        switch list {
        case .pages, .media:
            return nil
        case .links:
            return "Every link on the crawled pages, each once, with the first page it was found on and how often it came up. The ones that point to files can be saved, and are in Files too."
        case .images:
            return "Every image on the crawled pages, each once, with the first page it was found on."
        case .files:
            return "The files the crawled pages link to, each once, with the first page it was found on."
        }
    }

    private var listRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(CrawlList.allCases) { list in
                    let selected = crawler.list == list
                    Button {
                        guard crawler.list != list else { return }
                        crawler.list = list
                        extraction.selection = []
                        extraction.filter = ""
                    } label: {
                        HStack(spacing: 4) {
                            Text(list.rawValue)
                            Text("\(crawler.count(for: list))")
                                .foregroundStyle(theme.textSecondary)
                                .monospacedDigit()
                        }
                        .font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .foregroundStyle(theme.textPrimary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(selected ? settings.accentColor.opacity(0.24) : theme.surface))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}
