import Foundation

/// When a dropped `ssh` session is started again by itself, and when it is not.
/// Foundation only, so every rule is checked off a Mac; what acts on them is
/// `TerminalSession`.
///
/// This is opt-in (Settings → Connections), and built around one worry: a
/// failure retried in a loop. Every way that could happen is closed here:
///
/// - **Only a lost connection is retried.** ssh exits 255 for a connection
///   that went wrong, and anything else — the remote shell's own exit status, a
///   signal — is the end of a session, not a drop.
/// - **Only one that had been up.** A session that dropped within seconds of
///   starting never worked, and starting it again just fails again.
/// - **Never a sign-in that was refused, or a host key that does not match.**
///   Those are read from what ssh printed last, and they stop it for good:
///   trying again is how an account gets locked out.
/// - **Never one the person ended** with `~.`, or by closing the tab.
/// - **Nobody at the keyboard, so nothing to answer.** Each retry is run with
///   `BatchMode=yes`, so ssh signs in with a key or the agent or not at all: it
///   cannot stop at a password prompt, ask whether to trust a host, or wait on
///   anything. And with `ConnectTimeout`, a retry that cannot connect is over
///   in seconds rather than a minute and more.
/// - **A limited number of tries, further and further apart,** spread by a
///   random amount so a dozen tabs to one host do not all knock at once.
enum AutoReconnect {
    struct Policy: Equatable {
        /// Tries in a row before it gives up.
        var maxAttempts = 6
        /// The wait before the first, in seconds. Each is twice the one before.
        var firstDelay: TimeInterval = 2
        /// The longest wait.
        var maxDelay: TimeInterval = 60
        /// How long a session has to have been up for its end to count as a
        /// drop, and for a retry to count as having worked.
        var minUptime: TimeInterval = 30
        /// How far a wait is moved, as a fraction of it, either way.
        var jitter = 0.25
    }

    static let standard = Policy()

    /// What each retry adds to the ssh command line, ahead of everything the
    /// person wrote there: ssh keeps the first value it is given for an option,
    /// so a `BatchMode=no` of their own cannot undo it.
    static let unattendedArguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15"]

    // MARK: Whether to try

    /// Whether this connection is one an unattended retry suits: plain `ssh`
    /// (mosh roams by itself and a custom command is the person's own), and not
    /// one that asks before forwarding the agent, because that question cannot
    /// be put to an empty chair. Reconnecting it by hand still asks.
    static func isEligible(_ connection: SSHConnection) -> Bool {
        connection.transport == .ssh && !connection.agentForwarding.needsAnswer
    }

    /// Whether the status a session ended with is ssh's "the connection went
    /// wrong", 255.
    ///
    /// SwiftTerm hands over what `waitpid` gave, undecoded, so a normal exit with
    /// code 255 arrives as `255 << 8` (65280) — and a plain 255 is accepted too,
    /// in case a later SwiftTerm decodes it first. No wait status is ever 255
    /// itself, so the two cannot be confused. A signal, or no status, is not a
    /// lost connection.
    static func isConnectionError(terminationStatus status: Int32?) -> Bool {
        guard let status else { return false }
        if status == 255 { return true }
        // A normal exit has no signal in the low seven bits; the code is the next byte.
        return status & 0x7F == 0 && (status >> 8) & 0xFF == 255
    }

    // MARK: Why it ended, from what ssh printed

    enum Cause: Equatable {
        /// Anything that looks like a connection lost, or that says nothing.
        case lost
        /// The person disconnected (`~.`), which ssh reports as plain
        /// "Connection to host closed.".
        case userDisconnected
        /// The sign-in was refused, the host key does not match, or the identity
        /// file cannot be used: a retry would be refused the same way.
        case needsAttention
    }

    /// The last few lines that are not blank: where ssh says why it stopped.
    static func tail(of output: String, lines count: Int = 5) -> String {
        output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(count)
            .joined(separator: "\n")
    }

