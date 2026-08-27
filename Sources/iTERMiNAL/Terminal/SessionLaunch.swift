import Foundation

/// What a terminal session is: this Mac's shell, or a remote host reached
/// through one of the saved connections.
enum SessionKind: Equatable {
    case localShell
    case remote(UUID)

    var connectionID: UUID? {
        if case .remote(let id) = self { return id }
        return nil
    }

    var isRemote: Bool { connectionID != nil }
}

enum SessionLaunchError: LocalizedError {
    case unknownConnection
    case missingExecutable(String)
    case emptyCustomCommand

    var errorDescription: String? {
        switch self {
        case .unknownConnection:
            return "That saved connection no longer exists."
        case .missingExecutable(let name):
            return "Couldn't find \(name) on this Mac. Install it, or point the connection at a custom command."
        case .emptyCustomCommand:
            return "This connection uses a custom command, but none is set."
        }
    }
}

/// Builds the launch configuration for a session.
///
/// A remote session is just the system's own client running inside the PTY —
/// no embedded SSH stack. Because it gets a real TTY (unlike the SFTP
/// provider, which must run non-interactively), password and 2FA prompts work
/// normally and no credential ever passes through this app.
enum SessionLaunch {
    static func configuration(
        for kind: SessionKind,
        settings: AppSettings,
        directory: String?
    ) -> Result<TerminalLaunchConfiguration, SessionLaunchError> {
        switch kind {
        case .localShell:
            let shell = settings.resolvedShell()
            return .success(TerminalLaunchConfiguration(
                executable: shell.path,
                args: shell.args,
                execName: shell.execName,
                environment: environment(),
                initialDirectory: directory ?? settings.resolvedInitialDirectory
            ))

        case .remote(let id):
            guard let connection = settings.sshConnections.first(where: { $0.id == id }) else {
                return .failure(.unknownConnection)
            }
            return remoteConfiguration(connection)
        }
    }

    private static func remoteConfiguration(
        _ connection: SSHConnection
    ) -> Result<TerminalLaunchConfiguration, SessionLaunchError> {
        var executable: String
        var args: [String] = []

        switch connection.transport {
        case .ssh:
            guard let path = resolveExecutable("ssh") else {
                return .failure(.missingExecutable("ssh"))
            }
            executable = path
            if connection.port != 22 {
                args.append(contentsOf: ["-p", String(connection.port)])
            }
            if let identity = connection.identityFile?.trimmingCharacters(in: .whitespaces), !identity.isEmpty {
                args.append(contentsOf: ["-i", (identity as NSString).expandingTildeInPath])
            }
            args.append(contentsOf: tokenize(connection.extraArguments))
            if let remoteCommand = startupCommand(for: connection) {
                // -t forces a TTY so the login shell behaves interactively.
                args.append("-t")
                args.append(connection.destination)
                args.append(remoteCommand)
            } else {
                args.append(connection.destination)
            }

        case .mosh:
            guard let path = resolveExecutable("mosh") else {
                return .failure(.missingExecutable("mosh"))
            }
            executable = path
            if connection.port != 22 {
                args.append(contentsOf: ["--ssh", "ssh -p \(connection.port)"])
            }
            args.append(contentsOf: tokenize(connection.extraArguments))
            args.append(connection.destination)

        case .custom:
            let tokens = tokenize(substitutePlaceholders(connection.customCommand, connection))
            guard let first = tokens.first, !first.isEmpty else {
                return .failure(.emptyCustomCommand)
            }
            guard let path = first.contains("/") ? first : resolveExecutable(first) else {
                return .failure(.missingExecutable(first))
            }
            executable = path
            args = Array(tokens.dropFirst())
        }

        return .success(TerminalLaunchConfiguration(
            executable: executable,
            args: args,
            execName: nil,
            environment: environment(),
            initialDirectory: NSHomeDirectory()
        ))
    }

    /// `cd <path> && exec $SHELL -l` when the connection names a start
    /// directory, so the remote session opens where the user expects.
    private static func startupCommand(for connection: SSHConnection) -> String? {
        guard let path = connection.initialPath?.trimmingCharacters(in: .whitespaces),
              !path.isEmpty else { return nil }
        return "cd \(singleQuoted(path)) && exec \\$SHELL -l"
    }

    private static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func substitutePlaceholders(_ command: String, _ connection: SSHConnection) -> String {
        command
            .replacingOccurrences(of: "%h", with: connection.host)
            .replacingOccurrences(of: "%p", with: String(connection.port))
            .replacingOccurrences(of: "%u", with: connection.username)
            .replacingOccurrences(of: "%d", with: connection.destination)
    }

    static func environment() -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["TERM_PROGRAM"] = "iTERMiNAL"
        return env.map { "\($0.key)=\($0.value)" }
    }

    /// Splits a command string into argv, honouring single and double quotes
    /// so paths with spaces survive.
    static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        // Tracks "a token has begun", so an explicitly quoted empty string
        // survives while runs of whitespace don't produce blank tokens.
        var started = false

        for character in input {
            if let active = quote {
                if character == active {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
                started = true
            } else if character == " " || character == "\t" {
                if started {
                    tokens.append(current)
                    current = ""
                    started = false
                }
            } else {
                current.append(character)
                started = true
            }
        }
        if started {
            tokens.append(current)
        }
        return tokens
    }

    /// Looks for a binary in the usual Homebrew/system locations, then PATH.
    static func resolveExecutable(_ name: String) -> String? {
        var candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/bin/\(name)",
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/\(name)" })
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
