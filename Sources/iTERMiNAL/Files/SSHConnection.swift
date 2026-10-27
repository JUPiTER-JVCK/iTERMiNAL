import Foundation

/// How a remote session is dialed. All three run a real command in a PTY, so
/// none of them require this app to handle credentials.
enum SSHTransport: String, Codable, CaseIterable, Identifiable {
    case ssh
    case mosh
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ssh: return "SSH"
        case .mosh: return "Mosh"
        case .custom: return "Custom command"
        }
    }

    /// The binary to look for, or nil when the user supplies the command.
    var executableName: String? {
        switch self {
        case .ssh: return "ssh"
        case .mosh: return "mosh"
        case .custom: return nil
        }
    }
}

/// A saved remote target, shared by the SFTP file browser and SSH terminal
/// sessions.
///
/// It deliberately holds no secret. Authentication is delegated to the system:
/// SFTP runs non-interactively and therefore needs keys/agent — or the
/// connection a terminal tab has signed in and left open — while a terminal
/// session has a real TTY, so ssh can prompt for a password or 2FA itself and
/// this app still never sees, stores, or transmits one.
struct SSHConnection: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var identityFile: String?
    var initialPath: String?
    var transport: SSHTransport
    /// Extra flags passed through to the transport, e.g. "-o ServerAliveInterval=30".
    /// Where one of them sets something the fields below also set, ssh keeps
    /// the first it is given, and these come first.
    var extraArguments: String
    /// Full command line used when `transport == .custom` (Tailscale SSH,
    /// Eternal Terminal, a wrapper script…).
    var customCommand: String
    /// Hosts to go through on the way, written as ssh's `-J` takes them:
    /// `[user@]host[:port]`, comma-separated. Empty connects directly. See
    /// `JumpHosts`, which decides what is acceptable.
    var jumpHosts: String
    /// Whether the ssh-agent's keys can be used from the host. See `AgentForwarding`.
    var agentForwarding: AgentForwarding

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        identityFile: String? = nil,
        initialPath: String? = nil,
        transport: SSHTransport = .ssh,
        extraArguments: String = "",
        customCommand: String = "",
        jumpHosts: String = "",
        agentForwarding: AgentForwarding = .sshConfig
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.identityFile = identityFile
        self.initialPath = initialPath
        self.transport = transport
        self.extraArguments = extraArguments
        self.customCommand = customCommand
        self.jumpHosts = jumpHosts
        self.agentForwarding = agentForwarding
    }

    /// Tolerant decoding so connections saved before transports existed still
    /// load instead of wiping the user's host list.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        identityFile = try container.decodeIfPresent(String.self, forKey: .identityFile)
        initialPath = try container.decodeIfPresent(String.self, forKey: .initialPath)
        transport = try container.decodeIfPresent(SSHTransport.self, forKey: .transport) ?? .ssh
        extraArguments = try container.decodeIfPresent(String.self, forKey: .extraArguments) ?? ""
        customCommand = try container.decodeIfPresent(String.self, forKey: .customCommand) ?? ""
        jumpHosts = try container.decodeIfPresent(String.self, forKey: .jumpHosts) ?? ""
        // A choice this build does not know — written by a newer one — falls
        // back to the default instead of failing the whole host list.
        agentForwarding = (try? container.decodeIfPresent(AgentForwarding.self, forKey: .agentForwarding)) ?? .sshConfig
    }

    var destination: String {
        username.isEmpty ? host : "\(username)@\(host)"
    }

    var subtitle: String {
        let base = port == 22 ? destination : "\(destination):\(port)"
        return transport == .ssh ? base : "\(base) · \(transport.label)"
    }

    /// What `ssh -t` runs on the host so a session opens where the connection's
    /// start directory is: `cd <path> && exec $SHELL -l`, or nil without one.
    ///
    /// `$SHELL` is for the *host's* shell to fill in. `ssh` is started directly,
    /// with no shell of this Mac's in between to read it, so a backslash in front
    /// of it — which would be right if there were one — arrives as a backslash,
    /// and the host is asked to run a program named `$SHELL`.
    var startupCommand: String? {
        guard let path = initialPath?.trimmingCharacters(in: .whitespaces), !path.isEmpty else { return nil }
        return "cd \(Self.remoteShellPath(path)) && exec $SHELL -l"
    }

    /// `path` as the host's shell should read it: single-quoted, but for a
    /// leading `~` or `~/`, which is left outside the quotes so the host fills in
    /// that account's home folder (inside them it would be a folder named `~`).
    static func remoteShellPath(_ path: String) -> String {
        func quoted(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        if path == "~" { return "~" }
        if path.hasPrefix("~/") { return "~/" + quoted(String(path.dropFirst(2))) }
        return quoted(path)
    }
}
