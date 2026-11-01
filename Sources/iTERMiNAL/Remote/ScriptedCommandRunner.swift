import Foundation
import Combine

/// Starts the `ssh` process for one scripted command (see `ScriptedCommand`).
///
/// It is the same non-interactive `ssh` the port scan uses: `TunnelPlan` builds
/// it, so it has `BatchMode`, a connection time limit and no host-key option,
/// and it takes the sign-in a terminal tab to the same host has left open if
/// there is one.
enum ScriptedCommandRunner {
    /// Runs off the main thread; `completion` arrives on it with how long it took.
    static func run(
        connection: SSHConnection,
        commandLine: String,
        timeout: TimeInterval,
        completion: @escaping (ScriptedCommand.Outcome, Int) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let started = Date()
            let outcome = perform(connection: connection, commandLine: commandLine, timeout: timeout)
            let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
            DispatchQueue.main.async { completion(outcome, milliseconds) }
        }
    }

    private static func perform(connection: SSHConnection, commandLine: String, timeout: TimeInterval) -> ScriptedCommand.Outcome {
        guard let ssh = SessionLaunch.resolveExecutable("ssh") else {
            return ScriptedCommand.notStarted("Couldn't find ssh on this Mac.")
        }
        let shared = SSHControlSocket.liveSocket(for: connection, base: NSTemporaryDirectory())
        let arguments = TunnelPlan.scanArguments(for: connection, sharedSocket: shared, command: commandLine)
        guard let result = ProcessRunner.run(ssh, arguments, timeout: timeout) else {
            return ScriptedCommand.notStarted("Couldn't start ssh.")
        }
        return ScriptedCommand.outcome(
            status: result.status,
            output: result.output,
            errorOutput: result.errorOutput,
            timedOut: result.timedOut
        )
    }
}

/// What scripts have run on hosts since the app started, newest first, for
/// Settings → Security. Held in memory only: it is gone when the app quits, and
/// each command in it is masked and cut short.
final class ScriptedCommandLog: ObservableObject {
    static let shared = ScriptedCommandLog()
    static let capacity = 50

    struct Entry: Identifiable {
        let id = UUID()
        let time: Date
        let host: String
        let command: String
        let result: String
    }

    @Published private(set) var entries: [Entry] = []

    /// Called on the main queue.
    func record(host: String, command: String, outcome: ScriptedCommand.Outcome) {
        entries.insert(
            Entry(
                time: Date(),
                host: host,
                command: ScriptedCommand.excerpt(of: command),
                result: ScriptedCommand.summary(of: outcome)
            ),
            at: 0
        )
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
    }

    /// A command that was refused before it could start, which is worth a line
    /// too: a script is trying hosts it was not let into.
    func recordRefusal(host: String, reason: String) {
        entries.insert(Entry(time: Date(), host: host, command: "", result: "refused: \(reason)"), at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
    }

    func clear() {
        entries = []
    }
}
