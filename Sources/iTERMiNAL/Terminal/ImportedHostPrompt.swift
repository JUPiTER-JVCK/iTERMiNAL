import AppKit

/// The question a host that came in an imported snapshot puts before the first
/// connection to it from this Mac (see `SSHConnection.confirmBeforeConnecting`):
/// what connecting will run, and whether to.
///
/// Built the way the agent question is (`AgentForwardingPrompt`): a modal alert
/// on a later turn of the main run loop, never inside the SwiftUI update that
/// started the session, with the safe answer as the default button. Unlike that
/// one it is put one at a time. An imported layout can hold several tabs to the
/// same host, and they start together; each waits its turn, and once the host
/// has been answered its other tabs take that answer instead of asking again.
enum ImportedHostPrompt {
    /// What a tab says when the answer was not to connect. Reconnect, on the
    /// same banner, asks again.
    static let declinedNote = "Not connected: this host came in an imported snapshot. Reconnect shows what it runs and asks again."

    /// Main thread only, like everything that touches it.
    private static var showing = false
    private static var waiting: [(id: UUID, answer: (Bool) -> Void)] = []

    /// Asks about the saved host `id`, then calls `answer` on the main thread
    /// with `true` to connect and `false` not to.
    static func ask(about id: UUID, answer: @escaping (Bool) -> Void) {
        waiting.append((id: id, answer: answer))
        DispatchQueue.main.async { next() }
    }

    private static func next() {
        // A modal alert runs the main queue while it is up, so a tab that asks
        // meanwhile lands here; it waits for the one on screen to be answered.
        guard !showing, !waiting.isEmpty else { return }
        let (id, answer) = waiting.removeFirst()
        let settings = AppSettings.shared
        // Answered for this host while this tab waited, or the host has gone —
        // which the launch that follows says.
        guard let connection = settings.sshConnections.first(where: { $0.id == id }),
              connection.confirmBeforeConnecting else {
            answer(true)
            next()
            return
        }

        let name = TerminalLinks.preview(connection.name.isEmpty ? connection.host : connection.name)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Connect to \(name)?"
        alert.informativeText = connection.importReview
        alert.addButton(withTitle: "Don’t Connect")
        alert.addButton(withTitle: "Connect")
        showing = true
        let confirmed = alert.runModal() == .alertSecondButtonReturn
        showing = false

        if confirmed {
            // Before the answer, so the host's other tabs find it answered.
            settings.confirmConnection(id)
            answer(true)
        } else {
            // The same answer for the host's other tabs that are waiting.
            let others = waiting.filter { $0.id == id }
            waiting.removeAll { $0.id == id }
            answer(false)
            others.forEach { $0.answer(false) }
        }
        next()
    }
}
