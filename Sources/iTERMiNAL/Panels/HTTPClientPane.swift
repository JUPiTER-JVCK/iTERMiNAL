import SwiftUI
import AppKit

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
@MainActor
final class HTTPClientModel: ObservableObject, Identifiable {
    let id = UUID()

    @Published var method: HTTPMethod = .get
    @Published var urlText: String = ""
    @Published var headerFields: [HTTPHeaderField] = [HTTPHeaderField(name: "", value: "")]
    @Published var bodyText: String = ""

    @Published private(set) var isSending = false
    @Published private(set) var lastResponse: HTTPResponseSummary?
    @Published private(set) var lastError: HTTPClientError?
    @Published private(set) var history: [HTTPHistoryEntry]

    private let executor = HTTPRequestExecutor()
    private var sendTask: Task<Void, Never>?

    init() {
        history = HTTPHistoryStore.loadAll()
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
        sendTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response = try await self.executor.execute(spec, settings: settings)
                guard !Task.isCancelled else { return }
                self.lastResponse = response
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
        HTTPHistoryStore.clear()
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
        HTTPHistoryStore.append(entry)

        // Built as two separately-optional keys, not one boxed as `Any` —
        // a present-but-nil value isn't how this app's other API events
        // represent "no value", and would depend on JSONSerialization
        // handling a boxed Optional the same way on every platform rather
        // than just the one this was checked on.
        var eventData: [String: Any] = [
            "pane": id.uuidString,
            "method": spec.method.rawValue,
            "url": spec.url,
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
        }
        .background(theme.background)
        .onAppear { urlFieldFocused = true }
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
