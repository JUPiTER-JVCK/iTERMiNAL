import SwiftUI
import AppKit

/// Which half of the pane is showing: composing a request, or walking a
/// site's published paths from a command line.
enum HTTPPaneMode: String, CaseIterable {
    case request, explore
}

/// One request/response pane: the fields that make up a request, what came
/// back, and history of what was sent before. Used both as a split-pane
/// leaf and as the right-hand sliding panel — the same view, the same way
/// `FilePaneView` is reused in both places, since this panel (unlike
/// Browser's tabbed one) only ever holds one request at a time.
///
/// Nothing here runs anything on its own. A request is sent only from
/// `send(settings:)`, and that is only ever called in response to a
/// person's own action — pressing Return, ⌘Return, or choosing a history
/// row loads it into the fields but still waits for one of those.
/// Not `@MainActor`: like `BrowserModel`/`FileBrowserModel`, this is stored
/// in `PaneContent` and read synchronously from nonisolated code elsewhere
/// (`PaneNode.snapshot()`/`.restore()`, `APIRouter.describePanes`) — the
/// same reason neither of those two carries the annotation either. `send()`
/// pins its own continuation to the main actor instead, so the `@Published`
/// mutations that follow the network await still land on the main thread.
final class HTTPClientModel: ObservableObject, Identifiable {
    /// Also this pane's history scope — `HTTPHistoryStore` keys its on-disk
    /// directory by this value, so two panes never show or clear each
    /// other's requests. For a split-pane leaf this is persisted in
    /// `PaneSnapshot.http` and passed back into `init(id:)` on restore, so
    /// the pane's history survives a relaunch under the same scope. The
    /// side panel's single instance uses `sidePanelHistoryID`: its builder
    /// fields start empty each launch, but its history is kept, and a fixed
    /// ID means it doesn't leave a new directory behind every time.
    let id: UUID

    static let sidePanelHistoryID = UUID(uuidString: "6F0C5A0E-8B1D-4E55-9C47-3D2A1B7E9F10")!

    @Published var method: HTTPMethod = .get
    @Published var urlText: String = ""
    @Published var headerFields: [HTTPHeaderField] = [HTTPHeaderField(name: "", value: "")]
    @Published var bodyText: String = ""
    @Published var mode: HTTPPaneMode = .request

    /// The command-line site explorer. Not part of what is saved with a
    /// layout: a map is rebuilt by asking, never by reopening the app.
    let explorer = SiteExplorerModel()

    @Published private(set) var isSending = false
    @Published private(set) var lastResponse: HTTPResponseSummary?
    /// `lastResponse`'s body, decoded and pretty-printed once when it arrives.
    /// Formatting inside the response view's body re-parsed up to a 10 MB
    /// JSON document on every redraw — and every keystroke in the URL or body
    /// field redraws it, because the view observes this same model.
    @Published private(set) var lastFormatted: HTTPResponseFormatter.FormattedBody?
    @Published private(set) var lastError: HTTPClientError?
    @Published private(set) var history: [HTTPHistoryEntry]

    /// How much of a body is turned into on-screen text. Separate from
    /// `settings.httpMaxResponseBytes`, the real download-abort cap enforced
    /// upstream in the networking layer — this one only bounds the rendered
    /// string.
    static let maxRenderedCharacters = 200_000

    private let executor = HTTPRequestExecutor()
    private var sendTask: Task<Void, Never>?

    init(id: UUID = UUID()) {
        self.id = id
        history = HTTPHistoryStore.loadAll(scope: id)
        // A `get` typed at the explorer's prompt is a request this pane sent,
        // so it goes through the same history and event as any other.
        explorer.recordRequest = { [weak self] spec, statusCode, errorDescription in
            self?.recordHistory(spec: spec, statusCode: statusCode, errorDescription: errorDescription)
        }
        explorer.loadIntoBuilder = { [weak self] url in
            guard let self else { return }
            self.method = .get
            self.urlText = url
            self.mode = .request
        }
    }

