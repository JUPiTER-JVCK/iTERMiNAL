import Foundation

struct AssistantContext {
    var workingDirectory: String?
    var recentOutput: String?
}

/// Seam for the future AI assistant. The composer routes "@ai …" input here;
/// a real implementation (cloud API or local model) replaces the null one
/// without touching the UI.
protocol AssistantService: AnyObject {
    var isConfigured: Bool { get }
    func complete(prompt: String, context: AssistantContext) async throws -> String
}

enum AssistantError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No AI assistant is configured yet."
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
