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
