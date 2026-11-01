import Foundation

/// Where an assistant request is going, in words a person can check before
/// agreeing to send anything there.
enum AssistantDestination {
    struct Description: Equatable {
        /// "api.openai.com", or "the assistant on this Mac".
        let name: String
        /// Only for a loopback address: the request never leaves this Mac.
        let staysOnThisMac: Bool
    }

    /// The same hosts the assistant treats as local when deciding whether a key
    /// is needed.
    static func isLoopback(host: String) -> Bool {
        let host = host.lowercased()
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    /// The keychain item that holds the API key for `baseURL`.
    ///
    /// Anthropic's has its own, so switching the preset never sends a key saved
    /// for another provider to Anthropic, or a Claude key to anyone else. Every
    /// other address keeps the one item it has always used.
    static func keyAccount(forBaseURL baseURL: String) -> String {
        isAnthropic(baseURL: baseURL) ? "assistant.apiKey.anthropic" : "assistant.apiKey"
    }

    /// Anthropic's OpenAI-compatible endpoint answers 400 to a temperature below
    /// 1 on its current models, and asks that the field be left out instead.
    /// The page reader asks for 0 so the same page gives the same rows; this
    /// changes the request for that one host only, and hands back exactly what
    /// was asked for everywhere else.
    static func temperature(_ requested: Double?, forBaseURL baseURL: String) -> Double? {
        guard let requested, requested < 1, isAnthropic(baseURL: baseURL) else { return requested }
        return nil
    }

    /// The host itself, not a name that merely contains it.
    private static func isAnthropic(baseURL: String) -> Bool {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URL(string: trimmed)?.host else { return false }
        return host.lowercased() == "api.anthropic.com"
    }

    static func describe(baseURL: String) -> Description {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = URL(string: trimmed)?.host, !host.isEmpty else {
            return Description(name: "the configured assistant endpoint", staysOnThisMac: false)
        }
        if isLoopback(host: host) {
            return Description(name: "the assistant on this Mac", staysOnThisMac: true)
        }
        return Description(name: host, staysOnThisMac: false)
    }
}
