import Foundation

/// One line of "what you can do". `command` is something to run, kept apart
/// from the sentence so it can be shown in a box and copied.
struct RemoteStep: Equatable {
    var text: String
    var command: String?
}

/// A button the problem offers. Nothing here runs by itself: the commands are
/// only ever put in front of a person, in a terminal, to press Return on.
enum RemoteAction: Equatable {
    case tryAgain
    /// An `ssh` session to the host, in a tab. A real terminal, so it can ask
    /// for the password that the file browser cannot — and the file browser
    /// then uses the connection that tab leaves open (`SSHControlSocket`).
    case signInInTerminal
    /// A new tab on this Mac with `command` typed and not run.
    case runInLocalTerminal(label: String, command: String)
    case editConnection

    var title: String {
        switch self {
        case .tryAgain: return "Try Again"
        case .signInInTerminal: return "Sign In in a Terminal"
        case .runInLocalTerminal(let label, _): return label
        case .editConnection: return "Connection Settings…"
        }
    }
}

/// What went wrong reaching a host over SFTP, in terms a person can act on.
///
/// `sftp` reports a failure as a few lines of text on stderr, and the file
/// browser used to show them as they came, cut off after two:
/// `user@host: Permission denied (publickey,password,keyboard-interactive).`
/// says what the server did and nothing about what to do next — and the one
/// thing a person most needs to know is not in it at all: the file browser
/// runs `sftp` with no keyboard (`BatchMode=yes`), so it can't type a password
/// however right the password. What it can do is use a connection a terminal
/// tab has signed in and left open, so that is what the steps lead to.
///
/// This reads that text and says it plainly. It only ever *describes*; the
/// connection it was made for is kept so the wording and the commands name the
/// right host, port and key.
struct RemoteProblem: Equatable {
    enum Kind: Equatable {
        /// Every key was turned away. `methods` is what the server said it
        /// would accept, as `ssh` names them.
        case signInRefused(methods: [String])
        case tooManyAuthFailures
        /// `offending` is `ssh`'s own pointer into known_hosts, when it gave one.
        case hostKeyChanged(offending: String?)
        case identityFile(path: String, reason: String)
        case connectionRefused
        case timedOut
        case unreachable
        case hostNotFound
        case connectionDropped
        case noSFTP
        case pathNotFound
        case pathDenied
        case other
    }

    let kind: Kind
    let connection: SSHConnection
    /// What `sftp` printed, trimmed. Offered on request and never replaced by
    /// the summary: the exact text is what gets pasted into a search or a
    /// message to whoever runs the host.
    let output: String

    // MARK: Reading what sftp said

