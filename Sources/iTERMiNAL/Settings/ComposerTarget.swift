import Foundation

/// Where a command typed in the composer actually runs.
///
/// The composer used to always run commands in a private local shell of its
/// own, with no way to change it. That made it useless over a connection: the
/// context chips above the input said "Remote — my-host" because they describe
/// the focused session, you typed a command, and it ran on this Mac. The same
/// went for a dock tab. The chips were right about where you were looking and
/// wrong about where you were typing.
enum ComposerTarget: String, CaseIterable, Identifiable {
    /// Whatever terminal has focus — a tab pane or a dock tab, local or
    /// remote. The composer becomes an input line for the terminal you are
    /// actually looking at, which is what its chips have always claimed.
    case activeTerminal
    /// A shell the composer keeps to itself, with the output inline under the
    /// input. The old behaviour, kept because running something without
    /// disturbing the pane in front of you is a real use for it.
    case ownShell
    /// No shell at all: the composer becomes a chat with the AI model chosen in
    /// Settings → AI. What is typed goes to the model, never to a terminal.
    case assistant

    var id: String { rawValue }

    /// The label with the model's name, for the picker, where there is one.
    func label(model: String) -> String {
        guard self == .assistant else { return label }
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "AI assistant" : "AI — \(name)"
    }

    var label: String {
        switch self {
        case .activeTerminal: return "Active terminal"
        case .ownShell: return "Composer's own shell"
        case .assistant: return "AI assistant"
        }
    }

    var detail: String {
        switch self {
        case .activeTerminal:
            return "Commands run in the terminal that has focus — a pane or a dock tab, local or remote."
        case .ownShell:
            return "Commands run in a separate local shell, with the output shown inside the composer."
        case .assistant:
            return "The composer is a chat with the AI model from Settings → AI. Nothing typed runs in a terminal; the conversation is kept per space on this Mac."
        }
    }
}
