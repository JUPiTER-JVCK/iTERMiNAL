import SwiftUI

/// Handles `@ai …` submission from the composer: configuration checks,
/// context building, cancelable completion, and banner state.
@MainActor
final class ComposerAIController: ObservableObject {
    enum Banner: Equatable {
        case notConfigured
        case thinking
        case reply(String)
        case failure(String)
    }

    @Published var banner: Banner?
    private var task: Task<Void, Never>?

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

struct ComposerAIBannerView: View {
    let banner: ComposerAIController.Banner
    let theme: Theme

    var body: some View {
        switch banner {
        case .notConfigured:
            Text("The AI assistant isn't configured yet — add a provider in Settings → AI.")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
        case .thinking:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Thinking…")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
            }
        case .reply(let text):
            ScrollView {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 180)
        case .failure(let message):
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.red.opacity(0.85))
        }
    }
}
