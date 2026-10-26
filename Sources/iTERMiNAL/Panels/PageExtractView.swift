import SwiftUI
import AppKit

/// The Extract tab: a response read into lists you can filter, copy, save and
/// download from — links, images, video and audio, files, headings, tables,
/// metadata, readable text — and a box for asking it your own questions.
///
/// Everything shown was in the one response already fetched. Nothing here
/// requests anything on its own: the only requests are the ones a person starts
/// — Fetch on a row, or Download after seeing what and from where.
struct PageExtractView: View {
    @ObservedObject var extraction: PageExtractionModel
    let response: HTTPResponseSummary

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        VStack(spacing: 0) {
            switch extraction.phase {
            case .idle, .working:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading the response…")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            case .ready(let result):
                header(result, theme: theme)
                chipRow(result, theme: theme)
                FadedDivider()
                sectionBody(result, theme: theme)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { extraction.ensureExtracted() }
        // A new response while this tab is open — a link fetched from a row.
        .onChange(of: extraction.isIdle) { _, idle in
            if idle { extraction.ensureExtracted() }
        }
        .sheet(item: $extraction.pendingDownload) { pending in
            DownloadConfirmSheet(extraction: extraction, pending: pending)
        }
        .sheet(isPresented: $extraction.showingDownloadProgress) {
            DownloadProgressSheet(downloader: extraction.downloader, extraction: extraction)
        }
        .sheet(item: $extraction.crawlProposal) { proposal in
            CrawlConfirmSheet(extraction: extraction, proposal: proposal)
        }
        .sheet(item: $extraction.askProposal) { proposal in
            AskAssistantSheet(extraction: extraction, proposal: proposal)
        }
    }

    // MARK: Header and chips

    private func header(_ result: ResponseExtraction, theme: Theme) -> some View {
        HStack(spacing: 8) {
            Text(result.kindLabel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Text(ByteCountFormatter.string(fromByteCount: Int64(result.byteCount), countStyle: .file))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
            Spacer(minLength: 0)
            // A crawl is a thing to ask for, in its own words, not a side effect
            // of looking at a list: it opens a sheet that says what it will do.
            if result.page != nil {
                Button {
                    extraction.proposeAsk(settings: settings)
                } label: {
                    Label("Ask…", systemImage: "sparkles")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.textPrimary)
                .disabled(extraction.assistant.phase == .asking)
                .help("Ask the AI assistant to pull something out of this page's text, after showing you what would be sent and where")
                Button {
                    extraction.proposeCrawl(settings: settings)
                } label: {
                    Label("Crawl…", systemImage: "arrow.triangle.branch")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.textPrimary)
                .disabled(extraction.crawler.isActive)
                .help("Follow this page's links to the other pages of the site, a few at a time, after showing you what it will do")
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private func chipRow(_ result: ResponseExtraction, theme: Theme) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(extraction.chips(for: result)) { chip in
                    let selected = extraction.section == chip.section
                    Button {
                        extraction.select(chip.section)
                    } label: {
                        HStack(spacing: 4) {
                            Text(chip.title)
                            if let count = chip.count {
                                Text("\(count)")
                                    .foregroundStyle(theme.textSecondary)
                                    .monospacedDigit()
                            }
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

    // MARK: Body of a section

    @ViewBuilder
    private func sectionBody(_ result: ResponseExtraction, theme: Theme) -> some View {
        switch extraction.section {
        case .overview:
            ExtractOverview(extraction: extraction, result: result, theme: theme)
        case .text:
            ExtractText(extraction: extraction, result: result, theme: theme)
        case .query:
            ExtractQuery(extraction: extraction, theme: theme)
        case .crawl:
            CrawlView(extraction: extraction, crawler: extraction.crawler, theme: theme)
        case .ask:
            AskResultView(extraction: extraction, assistant: extraction.assistant, theme: theme)
        case .tables:
            if let page = result.page, !page.tables.isEmpty {
                VStack(spacing: 0) {
                    if page.tables.count > 1 {
                        HStack {
                            Picker("Table", selection: $extraction.tableIndex) {
                                ForEach(Array(page.tables.enumerated()), id: \.offset) { index, table in
                                    Text("\(index + 1). \(table.caption ?? "\(table.table.columns.count) columns") — \(table.table.rows.count) rows").tag(index)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                    }
                    if let table = extraction.table(for: .tables, in: result) {
                        ExtractResults(extraction: extraction, table: table, section: .tables, theme: theme)
                            .id(extraction.tableIndex)
                    }
                }
            }
        case .structured:
            VStack(spacing: 0) {
                if let table = extraction.table(for: .structured, in: result) {
                    ExtractResults(extraction: extraction, table: table, section: .structured, theme: theme)
                }
                if let page = result.page, !page.structuredJSON.isEmpty {
                    FadedDivider()
                    DisclosureGroup("JSON-LD (\(page.structuredJSON.count))") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(page.structuredJSON.enumerated()), id: \.offset) { _, json in
                                    Text(json)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(theme.textPrimary)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(8)
                        }
                        .frame(maxHeight: 220)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
        default:
            if let table = extraction.table(for: extraction.section, in: result) {
                ExtractResults(extraction: extraction, table: table, section: extraction.section, theme: theme)
                    .id(extraction.section.id)
            } else {
                Text("Nothing here.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: Overview

/// What the page says about itself, and a way into each list.
private struct ExtractOverview: View {
    @ObservedObject var extraction: PageExtractionModel
    let result: ResponseExtraction
    let theme: Theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let note = result.note {
                    Label(note, systemImage: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let page = result.page {
                    if let title = page.title { fact("Title", title) }
                    if let summary = page.summary { fact("Description", summary) }
                    if let site = page.siteName { fact("Site", site) }
                    if let author = page.author { fact("Author", author) }
                    if let published = page.published { fact("Published", published) }
                    if let language = page.language { fact("Language", language) }
                    if let charset = page.charset { fact("Encoding", charset) }
                    if let canonical = page.canonicalURL { fact("Canonical", canonical, address: true) }
                    if let image = page.previewImage { fact("Preview image", image, address: true) }
                    ForEach(page.feeds.rows) { row in
                        fact("Feed", row.cells[0].isEmpty ? row.cells[1] : "\(row.cells[0]) — \(row.cells[1])", address: false, url: row.cells[1])
                    }
                    FadedDivider().padding(.vertical, 2)
                    Text("On this page")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                    FlowLayout(spacing: 6) {
                        ForEach(extraction.chips(for: result).filter { $0.count != nil }) { chip in
                            Button { extraction.select(chip.section) } label: {
                                Text("\(chip.count ?? 0) \(chip.title.lowercased())")
                                    .font(.system(size: 11))
                                    .foregroundStyle(theme.textPrimary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(theme.surface))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    ForEach(footnotes(for: page), id: \.self) { line in
                        Text(line)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Pick a list above, or ask a question in Query.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func footnotes(for page: ExtractedPage) -> [String] {
        var lines: [String] = []
        if page.anchorCount > 0 { lines.append("\(page.anchorCount) links to places further down this page are not listed.") }
        if page.inlineDataCount > 0 { lines.append("\(page.inlineDataCount) images written into the markup (data: addresses) are not listed.") }
        lines.append("Read from the response above — nothing was requested. Scripts that draw the page are not run, so what they add is not here.")
        return lines
    }

    private func fact(_ name: String, _ value: String, address: Bool = false, url: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 84, alignment: .trailing)
            Text(value)
                .font(.system(size: 12, design: address ? .monospaced : .default))
                .foregroundStyle(theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if address || url != nil {
                Button { extraction.copy(url ?? value) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.textSecondary)
                    .help("Copy the address")
            }
        }
    }
}

// MARK: Text

/// The reading part of the page, plain or as Markdown.
private struct ExtractText: View {
    @ObservedObject var extraction: PageExtractionModel
    let result: ResponseExtraction
    let theme: Theme
    @EnvironmentObject private var settings: AppSettings
    @State private var copied = false

    var body: some View {
        let page = result.page
        let text = extraction.textMode == .reading ? (page?.text ?? "") : (page?.markdown ?? "")
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Format", selection: $extraction.textMode) {
                    ForEach(PageExtractionModel.TextMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if let source = page?.textSource, !text.isEmpty {
                    Text("from <\(source)>")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer(minLength: 0)
                if !text.isEmpty {
                    Text("\(text.count) characters")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                    Button(copied ? "Copied" : "Copy") {
                        extraction.copy(text)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    Button("Save…") {
                        let ext = extraction.textMode == .reading ? "txt" : "md"
                        extraction.saveText(text, suggestedName: extraction.exportName(section: .text, ext: ext))
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            FadedDivider()
            if text.isEmpty {
                Text("No reading in this page. If it is drawn by scripts, the words are not in what the server sent — and this reads only that.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    Text(text)
                        .font(.system(size: 12, design: extraction.textMode == .markdown ? .monospaced : .default))
                        .foregroundStyle(theme.textPrimary)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
            }
        }
    }
}
