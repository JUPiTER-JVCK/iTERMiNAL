import SwiftUI
import AppKit

/// A log file somebody asked to have analyzed.
struct LogAnalysisTarget: Identifiable, Equatable {
    let id = UUID()
    let path: String
}

/// Reads a log file and asks the assistant about it, one request at a time.
/// What is read, and how, is `LogAnalysis`'s; this holds the state the sheet
/// shows and the task that is asking.
@MainActor
final class LogAnalysisModel: ObservableObject {
    enum Phase: Equatable {
        case reading
        case unreadable(String)
        /// Read and waiting to be told to go.
        case ready(PreparedLog)
        case asking(LogProgress)
        case answered(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .reading
    let path: String
    private var prepared: PreparedLog?
    private var task: Task<Void, Never>?

    init(path: String) {
        self.path = path
    }

    /// Reads the file off the main thread: up to 200 KB, cleaned and masked.
    func load() {
        guard prepared == nil else { return }
        let path = path
        Task.detached(priority: .userInitiated) {
            let result = LogAnalysis.prepare(path: path)
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch result {
                case .failure(let problem):
                    self.phase = .unreadable(problem.message)
                case .success(let log):
                    self.prepared = log
                    self.phase = .ready(log)
                }
            }
        }
    }

    func ask(question: String) {
        guard let log = prepared else { return }
        let service = AssistantServiceProvider.current
        guard service.isConfigured else {
            phase = .failed("The AI assistant isn't set up yet.")
            return
        }
        phase = .asking(LogProgress(step: 0, total: LogAnalysis.requestCount(chunkCount: log.chunks.count), label: "Starting"))
        task = Task { [weak self] in
            do {
                let answer = try await LogAnalysis.analyze(
                    log: log,
                    question: question,
                    send: { system, user in
                        try await service.complete(system: system, user: user, temperature: nil)
                    },
                    progress: { progress in
                        // Called from wherever the work is running.
                        DispatchQueue.main.async { self?.noteProgress(progress) }
                    }
                )
                guard !Task.isCancelled else { return }
                self?.phase = .answered(answer)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func noteProgress(_ progress: LogProgress) {
        guard case .asking = phase else { return }
        phase = .asking(progress)
    }

    /// Stops asking, and goes back to the question.
    func stop() {
        task?.cancel()
        task = nil
        if let prepared { phase = .ready(prepared) }
    }

    /// Back to the question, after an answer or a failure.
    func askAgain() {
        if let prepared { phase = .ready(prepared) }
    }
}

/// Shown before a log goes anywhere: what is asked, where it goes, how much of
/// the file and in how many requests, and — one click away — every character.
struct LogAnalysisSheet: View {
    @StateObject private var model: LogAnalysisModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var showing = false

    init(target: LogAnalysisTarget) {
        _model = StateObject(wrappedValue: LogAnalysisModel(path: target.path))
    }

    private var isConfigured: Bool { AssistantServiceProvider.current.isConfigured }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Analyze a log file")
                .font(.headline)
            Text((model.path as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            content
        }
        .padding(16)
        .frame(width: 580)
        .tint(settings.accentColor)
        .onAppear { model.load() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .reading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading the file…")
                    .font(.system(size: 12))
            }
            closeRow

        case .unreadable(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
            closeRow

        case .ready(let log):
            ready(log)

        case .asking(let progress):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(progress.step == 0 ? "Starting…" : "\(progress.label) — request \(progress.step) of up to \(progress.total)")
                    .font(.system(size: 12))
            }
            HStack {
                Spacer()
                Button("Stop") { model.stop() }
                    .keyboardShortcut(.cancelAction)
            }

        case .answered(let answer):
            Text("The answer is written by a model from the text it was sent. It can be wrong, so it is shown as text only: nothing in it is run.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(answer)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 280)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(answer, forType: .string)
                }
                Spacer()
                Button("Ask Again…") { model.askAgain() }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Back") { model.askAgain() }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private var closeRow: some View {
        HStack {
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private func ready(_ log: PreparedLog) -> some View {
        let destination = AssistantDestination.describe(baseURL: settings.assistantBaseURL)
        return VStack(alignment: .leading, spacing: 12) {
            Text("It reads the end of the file, up to \(LogAnalysis.sizeLabel(LogAnalysis.maxBytes)), and asks the assistant about it a part at a time. Nothing is sent until you press Analyze.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField(LogAnalysis.defaultQuestion, text: $question, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)

            if log.droppedPartialLine {
                Text("The file was cut at the start of what was read, so the first line, a fragment, is left out.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if !isConfigured {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label("The AI assistant isn't set up yet.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                    Button("Open Settings → AI") {
                        SettingsNavigator.request(.ai)
                        openSettings()
                    }
                }
            } else {
                Text(LogAnalysis.consentMessage(log: log, destination: destination))
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }

            DisclosureGroup("What will be sent", isExpanded: $showing) {
                if showing {
                    ReadOnlyTextView(text: LogAnalysis.preview(log: log, question: LogAnalysis.cleanQuestion(question)))
                        .frame(height: 200)
                }
            }
            .font(.system(size: 12))

            Text("The answer is written by a model from that text. It can be wrong, and a log can try to steer it, so it is shown only as text: nothing in it is run.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Analyze") { model.ask(question: question) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isConfigured)
            }
        }
    }
}

/// A scrolling, selectable, read-only text view. SwiftUI's `Text` is not meant
/// for a couple of hundred kilobytes.
private struct ReadOnlyTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.isRichText = false
            view.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            view.textContainerInset = NSSize(width: 6, height: 6)
            view.string = text
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
    }
}
