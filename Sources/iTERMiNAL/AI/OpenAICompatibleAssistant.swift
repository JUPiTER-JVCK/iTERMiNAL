import Foundation

/// OpenAI chat-completions client that also talks to compatible servers
/// (Groq, local proxies, Ollama at `/v1`, etc.). No tool calling in v1.
final class OpenAICompatibleAssistant: AssistantService {
    static let apiKeyAccount = "assistant.apiKey"

    private let settings: AppSettings
    private let urlSession: URLSession

    init(settings: AppSettings = .shared, urlSession: URLSession = .shared) {
        self.settings = settings
        self.urlSession = urlSession
    }

    var isConfigured: Bool {
        let base = settings.assistantBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return false }
        let key = (KeychainStore.get(Self.apiKeyAccount) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { return true }
        // Ollama and similar local servers often need no key (or a dummy).
        return Self.isLocalHost(base)
    }

    func complete(prompt: String, context: AssistantContext) async throws -> String {
        guard isConfigured else { throw AssistantError.notConfigured }

        let base = settings.assistantBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpoint = Self.chatCompletionsURL(from: base) else {
            throw AssistantError.invalidURL(base)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = (KeychainStore.get(Self.apiKeyAccount) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let body = ChatCompletionRequest(
            model: settings.assistantModel.trimmingCharacters(in: .whitespacesAndNewlines),
            messages: [
                .init(role: "system", content: Self.systemPrompt),
                .init(role: "user", content: Self.userContent(prompt: prompt, context: context)),
            ]
        )
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw AssistantError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AssistantError.transport("Unexpected response type.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8)
                .map { String($0.prefix(400)) }
            throw AssistantError.httpStatus(http.statusCode, snippet)
        }

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        let text = decoded.choices.first?.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { throw AssistantError.emptyResponse }
        return text
    }

    // MARK: - URL helpers

    /// True when the base URL points at a loopback host (no API key required).
    static func isLocalHost(_ baseURL: String) -> Bool {
        guard let url = URL(string: baseURL), let host = url.host?.lowercased() else {
            return false
        }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    /// Accepts either `…/v1` or a full `…/v1/chat/completions` base.
    static func chatCompletionsURL(from base: String) -> URL? {
        let trimmed = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.lowercased().hasSuffix("/chat/completions") {
            return URL(string: base)
        }
        let root = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URL(string: root + "/chat/completions")
    }

    // MARK: - Prompt

    static let systemPrompt = """
        You are helping inside a macOS terminal app (iTERMiNAL). Prefer concise, \
        actionable answers. When you suggest shell commands, mark them clearly \
        (for example with a fenced code block) and never claim they were executed — \
        the user chooses what enters a terminal.
        """

    static func userContent(prompt: String, context: AssistantContext) -> String {
        var parts: [String] = []
        if let cwd = context.workingDirectory, !cwd.isEmpty {
            parts.append("Working directory: \(cwd)")
        }
        if let branch = context.gitBranch, !branch.isEmpty {
            parts.append("Git branch: \(branch)")
        }
        if let workspace = context.workspaceName, !workspace.isEmpty {
            parts.append("Workspace: \(workspace)")
        }
        if let output = context.recentOutput, !output.isEmpty {
            parts.append("Recent terminal output:\n```\n\(output)\n```")
        }
        if let selection = context.selection, !selection.isEmpty {
            parts.append("Selection:\n```\n\(selection)\n```")
        }
        parts.append("Request:\n\(prompt)")
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - Wire types

private struct ChatCompletionRequest: Encodable {
    struct Message: Encodable {
        var role: String
        var content: String
    }

    var model: String
    var messages: [Message]
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            var content: String?
        }
        var message: Message
    }
    var choices: [Choice]
}
