import Foundation

struct AssistantContext {
    var workingDirectory: String?
    var recentOutput: String?
    var gitBranch: String?
    var workspaceName: String?
    /// Optional selection; left nil in v1 unless a selection API exists.
    var selection: String?
}

/// Seam for the AI assistant. The composer routes "@ai …" input here;
/// a real implementation (cloud API or local model) replaces the null one
/// without touching the UI.
protocol AssistantService: AnyObject {
    var isConfigured: Bool { get }
    func complete(prompt: String, context: AssistantContext) async throws -> String
}

enum AssistantError: LocalizedError {
    case notConfigured
    case invalidURL(String)
    case httpStatus(Int, String?)
    case emptyResponse
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No AI assistant is configured yet."
        case .invalidURL(let value):
            return "Assistant base URL is invalid: \(value)"
        case .httpStatus(let code, let body):
            if let body, !body.isEmpty {
                return "Assistant request failed (\(code)): \(body)"
            }
            return "Assistant request failed with HTTP \(code)."
        case .emptyResponse:
            return "The assistant returned an empty reply."
        case .transport(let message):
            return "Assistant request failed: \(message)"
        }
    }
}

final class NullAssistantService: AssistantService {
    static let shared = NullAssistantService()

    var isConfigured: Bool { false }

    func complete(prompt: String, context: AssistantContext) async throws -> String {
        throw AssistantError.notConfigured
    }
}
