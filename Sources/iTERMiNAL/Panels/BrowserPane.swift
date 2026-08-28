import SwiftUI
import WebKit
import AppKit

enum BrowserError: LocalizedError {
    case invalidURL(String)
    case elementNotFound(String)
    case timedOut(String)
    case snapshotFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL(let text): return "Not a usable URL: \(text)"
        case .elementNotFound(let selector): return "No element matched \(selector)"
        case .timedOut(let what): return "Timed out waiting for \(what)"
        case .snapshotFailed: return "Could not capture the page"
        }
    }
}

/// Owns one WKWebView and its navigation state. Lives either in the sliding
/// side panel or as a leaf pane inside a tab's split layout.
///
/// Beyond the visible chrome, every action is also exposed as a scriptable
/// method so the local API can drive the page — navigate, click, fill,
/// read text, screenshot — which is what makes this useful for testing a
/// web UI from an agent or a script.
final class BrowserModel: NSObject, ObservableObject, Identifiable {
    let id = UUID()

    @Published var urlText: String
    /// False until this tab has actually loaded something, so a fresh tab can
    /// show an empty state instead of a blank web view.
    @Published private(set) var hasNavigated = false
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var pageTitle = ""

    let webView: WKWebView

    /// Completions waiting for the current navigation to settle.
    private var navigationCompletions: [(Result<String, Error>) -> Void] = []

    /// `autoLoad: false` produces an empty tab — used by the panel's "new
    /// tab", which should land on the empty state rather than the homepage.
    init(initialURL: String? = nil, autoLoad: Bool = true) {
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        urlText = initialURL ?? (autoLoad ? AppSettings.shared.browserHomepage : "")
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        if autoLoad || initialURL != nil {
            loadCurrentText()
        }
    }

