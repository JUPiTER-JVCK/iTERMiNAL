import SwiftUI
import AppKit

/// Shown before a page's text goes anywhere: what is asked, where it goes, how
/// much of the page, and — one click away — every character of it.
struct AskAssistantSheet: View {
    @ObservedObject var extraction: PageExtractionModel
    let proposal: AskProposal

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openSettings) private var openSettings
    @State private var question: String
    @State private var showing = false

    init(extraction: PageExtractionModel, proposal: AskProposal) {
        self.extraction = extraction
        self.proposal = proposal
        _question = State(initialValue: proposal.question)
    }

    private static let examples = [
        "Every product with its price",
        "The people named, with their roles",
        "Dates and what happens on each",
    ]

    private var request: AIExtractionRequest? {
        AIExtractionRequest.make(question: question, page: proposal.page, baseURL: settings.assistantBaseURL)
    }

    private var isConfigured: Bool { AssistantServiceProvider.current.isConfigured }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask the assistant about this page")
                .font(.headline)

            Text("It reads the text of the page you have in hand and answers as a list of rows. Nothing is sent until you press Ask.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("What do you want from it?", text: $question, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 6) {
                ForEach(Self.examples, id: \.self) { example in
                    Button(example) { question = example }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
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
            } else if let request {
                Text(request.consentMessage)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)

                DisclosureGroup("What will be sent", isExpanded: $showing) {
                    ScrollView {
                        Text(request.preview)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 180)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
                }
                .font(.system(size: 12))
            } else {
                Text("Say what you want, and this will show exactly what would be sent and where.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Text("The answer is written by a model from that text. It can be wrong, and a page can try to steer it, so it is only ever shown to you as a table: nothing in it is run, opened or fetched.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { extraction.askProposal = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Ask") { extraction.confirmAsk(question: question) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(request == nil || !isConfigured)
            }
        }
        .padding(16)
        .frame(width: 520)
        .tint(settings.accentColor)
    }
}

/// The answer: where it came from, and the rows — or the words, if it was not
/// a list.
struct AskResultView: View {
    @ObservedObject var extraction: PageExtractionModel
    @ObservedObject var assistant: PageAssistant
    let theme: Theme

    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            status
            FadedDivider()
            content
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                switch assistant.phase {
                case .idle:
                    EmptyView()
                case .asking:
                    ProgressView().controlSize(.small)
                    Text("Asking \(assistant.destination)…")
                case .answered:
                    Image(systemName: "sparkles").foregroundStyle(settings.accentColor)
                    Text("\(assistant.destination) answered")
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message)
                }
                Spacer(minLength: 6)
                if assistant.phase == .asking {
                    Button("Stop") { assistant.stop() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                } else {
                    Button("Ask Again…") { extraction.proposeAsk(settings: settings, question: assistant.asked) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                    Button("Clear") { assistant.reset() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(theme.textPrimary)

            if !assistant.asked.isEmpty {
                Text("“\(assistant.asked)”")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch assistant.outcome {
        case .table(let table, _)?:
            if table.rows.isEmpty {
                Text("The assistant found nothing on the page that matches.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            } else {
                ExtractResults(extraction: extraction, table: table, section: .askAnswer, theme: theme)
            }
        case .text(let text)?:
            VStack(alignment: .leading, spacing: 0) {
                Text("The assistant didn't give a list, so this is shown as it was written.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                ScrollView {
                    Text(text)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
            }
        case nil:
            Spacer(minLength: 0)
        }
    }
}
