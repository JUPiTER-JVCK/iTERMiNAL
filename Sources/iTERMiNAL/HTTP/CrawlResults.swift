import Foundation

/// One page a crawl came to: what was asked for, what came back, and what was
/// found on it.
struct CrawledPage: Equatable, Identifiable {
    let id: Int
    /// Where the page was in the end, after any redirect within the site.
    var url: String
    /// The HTTP status, or 0 when nothing was requested or nothing came back.
    var status: Int
    /// Why there is no more to say, in a few words: the page was not asked for,
    /// was not a web page, went to another site, or the request failed.
    var note: String
    var title: String
    var depth: Int
    /// The page whose link led here; empty for the page the crawl began with.
    var foundOn: String
    var links: Int
    var images: Int
    var bytes: Int
    var milliseconds: Int
}

/// Everything a crawl found, kept as the lists the Extract tab already shows —
/// each address once, with the first page it was found on.
struct CrawlResults: Equatable {
    static let pageColumns = ["Page", "Status", "Title", "Depth", "Links", "Images", "Size", "Found on"]
    static let linkColumns = ["Text", "URL", "Site", "Rel", "×", "Found on"]
    static let imageColumns = ["URL", "Alt", "Size", "Where", "Found on"]
    static let mediaColumns = ["URL", "Kind", "Type", "Watch page", "Found on"]
    static let fileColumns = ["Name", "URL", "Type", "Link text", "Found on"]
    /// Rows kept per list; past this the list says it was cut.
    static let maxRows = 5_000

    private(set) var pages: [CrawledPage] = []
    private(set) var links = ResultTable(columns: CrawlResults.linkColumns)
    private(set) var images = ResultTable(columns: CrawlResults.imageColumns)
    private(set) var media = ResultTable(columns: CrawlResults.mediaColumns)
    private(set) var files = ResultTable(columns: CrawlResults.fileColumns)
    private var linkIndex: [String: Int] = [:]
    private var imageIndex: [String: Int] = [:]
    private var mediaIndex: [String: Int] = [:]
    private var fileIndex: [String: Int] = [:]

    /// Pages that came back with a status.
    var fetchedCount: Int { pages.filter { $0.status > 0 }.count }
    /// Addresses that were left alone, because robots.txt asks it or the page
    /// was not one.
    var skippedCount: Int { pages.filter { $0.status == 0 }.count }
    var isEmpty: Bool { pages.isEmpty }

    /// Adds a page, and the lists it came with. `extracted` is nil for a page
    /// that was not read: not HTML, an error, not asked for.
    mutating func record(
        url: String, status: Int, note: String, depth: Int, foundOn: String,
        bytes: Int, milliseconds: Int, extracted: ExtractedPage?
    ) {
        let page = CrawledPage(
            id: pages.count, url: url, status: status, note: note,
            title: String((extracted?.title ?? "").prefix(PageExtractor.maxCell)), depth: depth, foundOn: foundOn,
            links: extracted?.links.rows.count ?? 0, images: extracted?.images.rows.count ?? 0,
            bytes: bytes, milliseconds: milliseconds
        )
        pages.append(page)
        guard let extracted else { return }

        for row in extracted.links.rows {
            guard let address = row.url else { continue }
            if let existing = linkIndex[address] {
                // How often it came up, across the pages that linked to it.
                let before = Int(links.rows[existing].cells[4]) ?? 1
                links.rows[existing].cells[4] = String(before + (Int(row.cells[cell: 4]) ?? 1))
            } else {
                Self.add(row, from: url, to: &links, index: &linkIndex, key: address)
            }
        }
        for row in extracted.images.rows {
            guard let address = row.url, imageIndex[address] == nil else { continue }
            Self.add(row, from: url, to: &images, index: &imageIndex, key: address)
        }
        for row in extracted.media.rows {
            guard let address = row.url, mediaIndex[address] == nil else { continue }
            Self.add(row, from: url, to: &media, index: &mediaIndex, key: address)
        }
        for row in extracted.files.rows {
            guard let address = row.url, fileIndex[address] == nil else { continue }
            Self.add(row, from: url, to: &files, index: &fileIndex, key: address)
        }
    }

    private static func add(
        _ row: ResultTable.Row, from page: String, to table: inout ResultTable,
        index: inout [String: Int], key: String
    ) {
        guard table.rows.count < Self.maxRows else {
            table.truncated = true
            return
        }
        index[key] = table.rows.count
        table.append(row.cells + [page], url: row.url, canDownload: row.canDownload)
    }

    /// The pages, as a table: one row each, in the order they were reached.
    func pagesTable() -> ResultTable {
        var table = ResultTable(columns: Self.pageColumns)
        for page in pages {
            let status: String
            if page.status > 0 {
                status = page.note.isEmpty ? "\(page.status)" : "\(page.status) · \(page.note)"
            } else {
                status = page.note
            }
            table.append(
                [
                    page.url, status, page.title, "\(page.depth)",
                    page.links == 0 ? "" : "\(page.links)",
                    page.images == 0 ? "" : "\(page.images)",
                    page.bytes > 0 ? ByteCountFormatter.string(fromByteCount: Int64(page.bytes), countStyle: .file) : "",
                    page.foundOn,
                ],
                url: page.url, canDownload: false
            )
        }
        return table
    }
}

private extension Array where Element == String {
    subscript(cell index: Int) -> String {
        indices.contains(index) ? self[index] : ""
    }
}
