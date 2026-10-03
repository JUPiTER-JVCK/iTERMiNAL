import SwiftUI

/// Handles `@ai …` submission from the composer, and Explain / Fix it for what
/// a terminal printed: configuration checks, context building, consent,
/// cancelable completion, and banner state.
///
/// Nothing here runs anything. A reply is text; the most this does with a
/// suggested command is hand it to the composer's input, where only a person
/// pressing Return sends it.
@MainActor
final class ComposerAIController: ObservableObject {
    enum Banner: Equatable {
        case notConfigured
        case thinking
        case reply(String)
        case failure(String)
        /// A command printed something that reads like an error, and Explain /
        /// Fix it are on offer. Nothing has been sent.
        case offer(ErrorOffer)
        /// About to send output to the assistant, and waiting to be told to.
        case consent(ErrorHelpRequest)
    }

    @Published var banner: Banner?
    private var task: Task<Void, Never>?
    /// Whether an assistant is set up, remembered briefly. Asking reads the
    /// keychain, and the composer asks on every command it sends.
    private var configuredCheck: (value: Bool, at: Date)?

    func assistantIsConfigured() -> Bool {
        if let check = configuredCheck, Date().timeIntervalSince(check.at) < 30 { return check.value }
        let value = AssistantServiceProvider.current.isConfigured
        configuredCheck = (value, Date())
        return value
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func clearBanner() {
        banner = nil
    }

    static func stripAIPrefix(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let rest: String
        if lower.hasPrefix("@ai:") {
            rest = String(trimmed.dropFirst(4))
        } else if lower.hasPrefix("@ai") {
            rest = String(trimmed.dropFirst(3))
        } else {
            rest = trimmed
        }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func submit(prompt: String, store: WorkspaceStore, settings: AppSettings) {
        task?.cancel()

        let service = AssistantServiceProvider.current
        guard service.isConfigured else {
            banner = .notConfigured
            return
        }

        let context = Self.buildContext(store: store, settings: settings)
        banner = .thinking
        run(prompt: prompt, context: context, service: service)
    }

    // MARK: Error help

    /// An offer from the failure watcher. It never replaces something the
    /// person is waiting on or reading.
    func offer(_ offer: ErrorOffer) {
        switch banner {
        case nil, .offer?:
            banner = .offer(offer)
        default:
            break
        }
    }

    /// Explain or Fix it. With an `offer` it is about that command and what it
    /// printed; without one it is about what the composer's terminal shows now.
    ///
    /// When "Include recent terminal output" is off this asks first, naming
    /// where the text would go. It does not turn the setting on.
    func requestHelp(_ kind: ErrorHelpKind, offer: ErrorOffer?, store: WorkspaceStore, settings: AppSettings) {
        task?.cancel()

        guard AssistantServiceProvider.current.isConfigured else {
            banner = .notConfigured
            return
        }

        let command: String?
        let output: String
        if let offer {
            command = offer.command
            output = offer.output
        } else {
            guard let session = store.composerDestinationSession else {
                banner = .failure("There's nothing to look at yet — run something first.")
                return
            }
            output = session.captureVisibleText()
            // The exact command sent from the composer to this terminal — and
            // only while it is still on screen, so it cannot be a command whose
            // output has long scrolled away. Not the terminal's own `lastCommand`:
            // that is a two-word label for the sidebar, with the arguments gone.
            // A command typed straight into the terminal is already on screen,
            // prompt line and all, so the output carries it.
            if let sent = store.lastComposerSend, sent.sessionID == session.id,
               !sent.command.isEmpty, output.contains(sent.command) {
                command = sent.command
            } else {
                command = nil
            }
        }
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            banner = .failure("There's no output to look at yet.")
            return
        }

        // The context switches are applied here, once, and the result travels
        // inside the request: what the consent prompt shows is what is sent.
        let session = store.composerDestinationSession ?? store.focusedSession ?? store.composerSession
        let request = ErrorHelpRequest.make(
            kind: kind,
            command: command,
            rawOutput: output,
            baseURL: settings.assistantBaseURL,
            workingDirectory: settings.assistantIncludeCwd ? session?.currentDirectory : nil,
            gitBranch: settings.assistantIncludeGitBranch ? session?.gitBranch : nil,
            workspaceName: settings.assistantIncludeWorkspace ? store.currentWorkspace?.name : nil
        )
        if settings.assistantIncludeRecentOutput {
            send(request, store: store, settings: settings)
        } else {
            banner = .consent(request)
        }
    }

    /// The person agreed to what the consent banner showed.
    func confirm(_ request: ErrorHelpRequest, store: WorkspaceStore, settings: AppSettings) {
        send(request, store: store, settings: settings)
    }

    private func send(_ request: ErrorHelpRequest, store: WorkspaceStore, settings: AppSettings) {
        task?.cancel()
        let service = AssistantServiceProvider.current
        guard service.isConfigured else {
            banner = .notConfigured
            return
        }
        // From the request alone: nothing is gathered again here, so nothing
        // goes that the person was not shown.
        var context = AssistantContext()
        context.workingDirectory = request.workingDirectory
        context.gitBranch = request.gitBranch
        context.workspaceName = request.workspaceName
        context.recentOutput = request.output
        context.lastCommand = request.command
        banner = .thinking
        run(prompt: request.prompt, context: context, service: service)
    }

    private func run(prompt: String, context: AssistantContext, service: AssistantService) {
        task = Task { [weak self] in
            do {
                let reply = try await service.complete(prompt: prompt, context: context)
                guard !Task.isCancelled else { return }
                self?.banner = .reply(reply)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.banner = .failure(error.localizedDescription)
            }
        }
    }

    private static func buildContext(store: WorkspaceStore, settings: AppSettings) -> AssistantContext {
        let session = store.focusedSession ?? store.composerSession
        var context = AssistantContext()
        if settings.assistantIncludeCwd {
            context.workingDirectory = session?.currentDirectory
        }
        if settings.assistantIncludeGitBranch {
            context.gitBranch = session?.gitBranch
        }
        if settings.assistantIncludeWorkspace {
            context.workspaceName = store.currentWorkspace?.name
        }
        if settings.assistantIncludeRecentOutput, let session {
            context.recentOutput = ContextSanitizer.sanitizeRecentOutput(
                session.captureVisibleText()
            )
        }
        return context
    }
}