    /// Builds a request from the current fields and sends it, replacing any
    /// send already in flight from this pane — there is only ever one
    /// outstanding request per pane, matching how the toolbar only ever
    /// shows one Send/Cancel control.
    func send(settings: AppSettings) {
        sendTask?.cancel()
        let spec = HTTPRequestSpec(
            method: method,
            url: urlText,
            headers: headerFields.filter { !$0.name.isEmpty },
            body: HTTPMethod.bodylessByConvention.contains(method) ? nil : bodyText
        )
        isSending = true
        lastError = nil
        sendTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await self.executor.execute(spec, settings: settings)
                // Off the main actor: pretty-printing a large body takes
                // long enough to be felt, and `HTTPResponseFormatter` is
                // plain Foundation with no shared state.
                let contentType = response.headers.first { $0.name.lowercased() == "content-type" }?.value
                let formatted = await Task.detached(priority: .userInitiated) {
                    HTTPResponseFormatter.format(
                        response.body,
                        contentType: contentType,
                        maxCharacters: HTTPClientModel.maxRenderedCharacters
                    )
                }.value
                guard !Task.isCancelled else { return }
                self.lastResponse = response
                self.lastFormatted = formatted
                // A page fetched here counts as one the person fetched: if it
                // is on the site being explored, its links join the map.
                self.explorer.recordDiscovered(from: response, settings: settings)
                self.recordHistory(spec: spec, statusCode: response.statusCode, errorDescription: nil)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                let clientError = (error as? HTTPClientError) ?? .transport(error.localizedDescription)
                self.lastError = clientError
                self.recordHistory(spec: spec, statusCode: nil, errorDescription: clientError.errorDescription)
            }
            self.isSending = false
        }
    }

    func cancelInFlightRequest() {
        sendTask?.cancel()
        sendTask = nil
        isSending = false
    }

    /// Puts a history entry's request back into the builder fields without
    /// sending it — load, don't run, the same shape every suggestion
    /// surface in this app already follows.
    func loadFromHistory(_ entry: HTTPHistoryEntry) {
        method = HTTPMethod(entry.method)
        urlText = entry.url
        headerFields = entry.headers.isEmpty ? [HTTPHeaderField(name: "", value: "")] : entry.headers
        bodyText = entry.body ?? ""
    }

    func clearHistory() {
        history = []
        HTTPHistoryStore.clear(scope: id)
    }

    private func recordHistory(spec: HTTPRequestSpec, statusCode: Int?, errorDescription: String?) {
        let entry = HTTPHistoryEntry(
            id: UUID(),
            sentAt: Date(),
            method: spec.method.rawValue,
            url: spec.url,
            headers: spec.headers,
            body: spec.body,
            statusCode: statusCode,
            errorDescription: errorDescription
        )
        history.insert(entry, at: 0)
        // The store prunes its own on-disk copy to this same limit — this
        // keeps the in-memory list, which `append` never trims, from
        // growing without bound for as long as the pane stays open.
        if history.count > HTTPHistoryStore.maxEntries {
            history.removeLast(history.count - HTTPHistoryStore.maxEntries)
        }
        HTTPHistoryStore.append(entry, scope: id)

        // Built as two separately-optional keys, not one boxed as `Any` —
        // a present-but-nil value isn't how this app's other API events
        // represent "no value", and would depend on JSONSerialization
        // handling a boxed Optional the same way on every platform rather
        // than just the one this was checked on.
        // The URL goes out redacted, the same as it is written to history:
        // an API subscriber has no more business seeing `?code=…` or
        // `user:password@` than the history file does.
        var eventData: [String: Any] = [
            "pane": id.uuidString,
            "method": spec.method.rawValue,
            "url": HTTPRedaction.redactedURL(spec.url),
        ]
        if let statusCode { eventData["status"] = statusCode }
        if let errorDescription { eventData["error"] = errorDescription }
        EventBus.shared.publish(APIEvent("http.sent", eventData))
    }
}

/// The pane itself: a toolbar (method, URL, Send/Cancel, overflow), then
/// history beside a stacked request builder and response view. Used
/// directly for both a split-pane leaf and the right-hand sliding panel —
/// this one, unlike Browser's, only ever holds one request at a time, so
/// there is no separate tabbed wrapper the way `BrowserPanelView` needs.
struct HTTPClientPaneView: View {
    @ObservedObject var model: HTTPClientModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var urlFieldFocused: Bool

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        VStack(spacing: 0) {
            modeBar(theme: theme)
            FadedDivider()
            switch model.mode {
            case .request:
                toolbar(theme: theme)
                FadedDivider()
                HSplitView {
                    HTTPHistoryListView(model: model)
                        .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
                    VSplitView {
                        HTTPRequestBuilderView(model: model)
                            .frame(minHeight: 120)
                        HTTPResponseView(model: model)
                            .frame(minHeight: 120)
                    }
                }
            case .explore:
                SiteExplorerView(explorer: model.explorer)
            }
        }
        .background(theme.background)
        .onAppear { if model.mode == .request { urlFieldFocused = true } }
        .onChange(of: model.mode) { _, mode in
            if mode == .request { urlFieldFocused = true }
        }
    }

    /// Request or Explore. A segmented control rather than a menu item: the
    /// explorer is half of what this pane is for, and should be visible.
    private func modeBar(theme: Theme) -> some View {
        HStack {
            Picker("Mode", selection: $model.mode) {
                Text("Request").tag(HTTPPaneMode.request)
                Text("Explore").tag(HTTPPaneMode.explore)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Request: build and send one request · Explore: walk the paths a site publishes, like a directory")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func toolbar(theme: Theme) -> some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(HTTPMethod.common, id: \.self) { method in
                    Button(method.rawValue) { model.method = method }
                }
            } label: {
                Text(model.method.rawValue)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .frame(width: 64, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            TextField("https://example.com", text: $model.urlText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .focused($urlFieldFocused)
                .onSubmit(send)

            if model.isSending {
                Button("Cancel", action: model.cancelInFlightRequest)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red)
            } else {
                Button("Send", action: send)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
            }

            Menu {
                Button("Copy as cURL", action: copyAsCURL)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .foregroundStyle(theme.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            // ⌘Return sends from anywhere in the pane, not only the URL
            // field — an invisible button carrying only the shortcut.
            // `allowsHitTesting(false)` keeps it from swallowing a stray
            // click that lands in a gap between the real toolbar controls.
            Button(action: send) { EmptyView() }
                .keyboardShortcut(.return, modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
    }

    private func send() {
        model.send(settings: settings)
    }

    private func copyAsCURL() {
        let spec = HTTPRequestSpec(
            method: model.method,
            url: model.urlText,
            headers: model.headerFields.filter { !$0.name.isEmpty },
            body: HTTPMethod.bodylessByConvention.contains(model.method) ? nil : model.bodyText
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(HTTPMessage.curlCommand(for: spec), forType: .string)
    }
}
