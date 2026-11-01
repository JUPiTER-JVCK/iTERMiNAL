import Foundation

/// Running one command on a saved host from a script, with no terminal tab:
/// the scripting API's `host.exec` and `iterminalctl exec`. Foundation only, so
/// the rules are checked in CI; `ScriptedCommandRunner` starts the process.
///
/// This reaches further than anything else the API does, so it is held back in
/// every way there is:
///
/// - the API itself is off until it is turned on, and needs its token;
/// - **a host must be ticked "Allow scripted commands"**, per host, in
///   Settings → Connections. That is off for every host, and an imported
///   snapshot cannot turn it on;
/// - it runs `ssh` the way the port scan does: no keyboard, `BatchMode`, so it
///   never prompts and never sees a password, and a host not yet trusted fails
///   rather than being trusted on the strength of a script. It can ride the
///   sign-in a terminal tab to the same host has left open;
/// - no agent forwarding, no forwards, no terminal, nothing on its standard
///   input;
/// - a time limit, a limit on how many run at once, and a limit on what is
///   read back;
/// - each one is noted in Settings → Security, with the command masked.
enum ScriptedCommand {
    static let maxLength = 4_000
    static let maxArguments = 100
    static let defaultTimeout: TimeInterval = 30
    static let maxTimeout: TimeInterval = 120
    /// Characters of each of the output and the error output sent back.
    static let maxOutputCharacters = 200_000
    static let maxConcurrent = 3
    /// Characters of a command kept for the note in Settings.
    static let excerptLength = 120

    // MARK: The command

    enum Problem: Error, Equatable {
        case missing, both, empty, tooLong, tooManyWords, controlCharacter

        var message: String {
            switch self {
            case .missing: return "Give a command, or the words of one."
            case .both: return "Give either a command or its words, not both."
            case .empty: return "The command is empty."
            case .tooLong: return "A command is at most \(ScriptedCommand.maxLength) characters."
            case .tooManyWords: return "A command is at most \(ScriptedCommand.maxArguments) words."
            case .controlCharacter: return "The command has a control character in it. A line break and a tab are fine."
            }
        }
    }

    /// The line the host's shell is given.
    ///
    /// `command` is used as written — it may be a pipeline, or a few lines of
    /// script. `arguments` are the words of one command, each quoted so the
    /// host's shell reads them as exactly what they are, with no expansion.
    static func commandLine(command: String?, arguments: [String]?) -> Result<String, Problem> {
        switch (command, arguments) {
        case (nil, nil):
            return .failure(.missing)
        case (.some, .some):
            return .failure(.both)
        case (.some(let text), nil):
            let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { return .failure(.empty) }
            if !isPlain(line) { return .failure(.controlCharacter) }
            if line.count > maxLength { return .failure(.tooLong) }
            return .success(line)
        case (nil, .some(let words)):
            guard let first = words.first, !first.isEmpty else { return .failure(.empty) }
            if words.count > maxArguments { return .failure(.tooManyWords) }
            if !words.allSatisfy(isPlain) { return .failure(.controlCharacter) }
            let line = words.map(EditorCommand.quote).joined(separator: " ")
            return line.count > maxLength ? .failure(.tooLong) : .success(line)
        }
    }

    /// No control character but a line break and a tab.
    private static func isPlain(_ text: String) -> Bool {
        !text.unicodeScalars.contains { scalar in
            if scalar == "\n" || scalar == "\t" { return false }
            return scalar.value < 0x20 || scalar.value == 0x7F
        }
    }

    /// How long to wait: the default when nothing sensible is asked for, and
    /// never less than a second or more than `maxTimeout`.
    static func timeout(_ requested: Double?) -> TimeInterval {
        guard let requested, requested.isFinite, requested > 0 else { return defaultTimeout }
        return min(max(requested, 1), maxTimeout)
    }

    // MARK: The host

