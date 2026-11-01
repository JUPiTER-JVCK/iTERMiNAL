import AppKit
import Quartz

/// Shows one file in the system's Quick Look panel — the same one Finder
/// opens with Space. The panel previews in a separate process, as it does
/// for Finder, so a file that is odd to render does not reach this app.
///
/// The data source is set on the panel directly rather than through the
/// responder chain: the file list is a SwiftUI `List`, which has no AppKit
/// controller to put in the chain.
final class QuickLookPresenter: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookPresenter()

    private var url: URL?
    /// A folder made for one fetched file, removed when the panel closes or
    /// another file replaces it. Nil for a file that is shown where it is.
    private var scratchFolder: URL?
    private var closeObserver: NSObjectProtocol?

    /// Whether `path` is a plain file. A pipe or a device is not shown: reading
    /// one would wait.
    static func isRegularFile(atPath path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    /// - Parameters:
    ///   - url: The file to show.
    ///   - scratchFolder: A folder holding only `url`, to delete afterwards.
    func show(_ url: URL, scratchFolder: URL? = nil) {
        discardScratch()
        guard let panel = QLPreviewPanel.shared() else {
            if let scratchFolder { try? FileManager.default.removeItem(at: scratchFolder) }
            return
        }
        self.url = url
        self.scratchFolder = scratchFolder
        panel.dataSource = self
        panel.reloadData()
        if closeObserver == nil {
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                self?.panelClosed()
            }
        }
        panel.makeKeyAndOrderFront(nil)
    }

    private func panelClosed() {
        url = nil
        discardScratch()
    }

    private func discardScratch() {
        if let scratchFolder { try? FileManager.default.removeItem(at: scratchFolder) }
        scratchFolder = nil
    }

    // MARK: QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        url == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard let url else { return nil }
        return url as NSURL
    }
}
