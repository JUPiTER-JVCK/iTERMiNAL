import Foundation

/// The one-click setups Settings → AI offers. Every one of them is the same
/// OpenAI-compatible client pointed somewhere else, so a provider here is only
/// an address and the model to start from; adding one does not change how a
/// request is made.
enum AssistantProvider: String, CaseIterable, Identifiable {
    case openai, claude, ollama, lmstudio, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openai: return "OpenAI"
        case .claude: return "Claude (Anthropic)"
        case .ollama: return "Ollama (local)"
        case .lmstudio: return "LM Studio (local)"
        case .custom: return "Custom"
        }
    }

    /// The address this provider fixes, or nil where the person types it.
    var baseURL: String? {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .claude: return "https://api.anthropic.com/v1"
        case .ollama: return "http://127.0.0.1:11434/v1"
        // Its server's own default, from its documentation. There is no
        // llama.cpp preset: its server's default port is 9931 in the current
        // source but 8080 in its own Docker examples, so no fixed address is
        // right for every build — Custom takes whatever port it was started on.
        case .lmstudio: return "http://127.0.0.1:1234/v1"
        case .custom: return nil
        }
    }

    /// A model to start from, or nil where the right one depends on what the
    /// person has pulled or runs.
    var defaultModel: String? {
        switch self {
        case .openai: return "gpt-4o-mini"
        case .claude: return "claude-haiku-5-5"
        case .ollama, .lmstudio, .custom: return nil
        }
    }

    /// Where this provider's API keys are made, for the providers that have one
    /// page to point at.
    var keysPage: URL? {
        switch self {
        case .claude: return URL(string: "https://platform.claude.com/settings/keys")
        case .openai, .ollama, .lmstudio, .custom: return nil
        }
    }

    /// The preset a base URL belongs to, compared exactly: anything that is not
    /// one of the fixed addresses is Custom.
    static func matching(baseURL: String) -> AssistantProvider {
        allCases.first(where: { $0.baseURL == baseURL }) ?? .custom
    }

    /// What the model field should read after the person picks this provider,
    /// or nil to leave it alone.
    ///
    /// A stock name from another provider is swapped — `gpt-4o-mini` sent to
    /// Anthropic is refused — and an empty field is filled. A name the person
    /// typed is never replaced, and a provider with no stock model (Ollama,
    /// Custom) changes nothing.
    func model(afterSwitchingFrom current: String) -> String? {
        guard let mine = defaultModel else { return nil }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return mine }
        guard trimmed != mine else { return nil }
        let stock = Self.allCases.compactMap { $0.defaultModel }
        return stock.contains(trimmed) ? mine : nil
    }
}