    /// Why `connection` cannot be used for this, or nil when it can. The first
    /// check is the one that matters: a host is out of reach until it is ticked.
    static func refusal(for connection: SSHConnection) -> String? {
        let name = connection.name.trimmingCharacters(in: .whitespaces).isEmpty ? connection.host : connection.name
        guard connection.allowScriptedCommands else {
            return "\(name) doesn't allow scripted commands. Tick “Allow scripted commands” for it in Settings → Connections to let scripts run commands there."
        }
        guard connection.transport == .ssh else {
            return "\(name) doesn't connect with ssh, so a command can't be run on it this way."
        }
        guard !connection.host.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "\(name) has no address yet."
        }
        if let problem = connection.jumpHostsProblem { return JumpHosts.refusal(problem) }
        return nil
    }

    // MARK: What came back

    struct Outcome: Equatable {
        enum Kind: Equatable {
            /// The command ran and exited with this status.
            case ran(exit: Int)
            /// `ssh` itself failed: it could not connect, or sign in.
            case failed(reason: String, needsSignIn: Bool)
            case timedOut
        }
        var kind: Kind
        var output: String
        var errorOutput: String
        var outputTruncated: Bool
        var errorTruncated: Bool
    }

    /// 255 is `ssh` failing; anything else is the command's own status. (A
    /// command that itself exits 255 cannot be told from that, which is how ssh
    /// is.)
    static func outcome(status: Int32, output: String, errorOutput: String, timedOut: Bool) -> Outcome {
        let (out, outCut) = cap(output)
        let (err, errCut) = cap(errorOutput)
        let kind: Outcome.Kind
        if timedOut {
            kind = .timedOut
        } else if status == 255 {
            kind = .failed(reason: TunnelPlan.summarise(errorOutput), needsSignIn: TunnelPlan.isSignInFailure(errorOutput))
        } else {
            kind = .ran(exit: Int(status))
        }
        return Outcome(kind: kind, output: out, errorOutput: err, outputTruncated: outCut, errorTruncated: errCut)
    }

    /// An outcome that never started: ssh was not there, or would not run.
    static func notStarted(_ reason: String) -> Outcome {
        Outcome(kind: .failed(reason: reason, needsSignIn: false), output: "", errorOutput: "", outputTruncated: false, errorTruncated: false)
    }

    static func cap(_ text: String) -> (String, Bool) {
        text.count > maxOutputCharacters ? (String(text.prefix(maxOutputCharacters)), true) : (text, false)
    }

    /// What goes back to the script: the result, or the reason it failed.
    static func reply(for outcome: Outcome, milliseconds: Int) -> Result<[String: Any], ScriptFailure> {
        switch outcome.kind {
        case .failed(let reason, let needsSignIn):
            let advice = needsSignIn ? "\n" + TunnelPlan.signInAdvice : ""
            return .failure(ScriptFailure(message: reason + advice))
        case .ran(let exit):
            return .success(fields(outcome, milliseconds: milliseconds, extra: ["exit": exit, "timedOut": false]))
        case .timedOut:
            // What was read before the time ran out is still worth having.
            return .success(fields(outcome, milliseconds: milliseconds, extra: ["timedOut": true]))
        }
    }

    struct ScriptFailure: Error, Equatable {
        var message: String
    }

    private static func fields(_ outcome: Outcome, milliseconds: Int, extra: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [
            "stdout": outcome.output,
            "stderr": outcome.errorOutput,
            "stdoutTruncated": outcome.outputTruncated,
            "stderrTruncated": outcome.errorTruncated,
            "durationMs": milliseconds,
        ]
        for (key, value) in extra { result[key] = value }
        return result
    }

    // MARK: The note in Settings

    /// A command for the note kept in Settings → Security: masked, on one line,
    /// and short.
    static func excerpt(of command: String) -> String {
        let flat = command.components(separatedBy: .newlines).joined(separator: " ⏎ ")
        let masked = SecretRedactor.redact(flat)
        return masked.count > excerptLength ? String(masked.prefix(excerptLength - 1)) + "…" : masked
    }

    /// How the note says it ended.
    static func summary(of outcome: Outcome) -> String {
        switch outcome.kind {
        case .ran(let exit): return exit == 0 ? "exit 0" : "exit \(exit)"
        case .timedOut: return "timed out"
        case .failed(let reason, _): return "didn't run: \(reason)"
        }
    }
}
