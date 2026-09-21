import Foundation

/// Picks the active `AssistantService` the way Settings chooses a sync engine:
/// configured OpenAI-compatible client, otherwise the null seam.
enum AssistantServiceProvider {
    /// Shared OpenAI-compatible client; reads live settings and keychain.
    static let openAICompatible = OpenAICompatibleAssistant()

    static var current: AssistantService {
        openAICompatible.isConfigured ? openAICompatible : NullAssistantService.shared
    }
}
