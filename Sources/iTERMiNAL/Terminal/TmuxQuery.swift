import Foundation

/// Asks a tmux server, on this Mac, about one of its clients: the command in
/// the client's current pane — Vim, say — and the prefix key that is set.
///
/// tmux runs each pane on a terminal of its own, so from the outside the
/// program in front is only ever tmux. Its server knows better, and says so to
/// `tmux display-message`. The client is picked by the terminal it is on, and
/// the server by the same `-L` or `-S` the client was started with, using the
/// client's own binary: whichever tmux a person runs, it is that one asked.
///
/// The answer is used only to choose which keys to show. Nothing it says is
/// typed or kept.
enum TmuxQuery {
    struct Answer: Equatable {
        /// The current pane's command, as tmux names it (`pane_current_command`).
        var paneCommand: String?
        /// The prefix key, as a key cap ("⌃A"), when tmux has one the strip can
        /// show.
        var prefix: String?
    }

    /// Asks, off the main thread, and hands the answer back on it — nil when
    /// tmux did not answer within a second.
    static func ask(_ client: ActiveProgram.TmuxClient, terminal: String, completion: @escaping (Answer?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let answer = run(client, terminal: terminal)
            DispatchQueue.main.async { completion(answer) }
        }
    }

    private static func run(_ client: ActiveProgram.TmuxClient, terminal: String) -> Answer? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: client.executable)
        // Two commands in one call, as tmux allows with a ";" of their own.
        process.arguments = client.socketArguments + [
            "display-message", "-p", "-c", terminal, "#{pane_current_command}",
            ";", "show-options", "-gv", "prefix",
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        // Set before it starts, so a tmux that answers at once is not missed.
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        // A server that has stopped answering must not hold a thread for long.
        if finished.wait(timeout: .now() + .seconds(1)) == .timedOut {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// The two lines tmux prints: the pane's command, then the prefix.
    static func parse(_ text: String) -> Answer {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let pane = lines.first.flatMap { $0.isEmpty ? nil : $0 }
        let prefix = lines.count > 1 ? ActiveProgram.capForTmuxKey(lines[1]) : nil
        return Answer(paneCommand: pane, prefix: prefix)
    }
}
