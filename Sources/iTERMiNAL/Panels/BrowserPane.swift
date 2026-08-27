import SwiftUI
import WebKit

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
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var pageTitle = ""

    let webView: WKWebView

    /// Completions waiting for the current navigation to settle.
    private var navigationCompletions: [(Result<String, Error>) -> Void] = []

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

            Divider()

            WebViewRepresentable(webView: model.webView)
        }
        .background(theme.background)
    }
}