    /// Classifies `output`, the stderr of a failed `sftp` run.
    ///
    /// Rules run in order, most specific first, and the whole text is read: a
    /// refused connection and a refused sign-in both end in "Connection
    /// closed", which says nothing on its own.
    static func classify(output rawOutput: String, connection: SSHConnection) -> RemoteProblem {
        let output = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = output.lowercased()
        func has(_ needle: String) -> Bool { text.contains(needle) }
        func make(_ kind: Kind) -> RemoteProblem {
            RemoteProblem(kind: kind, connection: connection, output: output)
        }

        if has("remote host identification has changed") || has("host key verification failed")
            || (has("offending") && has("known_hosts")) {
            let line = capture(#"Offending \S+ key in (\S+:\d+)"#, in: output)?.dropFirst().first
            return make(.hostKeyChanged(offending: line))
        }
        if let groups = capture(#"Permissions \d+ for '(.+?)' are too open"#, in: output) {
            return make(.identityFile(path: groups[1], reason: "too open"))
        }
        if let groups = capture(#"Load key \"(.+?)\": (.+)"#, in: output) {
            return make(.identityFile(path: groups[1], reason: groups[2].trimmingCharacters(in: .whitespaces)))
        }
        if has("too many authentication failures") {
            return make(.tooManyAuthFailures)
        }
        if let groups = capture(#"Permission denied \(([^)]*)\)"#, in: output) {
            let methods = groups[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            // A named identity file that is not there is the likelier story
            // than the key simply not being authorised, and `ssh` only warns.
            if let missing = capture(#"Identity file (.+?) not accessible"#, in: output) {
                return make(.identityFile(path: missing[1], reason: "missing"))
            }
            return make(.signInRefused(methods: methods))
        }
        if has("permission denied, please try again") || has("no more authentication methods")
            || has("authentication failed") || has("no supported authentication methods") {
            return make(.signInRefused(methods: []))
        }
        if has("connection refused") {
            return make(.connectionRefused)
        }
        if has("timed out") || has("timeout") {
            return make(.timedOut)
        }
        if has("no route to host") || has("network is unreachable") || has("host is down") {
            return make(.unreachable)
        }
        if has("could not resolve hostname") || has("name or service not known")
            || has("nodename nor servname") || has("temporary failure in name resolution") {
            return make(.hostNotFound)
        }
        // After a sign-in that worked: the service behind it would not start,
        // or something printed on the way in and broke the protocol.
        if has("subsystem request failed") || has("received message too long")
            || has("couldn't read packet") || has("message too long") {
            return make(.noSFTP)
        }
        // `sftp` ends nearly every failure with a bare "Connection closed",
        // which only means something when nothing else was said.
        if has("connection closed by") || has("connection reset by") || has("kex_exchange_identification")
            || has("broken pipe") || (has("connection closed") && meaningfulLines(output).isEmpty) {
            return make(.connectionDropped)
        }
        // From a sign-in that worked and a path that did not.
        if has("no such file or directory") || has("not found") {
            return make(.pathNotFound)
        }
        if has("permission denied") {
            return make(.pathDenied)
        }
        return make(.other)
    }

    /// The lines that say something: not the trailing "Connection closed" every
    /// failed run ends with, and not the first-connection notice that arrives
    /// even when everything worked.
    static func meaningfulLines(_ output: String) -> [String] {
        output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter {
            !$0.isEmpty && $0 != "Connection closed" && !$0.hasPrefix("Warning: Permanently added")
        }
    }

    /// The watchdog killed `sftp` before it said anything.
    static func timedOut(connection: SSHConnection) -> RemoteProblem {
        RemoteProblem(kind: .timedOut, connection: connection, output: "")
    }

    private static func capture(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        else { return nil }
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : (text as NSString).substring(with: range)
        }
    }

    // MARK: Saying it

    private var host: String { connection.host }
    private var destination: String { connection.destination }
    private var portNote: String { connection.port == 22 ? "" : " on port \(connection.port)" }

    /// The one line — enough to read in a narrow strip.
    var title: String {
        switch kind {
        case .signInRefused: return "Couldn't sign in to \(destination)"
        case .tooManyAuthFailures: return "\(host) hung up after too many keys"
        case .hostKeyChanged: return "\(host) has a different host key than before"
        case .identityFile: return "The identity file can't be used"
        case .connectionRefused: return "\(host) refused the connection"
        case .timedOut: return "\(host) didn't answer"
        case .unreachable: return "Can't reach \(host)"
        case .hostNotFound: return "Can't find \(host)"
        case .connectionDropped: return "\(host) closed the connection"
        case .noSFTP: return "SFTP isn't working on \(host)"
        case .pathNotFound: return "That folder isn't on \(host)"
        case .pathDenied: return "\(host) won't let this account open that"
        case .other: return "Couldn't reach \(destination) over SFTP"
        }
    }

    /// Why, in a sentence or three.
    var explanation: String {
        switch kind {
        case .signInRefused(let methods):
            let offered = Self.describe(methods)
            let cannot = "The file browser can't type a password — iTERMiNAL never handles one — so it signs in "
                + "with a key, or through a terminal tab you have signed in to."
            if methods.isEmpty {
                return "\(host) answered but didn't accept the sign-in. \(cannot)"
            }
            if methods.contains("publickey") {
                let others = methods.filter { $0 != "publickey" }
                let also = others.isEmpty ? "" : " It also allows \(Self.describe(others)), which the file browser can't ask for."
                return "\(host) answered, but none of the keys this Mac offered is installed there.\(also) \(cannot)"
            }
            return "\(host) only accepts \(offered), and the file browser can't type one — iTERMiNAL never handles "
                + "passwords. It can use a terminal tab you have signed in to, though."
        case .tooManyAuthFailures:
            return "ssh offers every key in your agent one after another, and \(host) hung up before it reached "
                + "the right one — servers allow only a few attempts."
        case .hostKeyChanged(let offending):
            let where_ = offending.map { " (\($0))" } ?? ""
            return "This Mac remembers a different host key for \(host)\(where_) than the one it presented now. "
                + "That is normal after a machine is reinstalled or an address is handed to another one — and it "
                + "is also what an intercepted connection looks like, so iTERMiNAL stops here instead of carrying on."
        case .identityFile(let path, let reason):
            switch reason {
            case "missing":
                return "The identity file \(path) doesn't exist or can't be read, so no key was offered."
            case "too open":
                return "ssh won't use \(path) because other users on this Mac can read it."
            default:
                return "ssh couldn't load \(path): \(reason)."
            }
        case .connectionRefused:
            return "Nothing is accepting SSH connections at \(host)\(portNote)."
        case .timedOut:
            return "No answer came back from \(host)\(portNote) in time. It may be asleep or off, on a different "
                + "network, or behind a firewall that drops the connection without saying so."
        case .unreachable:
            return "There is no route from this Mac to \(host)\(portNote): it is on a network this Mac isn't on, "
                + "or macOS is not letting iTERMiNAL reach devices on your local network."
        case .hostNotFound:
            return "The name \(host) didn't turn into an address."
        case .connectionDropped:
            return "\(host) accepted the connection and then closed it before signing in. Servers do that when a "
                + "limit is reached — too many connections, or too many failed attempts — when a firewall or ban "
                + "list steps in, or while the SSH service is restarting."
        case .noSFTP:
            return "Signing in worked, but the file transfer service didn't start. Either SFTP is switched off on "
                + "\(host), or the account prints text when it logs in — from .zshrc, .bashrc or a login banner — "
                + "which breaks the file protocol."
        case .pathNotFound:
            return "The folder was moved or deleted, or the start directory saved for this host is wrong."
        case .pathDenied:
            return "\(connection.username.isEmpty ? "This account" : connection.username) doesn't have permission "
                + "to open it on \(host)."
        case .other:
            return Self.meaningfulLines(output).last ?? "sftp stopped without saying why."
        }
    }

    /// What to do about it, in order.
    var steps: [RemoteStep] {
        switch kind {
        case .signInRefused(let methods):
            let signIn = RemoteStep(
                text: "Press Sign In in a Terminal and enter the password there. The file browser then uses that tab's "
                    + "connection: the password goes to ssh in the tab, never to iTERMiNAL.",
                command: nil
            )
            if !methods.isEmpty, !methods.contains("publickey") {
                return [
                    signIn,
                    RemoteStep(
                        text: "Keep the tab open while you browse. Closing it closes the connection the file browser is using.",
                        command: nil
                    ),
                    RemoteStep(text: "Then press Try Again.", command: nil),
                    RemoteStep(
                        text: "Or ask whoever runs \(host) to allow key sign-in (PubkeyAuthentication yes), which needs no open tab.",
                        command: nil
                    ),
                ]
            }
            return [
                RemoteStep(
                    text: "Install a key on \(host). This makes a key if you have none, then installs it, and asks for "
                        + "\(host)'s password once. Press Return to run it; after that this host needs no password:",
                    command: Self.keyLoginCommand(for: connection)
                ),
                RemoteStep(
                    text: "A key that isn't in ~/.ssh: name it under Settings → Connections → Identity file.",
                    command: nil
                ),
                RemoteStep(
                    text: "A key with a passphrase has to be in the agent first, so nothing needs to ask for it:",
                    command: "ssh-add --apple-use-keychain \(Self.identityPath(for: connection))"
                ),
                RemoteStep(
                    text: "Or sign in with the password instead: press Sign In in a Terminal and enter it there. The file "
                        + "browser uses that tab's connection for as long as the tab stays open, and retries by itself "
                        + "once it is signed in.",
                    command: nil
                ),
                RemoteStep(text: "Then press Try Again.", command: nil),
            ]
        case .tooManyAuthFailures:
            let named = connection.identityFile.map { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? false
            return [
                RemoteStep(
                    text: named
                        ? "Only the identity file set for this host is offered. Check it is the right one, and installed on \(host):"
                        : "Name the one key to use under Settings → Connections → Identity file. iTERMiNAL then offers only that key.",
                    command: named ? Self.keySetupCommand(for: connection) : nil
                ),
            ]
        case .hostKeyChanged:
            return [
                RemoteStep(
                    text: "If you know why it changed, forget the old key and try again:",
                    command: Self.forgetHostKeyCommand(for: connection)
                ),
                RemoteStep(text: "If you don't, don't carry on — ask whoever runs the machine.", command: nil),
            ]
        case .identityFile(let path, let reason):
            switch reason {
            case "too open":
                return [RemoteStep(text: "Make the key readable by you alone:", command: "chmod 600 \(Self.shellQuoted(path))")]
            default:
                return [RemoteStep(
                    text: "Check the path under Settings → Connections → Identity file, or clear it to use your usual keys.",
                    command: nil
                )]
            }
        case .connectionRefused:
            return [
                RemoteStep(text: "Check the address and port under Settings → Connections.", command: nil),
                RemoteStep(
                    text: "On a Mac, turn on Remote Login: System Settings → General → Sharing.",
                    command: nil
                ),
                RemoteStep(text: "Elsewhere, make sure sshd is running and the firewall allows port \(connection.port).", command: nil),
            ]
        case .timedOut:
            return [
                RemoteStep(text: "Check this Mac is on the same network or VPN as \(host).", command: nil),
                RemoteStep(
                    text: "Test whether the port answers at all:",
                    command: "nc -vz \(Self.shellQuoted(host)) \(connection.port)"
                ),
            ]
        case .unreachable:
            return [
                RemoteStep(text: "Join the same Wi-Fi, or connect the VPN, then try again.", command: nil),
                RemoteStep(
                    text: "For a device on your own network: System Settings → Privacy & Security → Local Network, and allow iTERMiNAL.",
                    command: nil
                ),
            ]
        case .hostNotFound:
            return [
                RemoteStep(text: "Check the spelling under Settings → Connections, or use the IP address.", command: nil),
                RemoteStep(text: "Names ending in .local only resolve on the same network.", command: nil),
            ]
        case .connectionDropped:
            return [
                RemoteStep(text: "Wait a minute and try again — a limit may simply have been reached.", command: nil),
                RemoteStep(text: "If you run \(host), its SSH log says why it hung up.", command: nil),
            ]
        case .noSFTP:
            return [
                RemoteStep(text: "A plain login should print nothing. Check:", command: "ssh \(Self.shellQuoted(destination)) true"),
                RemoteStep(
                    text: "Put any echo or banner lines in the account's startup files behind a check for an interactive shell.",
                    command: nil
                ),
                RemoteStep(text: "If you run \(host), it needs a `Subsystem sftp` line in sshd_config.", command: nil),
            ]
        case .pathNotFound:
            return [RemoteStep(
                text: "Clear the start directory under Settings → Connections to open the account's home folder.",
                command: nil
            )]
        case .pathDenied:
            return []
        case .other:
            return [RemoteStep(
                text: "Try again. If it keeps failing, a terminal session to this host shows the full error.",
                command: nil
            )]
        }
    }

    /// The buttons that go with it, in the order to show them.
    var actions: [RemoteAction] {
        switch kind {
        case .signInRefused(let methods):
            var list: [RemoteAction] = [.tryAgain]
            if methods.isEmpty || methods.contains("publickey") {
                list.append(.runInLocalTerminal(label: "Set Up Key…", command: Self.keyLoginCommand(for: connection)))
            }
            list.append(.signInInTerminal)
            list.append(.editConnection)
            return list
        case .tooManyAuthFailures, .identityFile, .connectionRefused, .timedOut, .unreachable, .hostNotFound:
            return [.tryAgain, .editConnection]
        case .hostKeyChanged:
            return [
                .tryAgain,
                .runInLocalTerminal(label: "Forget Old Key…", command: Self.forgetHostKeyCommand(for: connection)),
            ]
        case .connectionDropped, .noSFTP:
            return [.tryAgain, .signInInTerminal, .editConnection]
        case .pathNotFound:
            return [.tryAgain, .editConnection]
        case .pathDenied, .other:
            return [.tryAgain]
        }
    }

    // MARK: Words and commands

    /// `["publickey", "password"]` as "a key or a password".
    static func describe(_ methods: [String]) -> String {
        let names = methods.map { method -> String in
            switch method {
            case "publickey": return "a key"
            case "password": return "a password"
            case "keyboard-interactive": return "a keyboard-interactive prompt"
            case "gssapi-with-mic", "gssapi-keyex": return "Kerberos"
            default: return method
            }
        }
        switch names.count {
        case 0: return "nothing it recognised"
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " or " + names[names.count - 1]
        }
    }

    /// Where the key lives, for a command that names it.
    private static func identityPath(for connection: SSHConnection) -> String {
        let named = connection.identityFile?.trimmingCharacters(in: .whitespaces) ?? ""
        return named.isEmpty ? "~/.ssh/id_ed25519" : pathForShell(named)
    }

    /// `ssh-copy-id` for this connection: the port, the jump hosts and the key
    /// it names, if any. Run on this Mac, it asks for the host's password once
    /// and leaves the key in `authorized_keys`.
    static func keySetupCommand(for connection: SSHConnection) -> String {
        var parts = ["ssh-copy-id"]
        if connection.port != 22 { parts += ["-p", String(connection.port)] }
        if let jump = JumpHosts.proxyJumpValue(connection.jumpHosts), connection.transport == .ssh {
            // Quoted: a bracketed IPv6 address is a pattern to some shells.
            parts += ["-o", shellQuoted("ProxyJump=\(jump)")]
        }
        if let identity = connection.identityFile?.trimmingCharacters(in: .whitespaces), !identity.isEmpty {
            parts += ["-i", pathForShell(identity)]
        }
        parts.append(shellQuoted(connection.destination))
        return parts.joined(separator: " ")
    }

    /// Everything it takes to get from no key to key sign-in, as one line to
    /// press Return on: make the key if it is not there (`ssh-keygen` asks for a
    /// passphrase itself, so whether to have one is the person's choice), then
    /// `keySetupCommand`. `;` rather than `&&`, so it reads the same in fish.
    /// Nothing runs from here: it is typed into a tab and waits.
    static func keyLoginCommand(for connection: SSHConnection) -> String {
        let named = connection.identityFile?.trimmingCharacters(in: .whitespaces) ?? ""
        let key = identityPath(for: connection)
        var make = "ssh-keygen -t ed25519"
        if !named.isEmpty { make += " -f \(key)" }
        return "test -f \(key) || \(make); \(keySetupCommand(for: connection))"
    }

    /// Removes the host's entry from known_hosts. A host on another port is
    /// recorded as `[host]:port`.
    static func forgetHostKeyCommand(for connection: SSHConnection) -> String {
        let entry = connection.port == 22 ? connection.host : "[\(connection.host)]:\(connection.port)"
        return "ssh-keygen -R \(shellQuoted(entry))"
    }

    /// A path for a command line: `~/` is left to the shell, the rest quoted
    /// only if it needs it.
    private static func pathForShell(_ path: String) -> String {
        if path.hasPrefix("~/") { return "~/" + shellQuoted(String(path.dropFirst(2))) }
        return shellQuoted(path)
    }

    /// `value` as one shell word: as it is when nothing in it is special,
    /// single-quoted when something is.
    static func shellQuoted(_ value: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./_-")
        if !value.isEmpty, value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
