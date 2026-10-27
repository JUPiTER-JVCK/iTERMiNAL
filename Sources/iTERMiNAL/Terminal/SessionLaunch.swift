import Foundation

/// What a terminal session is: this Mac's shell, a remote host reached
/// through one of the saved connections, or one of the bundled full-screen
/// tools running in a side panel.
enum SessionKind: Equatable {
    case localShell
    case remote(UUID)
    case tool(TerminalTool)

    var connectionID: UUID? {
        if case .remote(let id) = self { return id }
        return nil
    }

    var isRemote: Bool { connectionID != nil }

    var tool: TerminalTool? {
        if case .tool(let tool) = self { return tool }
        return nil
    }

    /// A program that owns the whole screen, not a shell. Nothing that types
    /// commands — the composer — should ever send them here.
    var isTool: Bool { tool != nil }
}

enum SessionLaunchError: LocalizedError {
    case unknownConnection
    case missingExecutable(String)
    case emptyCustomCommand
    case toolUnavailable(TerminalTool)
    /// The jump hosts written for a connection cannot be used. Refused rather
    /// than connected to directly: a host that is meant to be reached through a
    /// bastion is not to be reached any other way by accident.
    case invalidJumpHosts(String)

    var errorDescription: String? {
        switch self {
        case .invalidJumpHosts(let problem):
            return JumpHosts.refusal(problem)
        case .unknownConnection:
            return "That saved connection no longer exists."
        case .missingExecutable(let name):
            return "Couldn't find \(name) on this Mac. Install it, or point the connection at a custom command."
        case .emptyCustomCommand:
            return "This connection uses a custom command, but none is set."
        case .toolUnavailable(let tool):
            // Release builds always carry both tools — CI refuses to publish
            // one that does not — so this is a local build made without them.
            return "This build of iTERMiNAL was made without \(tool.title), and it isn't installed on this Mac either. Release builds include it; for a local build, run scripts/fetch-superfile.sh or scripts/build-btop.sh."
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
    /// `controlPath` is for a session whose sign-in the file browser is to
    /// share: `ssh` listens there once it is signed in (see `SSHControlSocket`).
    static func configuration(
        for kind: SessionKind,
        settings: AppSettings,
        directory: String?,
        shellOverride: String? = nil,
        controlPath: String? = nil,
        agentApproved: Bool = false
    ) -> Result<TerminalLaunchConfiguration, SessionLaunchError> {
        switch kind {
        case .localShell:
            let shell = settings.resolvedShell(override: shellOverride)
            return .success(TerminalLaunchConfiguration(
                executable: shell.path,
                args: shell.args,
                execName: shell.execName,
                environment: environment(colors: settings.outputColors),
                initialDirectory: directory ?? settings.resolvedInitialDirectory
            ))

        case .remote(let id):
            guard let connection = settings.sshConnections.first(where: { $0.id == id }) else {
                return .failure(.unknownConnection)
            }
            return remoteConfiguration(connection, controlPath: controlPath, agentApproved: agentApproved)

        case .tool(let tool):
            guard let executable = tool.resolvedExecutable else {
                return .failure(.toolUnavailable(tool))
            }
            // Run directly, not through a shell: there is nothing to expand,
            // and a shell in between would outlive the tool as a prompt the
            // user never asked for once they quit it.
            let cwd = directory ?? settings.resolvedInitialDirectory
            // Dressed in the terminal's colours from the first frame. There
            // may be no view yet to ask for its colour scheme — the store
            // starts a tool before its panel is drawn — so the appearance
            // comes from the app, which is what that scheme follows anyway.
            let theme = settings.resolvedTerminalTheme(darkMode: settings.isDarkAppearance)
            return .success(TerminalLaunchConfiguration(
                executable: executable,
                args: ToolTheming.launchArguments(for: tool, theme: theme)
                    + tool.arguments(directory: cwd),
                execName: nil,
                environment: environment(),
                initialDirectory: cwd
            ))
        }
    }

    /// `agentApproved` is the answer to "forward your agent?" for a connection
    /// set to ask; every other choice ignores it.
    private static func remoteConfiguration(
        _ connection: SSHConnection,
        controlPath: String? = nil,
        agentApproved: Bool = false
    ) -> Result<TerminalLaunchConfiguration, SessionLaunchError> {
        var executable: String
        var args: [String] = []

        // The file browser speaks SSH whatever the saved transport is, so a
        // sign-in made for it is an `ssh` one too.
        let transport: SSHTransport = controlPath == nil ? connection.transport : .ssh
        switch transport {
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
            // Arguments written for mosh or a custom command are not ssh's.
            if connection.transport == .ssh {
                if let problem = connection.jumpHostsProblem {
                    return .failure(.invalidJumpHosts(problem))
                }
                args.append(contentsOf: tokenize(connection.extraArguments))
                // After the person's own arguments, like the control path
                // below: ssh keeps the first value it is given for an option,
                // so a `-J` or `-A` written by hand is theirs to keep.
                args.append(contentsOf: connection.proxyJumpArguments)
                args.append(contentsOf: connection.agentForwarding.arguments(approved: agentApproved))
            }
            if let controlPath {
                // After the person's own arguments, so a ControlPath they chose
                // is theirs to keep: where ssh is given an option twice, the
                // first one counts. A socket left by an ssh that was killed
                // would stop this one from listening, so it goes first.
                SSHControlSocket.removeStale(controlPath)
                args.append(contentsOf: SSHControlSocket.masterArguments(path: controlPath))
            }
            if let remoteCommand = connection.startupCommand {
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

    private static func substitutePlaceholders(_ command: String, _ connection: SSHConnection) -> String {
        command
            .replacingOccurrences(of: "%h", with: connection.host)
            .replacingOccurrences(of: "%p", with: String(connection.port))
            .replacingOccurrences(of: "%u", with: connection.username)
            .replacingOccurrences(of: "%d", with: connection.destination)
    }

    /// `colors` is for a shell, whose `ls` and `man` print for a person to read:
    /// remote sessions, which have another machine's environment, and the
    /// bundled tools, which draw their own colours, do not get it.
    static func environment(colors: OutputColors? = nil) -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["TERM_PROGRAM"] = "iTERMiNAL"
        if let colors {
            // Only what is not set already, and the shell's own startup files
            // run after this — so a person's `.zshrc` has the last word.
            for (name, value) in colors.environment(inheriting: env) { env[name] = value }
        }
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
