import Combine
import Foundation

/// Watches a terminal after a command was sent from the composer, and notices
/// when what it printed reads like an error.
///
/// Everything it does happens on this Mac, reading the terminal's own text; it
/// sends nothing anywhere. It only reports what it saw, as an offer. Real exit
/// codes would need the shell to report them, so this reads the words instead,
/// and what it says must be "looked like", never "failed".
final class CommandOutcomeWatcher: ObservableObject {
    /// How long the terminal must be silent before it is worth reading. A
    /// command that is still printing is not finished with its output.
    static let quietPeriod: TimeInterval = 1.0
    /// Gives up after this long; a command still going after two minutes is
    /// not one to guess about.
    static let giveUpAfter: TimeInterval = 120
    /// How much of the terminal to read: scrollback and screen, tail only.
    static let captureBytes = 64 * 1024

    private var subscription: AnyCancellable?
    private var deadline: DispatchWorkItem?

    /// - Parameters:
    ///   - baseline: the terminal's text just *before* the command was sent, so
    ///     an error already on screen is not mistaken for this command's.
    ///   - onOffer: called on the main queue, at most once.
    func start(
        session: TerminalSession,
        command: String,
        baseline: String,
        onOffer: @escaping (ErrorOffer) -> Void
    ) {
        stop()
        subscription = session.$lastActivityAt
            .dropFirst()
            .debounce(for: .seconds(Self.quietPeriod), scheduler: DispatchQueue.main)
            .sink { [weak self, weak session] _ in
                guard let self, let session else { return }
                let current = session.captureScrollback(maxBytes: Self.captureBytes)
                let fresh = OutputDiff.newLines(baseline: baseline, current: current)
                guard let match = FailureSignature.firstMatch(in: fresh, excludingCommand: command) else {
                    // Quiet, and nothing wrong yet. A command that goes quiet
                    // and then fails is read again the next time it prints.
                    return
                }
                self.stop()
                onOffer(ErrorOffer(command: command, output: fresh.joined(separator: "\n"), reason: match.reason))
            }
        let item = DispatchWorkItem { [weak self] in self?.stop() }
        deadline = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.giveUpAfter, execute: item)
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
        deadline?.cancel()
        deadline = nil
    }

    deinit {
        deadline?.cancel()
    }
}
