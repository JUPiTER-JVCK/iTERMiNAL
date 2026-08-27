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
/// SFTP runs non-interactively and therefore needs keys/agent, while a terminal
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
    /// Extra flags passed through to the transport, e.g. "-A -J bastion".
    var extraArguments: String
    /// Full command line used when `transport == .custom` (Tailscale SSH,
    /// Eternal Terminal, a wrapper script…).
    var customCommand: String

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
        customCommand: String = ""
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
    }

    var destination: String {
        username.isEmpty ? host : "\(username)@\(host)"
    }

    var subtitle: String {
        let base = port == 22 ? destination : "\(destination):\(port)"
        return transport == .ssh ? base : "\(base) · \(transport.label)"
    }
}
