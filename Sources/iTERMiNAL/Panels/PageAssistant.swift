import SwiftUI
import AppKit

/// A question about a page, waiting to be sent — or not. Holds what the sheet
/// needs to show exactly what would go, and nothing has gone yet.
struct AskProposal: Identifiable {
    let id = UUID()
    /// What was read from the response in hand.
    var page: ExtractedPage
    /// The addresses the page itself names: the only ones an answer's cells can
    /// be acted on as.
    var known: Set<String>
    var question: String
}

/// The assistant's answer about a page, and the asking of it.
///
/// An answer is written by a model from a page's text — it can be wrong, and a
/// page can try to steer it — so what comes back is only ever shown: a table of
/// text, or the text itself. Nothing in it is run, opened or fetched, and a cell
/// is an address a person can act on only if the page named that address
/// (`AIExtractionReply`).
///
/// Like the models it sits beside, not `@MainActor`: it is held by one that
/// nonisolated code reads. Everything a view reads is changed on the main thread.
final class PageAssistant: ObservableObject {
    enum Phase: Equatable {
        case idle
        case asking
        case answered
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var outcome: AIExtractionReply.Outcome?
    /// The question the answer is to, and where it was sent.
    @Published private(set) var asked = ""
    @Published private(set) var destination = ""

    private var task: Task<Void, Never>?
    private var generation = 0

    var isIdle: Bool { phase == .idle }

    /// The rows of the answer, when it came as a list.
    var table: ResultTable? {
        if case .table(let table, _)? = outcome { return table }
        return nil
    }

    /// Sends `request` — which the person has seen, whole — and reads the reply.
    func ask(_ request: AIExtractionRequest, known: Set<String>) {
        task?.cancel()
        generation += 1
        let mine = generation
        let service = AssistantServiceProvider.current
        guard service.isConfigured else {
            phase = .failed("The AI assistant isn't set up yet. Add a provider in Settings → AI.")
            return
        }
        asked = request.question
        destination = request.destination.name
        outcome = nil
        phase = .asking
        task = Task { [weak self] in
            do {
                // Temperature 0: this is reading, and the same page should give
                // the same rows.
                let reply = try await service.complete(
                    system: AIExtractionRequest.systemPrompt, user: request.userContent, temperature: 0
                )
                let parsed = AIExtractionReply.parse(reply, knownAddresses: known)
                // A `let` for the hop to the main thread: a weak capture is a
                // `var`, and a closure that runs concurrently may not read one.
                guard let assistant = self else { return }
                await MainActor.run {
                    guard assistant.generation == mine else { return }
                    assistant.outcome = parsed
                    assistant.phase = .answered
                }
            } catch is CancellationError {
                return
            } catch {
                guard let assistant = self else { return }
                await MainActor.run {
                    guard assistant.generation == mine else { return }
                    assistant.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    /// Stops waiting for a reply.
    func stop() {
        guard phase == .asking else { return }
        generation += 1
        task?.cancel()
        task = nil
        phase = .failed("Stopped. Nothing came back to show.")
    }

    /// Forgets the answer: it was about a page that is no longer the one in hand.
    func reset() {
        generation += 1
        task?.cancel()
        task = nil
        phase = .idle
        outcome = nil
        asked = ""
        destination = ""
    }
}
