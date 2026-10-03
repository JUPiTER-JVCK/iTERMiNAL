import Foundation

enum ErrorHelpKind: Equatable {
    case explain
    case fix
}

/// What the failure watcher noticed: the command, what it printed, and what
/// looked wrong — kept as it came off the screen, and only cleaned and masked
/// if someone asks for help with it.
struct ErrorOffer: Equatable {
    var command: String
    var output: String
    /// A few words for a tooltip: "permission denied".
    var reason: String
}

/// What an Explain or Fix would send, prepared and ready to show for consent:
/// everything in it has already been cleaned, so what is on screen to agree to
/// is what goes.
struct ErrorHelpRequest: Equatable {
    var kind: ErrorHelpKind
    /// The command that was run, if known, with secrets masked.
    var command: String?
    /// The output, stripped of control sequences, masked, and cut to fit.
    var output: String
    var lineCount: Int
    var destination: AssistantDestination.Description

    /// - Parameters:
    ///   - rawOutput: Straight from the terminal. Only the tail is kept.
    ///   - baseURL: The configured assistant endpoint, to say where it goes.
    static func make(
        kind: ErrorHelpKind,
        command: String?,
        rawOutput: String,
        baseURL: String
    ) -> ErrorHelpRequest {
        let output = ContextSanitizer.sanitizeRecentOutput(rawOutput)
        let typed = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanedCommand = typed.isEmpty ? nil : SecretRedactor.redact(String(typed.prefix(commandLimit)))
        return ErrorHelpRequest(
            kind: kind,
            command: cleanedCommand,
            output: output,
            lineCount: output.split(separator: "\n", omittingEmptySubsequences: true).count,
            destination: AssistantDestination.describe(baseURL: baseURL)
        )
    }

    static let commandLimit = 1_000

    /// What to ask. Short on purpose: the model already has the command and the
    /// output, and the system prompt already says to fence commands and never
    /// to claim they ran.
    var prompt: String {
        switch kind {
        case .explain:
            return "Explain what went wrong in the output above and the most likely cause, in a few short sentences. "
                + "Only suggest a command if it helps, and do not assume the command failed if the output does not say so."
        case .fix:
            return "Suggest the smallest change that would fix what went wrong in the output above. "
                + "Give the exact command in a fenced code block, with one line on why. "
                + "If the output does not show a failure, say so instead of inventing one."
        }
    }

    /// The question put to the person before anything is sent. Names the
    /// destination, and says "stays on this Mac" only for a loopback one.
    var consentMessage: String {
        let lines = lineCount == 1 ? "1 line of output" : "\(lineCount) lines of output"
        let what = command == nil ? lines : "the command and \(lines)"
        if destination.staysOnThisMac {
            return "Send \(what) to \(destination.name)? It stays on this Mac."
        }
        return "Send \(what) to \(destination.name)? Values that look like keys or passwords are masked first."
    }
}
