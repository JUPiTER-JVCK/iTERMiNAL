import SwiftUI

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
    }
}