    func loadCurrentText() {
        guard let url = Self.url(fromUserInput: urlText) else { return }
        urlText = url.absoluteString
        hasNavigated = true
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
        if trimmed.hasPrefix("localhost") || trimmed.hasPrefix("127.0.0.1") {
            return URL(string: "http://" + trimmed)
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

    /// Cancels an in-flight load — what the toolbar's stop affordance needs.
    func stop() {
        webView.stopLoading()
        finishNavigation(.success(webView.url?.absoluteString ?? urlText))
    }
    func goHome() {
        urlText = AppSettings.shared.browserHomepage
        loadCurrentText()
    }

    private func syncNavigationState() {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        pageTitle = webView.title ?? ""
    }

    private func finishNavigation(_ result: Result<String, Error>) {
        isLoading = false
        syncNavigationState()
        let waiting = navigationCompletions
        navigationCompletions.removeAll()
        waiting.forEach { $0(result) }
    }

    // MARK: - Scripting surface

    /// Loads `text` (URL or search) and calls back once the page settles.
    func navigate(to text: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let url = Self.url(fromUserInput: text) else {
            completion(.failure(BrowserError.invalidURL(text)))
            return
        }
        urlText = url.absoluteString
        hasNavigated = true
        navigationCompletions.append(completion)
        isLoading = true
        webView.load(URLRequest(url: url))
    }

    func evaluate(_ javaScript: String, completion: @escaping (Result<String, Error>) -> Void) {
        webView.evaluateJavaScript(javaScript) { value, error in
            if let error {
                completion(.failure(error))
            } else {
                completion(.success(Self.describe(value)))
            }
        }
    }

    func click(selector: String, completion: @escaping (Result<String, Error>) -> Void) {
        let script = """
        (function() {
            const el = document.querySelector(\(Self.jsString(selector)));
            if (!el) { return "__not_found__"; }
            el.click();
            return "clicked";
        })()
        """
        evaluate(script) { result in
            completion(Self.mapNotFound(result, selector: selector))
        }
    }

    /// Sets a field's value and fires input/change so reactive frameworks
    /// (React, Vue) notice the edit rather than silently ignoring it.
    func fill(selector: String, value: String, completion: @escaping (Result<String, Error>) -> Void) {
        let script = """
        (function() {
            const el = document.querySelector(\(Self.jsString(selector)));
            if (!el) { return "__not_found__"; }
            const setter = Object.getOwnPropertyDescriptor(el.__proto__, "value");
            if (setter && setter.set) {
                setter.set.call(el, \(Self.jsString(value)));
            } else {
                el.value = \(Self.jsString(value));
            }
            el.dispatchEvent(new Event("input", { bubbles: true }));
            el.dispatchEvent(new Event("change", { bubbles: true }));
            return "filled";
        })()
        """
        evaluate(script) { result in
            completion(Self.mapNotFound(result, selector: selector))
        }
    }

    /// Visible page text, or the text of one element when a selector is given.
    func text(selector: String?, completion: @escaping (Result<String, Error>) -> Void) {
        let script: String
        if let selector, !selector.isEmpty {
            script = """
            (function() {
                const el = document.querySelector(\(Self.jsString(selector)));
                return el ? el.innerText : "__not_found__";
            })()
            """
        } else {
            script = "document.body ? document.body.innerText : \"\""
        }
        evaluate(script) { result in
            completion(Self.mapNotFound(result, selector: selector ?? "body"))
        }
    }

    func html(completion: @escaping (Result<String, Error>) -> Void) {
        evaluate("document.documentElement.outerHTML") { completion($0) }
    }

    /// Polls until the selector matches or the timeout elapses.
    func waitForSelector(_ selector: String, timeout: TimeInterval, completion: @escaping (Result<String, Error>) -> Void) {
        let deadline = Date().addingTimeInterval(max(0.1, timeout))

        func poll() {
            let script = "document.querySelector(\(Self.jsString(selector))) ? \"found\" : \"__not_found__\""
            evaluate(script) { result in
                switch result {
                case .success(let value) where value == "found":
                    completion(.success("found"))
                case .failure(let error) where Date() >= deadline:
                    completion(.failure(error))
                default:
                    if Date() >= deadline {
                        completion(.failure(BrowserError.timedOut(selector)))
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { poll() }
                    }
                }
            }
        }
        poll()
    }

    /// Captures the visible page as PNG data.
    func screenshot(completion: @escaping (Result<Data, Error>) -> Void) {
        let config = WKSnapshotConfiguration()
        webView.takeSnapshot(with: config) { image, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let image,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                completion(.failure(BrowserError.snapshotFailed))
                return
            }
            completion(.success(png))
        }
    }

    // MARK: - Helpers

    private static func mapNotFound(_ result: Result<String, Error>, selector: String) -> Result<String, Error> {
        switch result {
        case .success(let value) where value == "__not_found__":
            return .failure(BrowserError.elementNotFound(selector))
        default:
            return result
        }
    }

    /// Encodes a Swift string as a JavaScript string literal, so selectors
    /// and values containing quotes can't break out of the script.
    static func jsString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let text = String(data: data, encoding: .utf8),
              text.count >= 2 else { return "\"\"" }
        return String(text.dropFirst().dropLast())
    }

    private static func describe(_ value: Any?) -> String {
        switch value {
        case nil, is NSNull: return ""
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default:
            if let value,
               JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            return value.map { String(describing: $0) } ?? ""
        }
    }
}

extension BrowserModel: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        syncNavigationState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url {
            urlText = url.absoluteString
        }
        finishNavigation(.success(webView.url?.absoluteString ?? urlText))
        EventBus.shared.publish(APIEvent("browser.navigated", [
            "pane": id.uuidString,
            "url": urlText,
            "title": pageTitle,
        ]))
        WorkspaceStore.shared.scheduleSave()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishNavigation(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishNavigation(.failure(error))
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

                Button {
                    model.isLoading ? model.stop() : model.reload()
                } label: {
                    Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help(model.isLoading ? "Stop loading" : "Reload")

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

            FadedDivider()

            WebViewRepresentable(webView: model.webView)
        }
        .background(theme.background)
    }
}

// MARK: - Tabbed browser panel

