import SwiftUI
import AppKit

/// One list from a response — links, images, a table — with a filter, a way to
/// pick rows, and what can be done with them: copy, save, open, fetch, download.
struct ExtractResults: View {
    @ObservedObject var extraction: PageExtractionModel
    let table: ResultTable
    let section: ExtractSection
    let theme: Theme

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let rows = table.filtered(by: extraction.filter)
        VStack(spacing: 0) {
            if let note = noteLine {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if section == .images, settings.httpImagePreviews {
                ImagePreviewNote(loader: extraction.previews, theme: theme)
            }
            if rows.isEmpty {
                Text(table.rows.isEmpty ? "Nothing here." : "Nothing matches the filter.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            } else if section.isAddressList {
                addressList(rows)
            } else {
                grid(rows)
            }
            FadedDivider()
            footer(rows)
        }
    }

    private var noteLine: String? {
        var parts: [String] = []
        if table.truncated { parts.append("More was found than is listed.") }
        switch section {
        case .media:
            if table.rows.contains(where: { !$0.canDownload }) {
                parts.append("Embedded players (YouTube, Vimeo…) are listed with their page; they can't be saved as files from here.")
            }
        case .links:
            parts.append("Every link on the page. The ones that point to files can be saved, and are in Files too.")
        case .crawledPages:
            parts.append("The pages the crawl came to, in the order it reached them. One that robots.txt asks to be left alone is listed and was not fetched.")
        default:
            break
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: Address lists

    private struct RowSummary {
        var title: String
        var subtitle: String?
        var badges: [String]
    }

    /// A crawl's lists end in the page each address was found on; it is said in
    /// a badge, as a path.
    private func summary(for row: ResultTable.Row) -> RowSummary {
        var result = baseSummary(for: row)
        if table.columns.last == "Found on", let foundOn = row.cells.last, !foundOn.isEmpty {
            let path = URLComponents(string: foundOn).map { $0.percentEncodedPath.isEmpty ? "/" : $0.percentEncodedPath } ?? foundOn
            result.badges.append("on " + path)
        }
        return result
    }

    private func baseSummary(for row: ResultTable.Row) -> RowSummary {
        let cells = row.cells
        func cell(_ index: Int) -> String { index < cells.count ? cells[index] : "" }
        func fileName(_ url: String) -> String {
            let name = AssetNaming.lastPathComponent(of: url)
            return name.isEmpty ? url : name
        }
        switch section {
        case .links:
            let text = cell(0)
            return RowSummary(
                title: text.isEmpty ? cell(1) : text, subtitle: text.isEmpty ? nil : cell(1),
                badges: [cell(2), cell(3), cell(4) == "1" ? "" : "×\(cell(4))"]
            )
        case .images:
            return RowSummary(title: cell(1).isEmpty ? fileName(cell(0)) : cell(1), subtitle: cell(0), badges: [cell(2), cell(3)])
        case .media:
            return RowSummary(title: cell(3).isEmpty ? fileName(cell(0)) : cell(2), subtitle: cell(3).isEmpty ? cell(0) : cell(3), badges: [cell(1), cell(3).isEmpty ? cell(2) : ""])
        case .files:
            return RowSummary(title: cell(0), subtitle: cell(1), badges: [cell(2)])
        case .resources:
            return RowSummary(title: fileName(cell(0)), subtitle: cell(0), badges: [cell(1), cell(2)])
        default:
            return RowSummary(title: cell(0), subtitle: nil, badges: [cell(1)])
        }
    }

    private func addressList(_ rows: [ResultTable.Row]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    addressRow(row)
                }
            }
        }
    }

