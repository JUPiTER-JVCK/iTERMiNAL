import SwiftUI
import WebKit

/// Owns one WKWebView and its navigation state. Lives either in the sliding
/// side panel or as a leaf pane inside a tab's split layout.
final class BrowserModel: NSObject, ObservableObject {
    @Published var urlText: String
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var pageTitle = ""

    let webView: WKWebView

    init(initialURL: String? = nil) {
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        urlText = initialURL ?? AppSettings.shared.browserHomepage
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        loadCurrentText()
    }

    func loadCurrentText() {
        guard let url = Self.url(fromUserInput: urlText) else { return }
        urlText = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    /// Bare domains get https:// prefixed; anything that doesn't look like a
    /// URL becomes a web search.
    static func url(fromUserInput text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return URL(string: trimmed)
        }
        if !trimmed.contains(" "), trimmed.contains(".") {
            return URL(string: "https://" + trimmed)
        }
        let query = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        return URL(string: "https://www.google.com/search?q=" + query)
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func goHome() {
        urlText = AppSettings.shared.browserHomepage
        loadCurrentText()
    }

    private func syncNavigationState() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        pageTitle = webView.title ?? ""
    }
}

extension BrowserModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        syncNavigationState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        if let url = webView.url {
            urlText = url.absoluteString
        }
        syncNavigationState()
        WorkspaceStore.shared.scheduleSave()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        syncNavigationState()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        syncNavigationState()
    }
}

private struct WebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct BrowserPaneView: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: model.goBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.plain)
                .disabled(!model.canGoBack)

                Button(action: model.goForward) {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.plain)
                .disabled(!model.canGoForward)

                Button(action: model.reload) {
                    Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
                }
                .buttonStyle(.plain)

                TextField("Search or enter address", text: $model.urlText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit { model.loadCurrentText() }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(theme.surface))
                    .overlay(Capsule().strokeBorder(theme.surfaceBorder))

                Button(action: model.goHome) {
                    Image(systemName: "house")
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            WebViewRepresentable(webView: model.webView)
        }
        .background(theme.background)
    }
}