/// A collection of browser tabs for the right-hand panel. Each tab owns its
/// own `WKWebView`, so switching tabs keeps every page alive and scrolled
/// where it was.
final class BrowserTabsModel: ObservableObject {
    @Published private(set) var tabs: [BrowserModel] = []
    @Published var selectedID: UUID?

    var active: BrowserModel? {
        guard let selectedID else { return tabs.first }
        return tabs.first { $0.id == selectedID } ?? tabs.first
    }

    @discardableResult
    func newTab(url: String? = nil) -> BrowserModel {
        // A tab opened by hand starts empty; one opened for a link loads it.
        let model = BrowserModel(initialURL: url, autoLoad: false)
        tabs.append(model)
        selectedID = model.id
        EventBus.shared.publish(APIEvent("browser.tab.created", ["tab": model.id.uuidString]))
        return model
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if selectedID == id {
            // Prefer the neighbour on the left, the way browsers do.
            selectedID = tabs[max(0, index - 1)..<tabs.count].first?.id ?? tabs.last?.id
        }
        EventBus.shared.publish(APIEvent("browser.tab.closed", ["tab": id.uuidString]))
    }

    func title(for model: BrowserModel) -> String {
        model.pageTitle.isEmpty ? "New tab" : model.pageTitle
    }
}

/// The right-hand browser panel: a tab strip, a navigation row, and either a
/// live page or the empty state.
struct BrowserPanelView: View {
    @ObservedObject var model: BrowserTabsModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        VStack(spacing: 0) {
            tabStrip(theme: theme)
            FadedDivider()
            if let active = model.active {
                BrowserNavigationRow(model: active)
                FadedDivider()
                ZStack {
                    WebViewRepresentable(webView: active.webView)
                        .opacity(active.hasNavigated ? 1 : 0)
                    if !active.hasNavigated {
                        BrowserEmptyState(theme: theme)
                    }
                }
            } else {
                BrowserEmptyState(theme: theme)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.background)
    }

    private func tabStrip(theme: Theme) -> some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.tabs) { tab in
                        BrowserTabChip(
                            tab: tab,
                            title: model.title(for: tab),
                            isSelected: model.active?.id == tab.id,
                            onSelect: { model.selectedID = tab.id },
                            onClose: { model.closeTab(tab.id) }
                        )
                    }
                }
            }

            Button {
                model.newTab()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New tab")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

/// One tab chip: favicon-ish glyph, title, and a close button.
private struct BrowserTabChip: View {
    @ObservedObject var tab: BrowserModel
    let title: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        HStack(spacing: 6) {
            Image(systemName: "globe")
                .font(.system(size: 10))
                .foregroundStyle(theme.textSecondary)
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close tab")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(maxWidth: 190)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? theme.surface : (hovering ? theme.surface.opacity(0.5) : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }
}

/// Back / forward / reload, the address field, and page actions.
private struct BrowserNavigationRow: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        HStack(spacing: 8) {
            Button(action: model.goBack) {
                Image(systemName: "arrow.left")
            }
            .buttonStyle(.plain)
            .disabled(!model.canGoBack)
            .help("Back")

            Button(action: model.goForward) {
                Image(systemName: "arrow.right")
            }
            .buttonStyle(.plain)
            .disabled(!model.canGoForward)
            .help("Forward")

            Button {
                model.isLoading ? model.stop() : model.reload()
            } label: {
                Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help(model.isLoading ? "Stop loading" : "Reload")

            TextField("Enter a URL", text: $model.urlText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit { model.loadCurrentText() }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(theme.surfaceBorder)
                )

            Button {
                if let url = BrowserModel.url(fromUserInput: model.urlText) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Image(systemName: "arrow.up.right")
            }
            .buttonStyle(.plain)
            .disabled(model.urlText.isEmpty)
            .help("Open in your default browser")

            Menu {
                Button("Reload", action: model.reload)
                Button("Home", action: model.goHome)
                Divider()
                Button("Copy Address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.urlText, forType: .string)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .foregroundStyle(theme.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

private struct BrowserEmptyState: View {
    let theme: Theme

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "globe")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(theme.textSecondary)
            Text("Start browsing")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            Text("Enter a URL to open a page")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