    private func addressRow(_ row: ResultTable.Row) -> some View {
        let text = summary(for: row)
        let selectable = row.canDownload && row.url != nil
        let isSelected = extraction.selection.contains(row.id)
        return HStack(alignment: .top, spacing: 8) {
            if selectable {
                Button {
                    toggle(row.id)
                } label: {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .foregroundStyle(isSelected ? settings.accentColor : theme.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSelected ? "Deselect" : "Select")
            }
            if section == .images, settings.httpImagePreviews, row.canDownload, let address = row.url {
                ImagePreviewThumb(loader: extraction.previews, address: address, theme: theme)
                    .onAppear { extraction.previews.request(address, pageURL: extraction.pageURL) }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(text.title)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle = text.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            HStack(spacing: 4) {
                ForEach(text.badges.filter { !$0.isEmpty }, id: \.self) { badge in
                    Text(badge)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(theme.surface))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isSelected ? settings.accentColor.opacity(0.12) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if selectable { toggle(row.id) }
        }
        .contextMenu { rowMenu(row) }
    }

    private func toggle(_ id: Int) {
        if extraction.selection.contains(id) { extraction.selection.remove(id) } else { extraction.selection.insert(id) }
    }

    // MARK: Grid

    private func widths(for rows: [ResultTable.Row]) -> [CGFloat] {
        table.columns.indices.map { column in
            let longest = rows.prefix(200).reduce(table.columns[column].count) { max($0, min($1.cells[column].count, 60)) }
            return CGFloat(min(max(longest, 5), 60)) * 7 + 18
        }
    }

    private func grid(_ rows: [ResultTable.Row]) -> some View {
        let widths = widths(for: rows)
        // A scroll view that goes both ways centers what is smaller than it, so
        // a short table floated in the middle of the pane. Held nearly as big as
        // the pane and pinned to its top left, it starts where a table does. A
        // little short of it, because a scroller takes room from the content and
        // a table exactly the pane's size would then have something to scroll.
        return GeometryReader { pane in
            ScrollView([.horizontal, .vertical]) {
                gridBody(rows, widths: widths)
                    .frame(
                        minWidth: max(0, pane.size.width - 20), minHeight: max(0, pane.size.height - 20),
                        alignment: .topLeading
                    )
            }
        }
    }

    private func gridBody(_ rows: [ResultTable.Row], widths: [CGFloat]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
            Section {
                ForEach(rows) { row in
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(table.columns.indices, id: \.self) { column in
                            Text(row.cells[column])
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(theme.textPrimary)
                                .lineLimit(3)
                                .textSelection(.enabled)
                                .frame(width: widths[column], alignment: .leading)
                                .padding(.vertical, 3)
                        }
                    }
                    .padding(.horizontal, 10)
                    .contentShape(Rectangle())
                    .contextMenu { rowMenu(row) }
                }
            } header: {
                HStack(spacing: 0) {
                    ForEach(table.columns.indices, id: \.self) { column in
                        Text(table.columns[column])
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: widths[column], alignment: .leading)
                            .padding(.vertical, 4)
                    }
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.background)
            }
        }
    }

    // MARK: Row menu

    @ViewBuilder
    private func rowMenu(_ row: ResultTable.Row) -> some View {
        if let url = row.url {
            Button("Copy Address") { extraction.copy(url) }
            if url.hasPrefix("http://") || url.hasPrefix("https://") {
                Button("Open in Browser Panel") { extraction.open(url) }
                Button("Load as Request") { extraction.request(url, send: false) }
                Button("Fetch (GET)") { extraction.request(url, send: true) }
            }
            if row.canDownload {
                Button("Download…") {
                    extraction.prepareDownload(urls: [url], title: section.title, settings: settings)
                }
            }
            Divider()
        }
        Button("Copy Row") { extraction.copy(row.cells.joined(separator: "\t")) }
    }

    // MARK: Footer

    private func footer(_ rows: [ResultTable.Row]) -> some View {
        let selected = rows.filter { extraction.selection.contains($0.id) }
        let downloadable = rows.filter { $0.canDownload && $0.url != nil }
        let chosen = selected.isEmpty ? rows : selected
        return HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textSecondary)
                TextField("Filter", text: $extraction.filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                if !extraction.filter.isEmpty {
                    Button { extraction.filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.surface))
            .frame(maxWidth: 170)

            Text(rows.count == table.rows.count ? "\(rows.count)" : "\(rows.count) of \(table.rows.count)")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
                .monospacedDigit()

            if section == .images {
                Toggle(isOn: $settings.httpImagePreviews) {
                    Label("Previews", systemImage: "photo")
                        .font(.system(size: 11, weight: .medium))
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Show a small picture beside each image. Each one is fetched from the site that hosts it, so this is off until you turn it on.")
            }

            Spacer(minLength: 0)

            if !downloadable.isEmpty {
                Button(selected.count == downloadable.count ? "None" : "All") {
                    if selected.count == downloadable.count {
                        extraction.selection = []
                    } else {
                        extraction.selection = Set(downloadable.map(\.id))
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textPrimary)
                .help("Select or clear every file that can be saved")

                Menu {
                    Button("Selected (\(selected.filter { $0.canDownload && $0.url != nil }.count))…") {
                        extraction.prepareDownload(
                            urls: ResultTable.downloadURLs(in: selected), title: section.title, settings: settings
                        )
                    }
                    .disabled(selected.filter { $0.canDownload && $0.url != nil }.isEmpty)
                    Button("All shown (\(downloadable.count))…") {
                        extraction.prepareDownload(
                            urls: ResultTable.downloadURLs(in: downloadable), title: section.title, settings: settings
                        )
                    }
                } label: {
                    // What pressing it will take, once something is picked.
                    let picked = selected.filter { $0.canDownload && $0.url != nil }.count
                    Label(picked > 0 ? "Download \(picked)" : "Download", systemImage: "arrow.down.circle")
                        .font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Menu {
                Section(selected.isEmpty ? "Copy \(rows.count) rows as" : "Copy \(selected.count) selected as") {
                    ForEach(ResultExport.Format.allCases) { format in
                        Button(format.label) { extraction.copyRows(chosen, columns: table.columns, as: format) }
                    }
                }
                Section("Save as…") {
                    ForEach(ResultExport.Format.allCases) { format in
                        Button(format.label) {
                            extraction.saveRows(chosen, columns: table.columns, as: format, section: section)
                        }
                    }
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.system(size: 11, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(rows.isEmpty)
        }
        .foregroundStyle(theme.textPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
