import Foundation

/// What a terminal tab's banner says when its ssh could not connect or was
/// turned away, using what `RemoteProblem` already reads from ssh's words for
/// the file browser — said for a terminal, which unlike the file browser can
/// ask for a password, and with the buttons that make sense there.
///
/// Foundation only, so it is checked off a Mac; `TerminalSession` asks it when
/// a session ends, and the banner shows what it says.
enum TabConnectionProblem {
    /// The problem worth naming when an ssh tab has ended, or nil when the
    /// banner's own words — the session disconnected, with Reconnect — are as
    /// good as any.
    ///
    /// Only ssh's "the connection went wrong" (255), and not an end the person
    /// chose with `~.`. A refused sign-in, a changed host key, an identity file
    /// ssh can't use and too many keys are named whenever ssh's last words say
    /// so: those are what Reconnect alone cannot fix, and the same reading is
    /// what stops an automatic reconnect (`AutoReconnect.cause`). A connection
    /// that could not be made — refused, no answer, no route, no such name, or
    /// closed before signing in — is named only when the session never got
    /// going, ending within `minUptime`: after a session that worked, the same
    /// words mean a connection was lost, which the banner already says.
    static func diagnose(
        tail: String,
        connection: SSHConnection,
        terminationStatus: Int32?,
        ranFor: TimeInterval,
        minUptime: TimeInterval = AutoReconnect.standard.minUptime
    ) -> RemoteProblem? {
        guard connection.transport == .ssh,
              AutoReconnect.isConnectionError(terminationStatus: terminationStatus),
              AutoReconnect.cause(ofOutput: tail, connection: connection) != .userDisconnected
        else { return nil }
        let problem = RemoteProblem.classify(output: tail, connection: connection)
        switch problem.kind {
        case .hostKeyChanged(let offending):
            // ssh ends with "Host key verification failed." both when a key it
            // knows has changed and when the person answered no to a host it has
            // never seen. Only the first is a changed key: ssh says so in
            // capitals, or points at the line in known_hosts it disagrees with.
            let changed = offending != nil || tail.lowercased().contains("remote host identification has changed")
            return changed ? problem : nil
        case .signInRefused, .tooManyAuthFailures, .identityFile:
            return problem
        case .connectionRefused, .timedOut, .unreachable, .hostNotFound, .connectionDropped:
            return ranFor < minUptime || neverConnected(tail) ? problem : nil
        case .noSFTP, .pathNotFound, .pathDenied, .other:
            return nil
        }
    }

    /// Words ssh prints only while it is still making the connection, so a
    /// session that ended on them never started, however long that took — a
    /// `ConnectTimeout` set long in ~/.ssh/config, say. A connection that was
    /// up and then lost ends on other words ("closed by remote host",
    /// "Broken pipe", "Timeout, server not responding").
    static func neverConnected(_ tail: String) -> Bool {
        let text = tail.lowercased()
        return ["ssh: connect to host ", "could not resolve hostname", "kex_exchange_identification"]
            .contains { text.contains($0) }
    }

    /// One sentence for the banner, after the problem's title.
    static func summary(for problem: RemoteProblem) -> String {
        switch problem.kind {
        case .signInRefused(let methods):
            if !methods.isEmpty, !methods.contains("password"), !methods.contains("keyboard-interactive") {
                return "It accepts only \(RemoteProblem.describe(methods)), and none this Mac offered was accepted."
            }
            return "The password or key wasn't accepted."
        case .tooManyAuthFailures:
            return "ssh offered too many keys before the right one. Name the one to use in Connection Settings."
        case .hostKeyChanged:
            return "If you know why, forget the old key and reconnect. If you don't, don't carry on."
        case .timedOut:
            return "It may be asleep or off, or on a network this Mac isn't on."
        case .unreachable:
            return "There is no route to it from the network this Mac is on."
        case .connectionDropped:
            return "It hung up before signing in: a connection limit, a ban list, or ssh restarting there."
        case .identityFile, .connectionRefused, .hostNotFound, .noSFTP, .pathNotFound, .pathDenied, .other:
            return problem.explanation
        }
    }

    /// The problem's buttons that make sense on a terminal tab's banner: not
    /// Try Again, which the banner's Reconnect already is, and not Sign In in a
    /// Terminal, which the tab already is. At most two, so the banner stays one
    /// row. Each that runs something only types it into a new tab.
    static func actions(for problem: RemoteProblem) -> [RemoteAction] {
        Array(problem.actions.filter { $0 != .tryAgain && $0 != .signInInTerminal }.prefix(2))
    }
}
