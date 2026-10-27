import AppKit

/// The question a connection set to "Ask each time I connect" puts before ssh
/// starts: forward the agent this time, or not.
///
/// The safe answer is the default one — the first button, the one Return
/// presses — because the person who dismisses it by habit should end up with
/// nothing forwarded rather than everything.
enum AgentForwardingPrompt {
    /// Asks, then calls `answer` with `true` to forward and `false` not to.
    ///
    /// Always on a later turn of the main run loop, never inside the call that
    /// asked: a session starts from SwiftUI's update pass, and a modal alert
    /// opened in the middle of one is a nested run loop inside a layout.
    static func ask(for connection: SSHConnection, answer: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            let name = connection.name.isEmpty ? connection.host : connection.name
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Forward your SSH agent to \(name)?"
            alert.informativeText = """
            While this connection is open, programs on \(connection.host) — and anyone who can act as you there, such as root — can use your SSH keys to sign in to other machines. The keys themselves never leave this Mac.

            Forward only to a host you trust.
            """
            alert.addButton(withTitle: "Don’t Forward")
            alert.addButton(withTitle: "Forward Agent")
            answer(alert.runModal() == .alertSecondButtonReturn)
        }
    }
}
