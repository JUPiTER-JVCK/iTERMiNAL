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

    var id: String { rawValue }

    var label: String {
        switch self {
        case .activeTerminal: return "Active terminal"
        case .ownShell: return "Composer's own shell"
        }
    }

    var detail: String {
        switch self {
        case .activeTerminal:
            return "Commands run in the terminal that has focus — a pane or a dock tab, local or remote."
        case .ownShell:
            return "Commands run in a separate local shell, with the output shown inside the composer."
        }
    }
}
