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
    /// Where the command ran, the git branch and the workspace's name — only
    /// the ones whose switches in Settings → AI are on. They travel with the
    /// request, so what is shown for consent is the payload itself: the
    /// request is the single source for what is sent.
    var workingDirectory: String?
    var gitBranch: String?
    var workspaceName: String?

    /// - Parameters:
    ///   - rawOutput: Straight from the terminal. Only the tail is kept.
    ///   - baseURL: The configured assistant endpoint, to say where it goes.
    static func make(
        kind: ErrorHelpKind,
        command: String?,
        rawOutput: String,
        baseURL: String,
        workingDirectory: String? = nil,
        gitBranch: String? = nil,
        workspaceName: String? = nil
    ) -> ErrorHelpRequest {
        let output = ContextSanitizer.sanitizeRecentOutput(rawOutput)
        let typed = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Masked whole, then cut: a token that straddles the limit would otherwise
        // be left as a fragment too short to be recognised as one.
        let cleanedCommand = typed.isEmpty ? nil : String(SecretRedactor.redact(typed).prefix(commandLimit))
        return ErrorHelpRequest(
            kind: kind,
            command: cleanedCommand,
            output: output,
            lineCount: output.split(separator: "\n", omittingEmptySubsequences: true).count,
            destination: AssistantDestination.describe(baseURL: baseURL),
            workingDirectory: clean(workingDirectory),
            gitBranch: clean(gitBranch),
            workspaceName: clean(workspaceName)
        )
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : SecretRedactor.redact(trimmed)
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

    /// Everything that would be sent, in words, in the order it is shown.
    var contents: [String] {
        var items: [String] = []
        if command != nil { items.append("the command") }
        items.append(lineCount == 1 ? "1 line of output" : "\(lineCount) lines of output")
        if workingDirectory != nil { items.append("the working directory") }
        if gitBranch != nil { items.append("the git branch") }
        if workspaceName != nil { items.append("the workspace name") }
        return items
    }

    /// The question put to the person before anything is sent. Lists every kind
    /// of thing in the request, names the destination, and says "stays on this
    /// Mac" only for a loopback one.
    var consentMessage: String {
        let items = contents
        let what = items.count > 1
            ? items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
            : items.joined()
        if destination.staysOnThisMac {
            return "Send \(what) to \(destination.name)? It stays on this Mac."
        }
        return "Send \(what) to \(destination.name)? Values that look like keys or passwords are masked first."
    }

    /// Exactly what would be sent, as text: the same fields, the same values.
    var preview: String {
        var sections: [String] = []
        if let workingDirectory { sections.append("Working directory:\n\(workingDirectory)") }
        if let gitBranch { sections.append("Git branch:\n\(gitBranch)") }
        if let workspaceName { sections.append("Workspace:\n\(workspaceName)") }
        if let command { sections.append("Command:\n\(command)") }
        sections.append("Output:\n\(output)")
        // The question asked of the assistant, which goes with it.
        sections.append("Request:\n\(prompt)")
        return sections.joined(separator: "\n\n")
    }
}
