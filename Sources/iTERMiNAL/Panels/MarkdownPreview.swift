import SwiftUI
import AppKit
import WebKit

/// A Markdown file, rendered and ready to show.
struct MarkdownDocument: Identifiable {
    let id = UUID()
    let title: String
    let html: String
}

enum MarkdownPreview {
    /// The most of a file that is read, in bytes. A README is a few kilobytes.
    static let maxBytes = 5_000_000

    /// The text of a plain file, or nil when it is not one, is bigger than
    /// `maxBytes`, or cannot be read. A pipe or a device is not read: it would
    /// wait.
    static func readText(at url: URL) -> String? {
        var info = stat()
        guard stat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= off_t(maxBytes),
              let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The preview sheet: the document in a web view that cannot run scripts, load
/// anything, or go anywhere but out to the default browser.
struct MarkdownPreviewSheet: View {
    let document: MarkdownDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(document.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            MarkdownWebView(html: document.html)
        }
        .frame(minWidth: 640, idealWidth: 780, minHeight: 480, idealHeight: 660)
    }
}

/// Three things keep a Markdown file from doing anything: the converter writes
/// only tags it knows (`MarkdownHTML`), the page's own policy forbids scripts
/// and every kind of fetch, and this view has scripting off and approves no
/// navigation of its own — a link to the web opens in the default browser
/// instead, and a link within the page scrolls.
private struct MarkdownWebView: NSViewRepresentable {
    let html: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.loadHTMLString(html, baseURL: nil)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if navigationAction.navigationType == .linkActivated {
                if url.absoluteString.hasPrefix("about:blank#") {
                    // A link within the page.
                    decisionHandler(.allow)
                    return
                }
                if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }
            // The page loading itself, and nothing else.
            decisionHandler(url.absoluteString == "about:blank" ? .allow : .cancel)
        }
    }
}