    /// Words that mean the connection broke rather than was closed on purpose.
    private static let dropWords = [
        "closed by remote host", "broken pipe", "connection reset", "not responding", "timed out", "timeout",
        "send disconnect", "packet_write_wait", "client_loop",
    ]

    /// Reads the end of a session's output. `RemoteProblem` is what already
    /// reads ssh's words for the file browser; its refusals are the ones that
    /// must never be retried.
    static func cause(ofOutput tail: String, connection: SSHConnection) -> Cause {
        let lines = tail.components(separatedBy: .newlines).filter { !$0.isEmpty }
        // `~.` ends with "Connection to host closed." and nothing about a drop.
        // A drop from the other end says "closed by remote host" first, and the
        // same plain line after it, so the line alone proves nothing.
        if let last = lines.last, last.range(of: #"Connection to \S+ closed\.$"#, options: .regularExpression) != nil {
            let before = lines.dropLast().joined(separator: "\n").lowercased()
            if !dropWords.contains(where: { before.contains($0) }) { return .userDisconnected }
        }
        switch RemoteProblem.classify(output: lines.joined(separator: "\n"), connection: connection).kind {
        case .signInRefused, .tooManyAuthFailures, .hostKeyChanged, .identityFile:
            return .needsAttention
        default:
            return .lost
        }
    }

    // MARK: The decision

    enum StopReason: Equatable {
        /// An ordinary exit, or a signal.
        case notAConnectionError
        /// It dropped before it had been up long enough to count.
        case neverConnected
        case disconnectedByUser
        case needsAttention
        /// The tries are used up.
        case gaveUp

        /// A line for the banner, for the reasons the person would otherwise
        /// not understand; nil where nothing needs saying.
        var note: String? {
            switch self {
            case .needsAttention:
                return "It was not retried: ssh said the sign-in or the host key was refused, and trying again would be refused the same way."
            case .gaveUp:
                return "Gave up after \(AutoReconnect.standard.maxAttempts) tries."
            case .notAConnectionError, .neverConnected, .disconnectedByUser:
                return nil
            }
        }
    }

    enum Decision: Equatable {
        /// Try again after this many seconds; this is try number `attempt`.
        case retry(after: TimeInterval, attempt: Int)
        case stop(StopReason)
    }

    /// What to do about a session that has just ended.
    ///
    /// `attemptsSoFar` is how many tries the current run of them has had: 0 for
    /// a session the person started. A retry that stayed up for `minUptime` has
    /// worked, so its own end is a fresh drop with the count back at one; one
    /// that did not is another failed try. `jitterSample` is a number from 0 to
    /// 1, passed in so the same inputs always give the same answer.
    static func decide(
        terminationStatus: Int32?,
        ranFor: TimeInterval,
        attemptsSoFar: Int,
        cause: Cause,
        policy: Policy = standard,
        jitterSample: Double
    ) -> Decision {
        guard isConnectionError(terminationStatus: terminationStatus) else { return .stop(.notAConnectionError) }
        switch cause {
        case .userDisconnected: return .stop(.disconnectedByUser)
        case .needsAttention: return .stop(.needsAttention)
        case .lost: break
        }

        let attempt: Int
        if ranFor >= policy.minUptime {
            attempt = 1
        } else if attemptsSoFar == 0 {
            return .stop(.neverConnected)
        } else {
            attempt = attemptsSoFar + 1
        }
        guard attempt <= policy.maxAttempts else { return .stop(.gaveUp) }
        return .retry(after: delay(forAttempt: attempt, policy: policy, jitterSample: jitterSample), attempt: attempt)
    }

    /// Twice as long each time, up to `maxDelay`, then moved by up to `jitter`
    /// of itself either way.
    static func delay(forAttempt attempt: Int, policy: Policy = standard, jitterSample: Double) -> TimeInterval {
        let steps = min(max(attempt, 1) - 1, 20)
        let base = min(policy.maxDelay, policy.firstDelay * pow(2, Double(steps)))
        let sample = min(max(jitterSample.isFinite ? jitterSample : 0.5, 0), 1)
        return base * (1 + policy.jitter * (2 * sample - 1))
    }
}
