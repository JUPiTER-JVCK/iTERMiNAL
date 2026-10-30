import Foundation

/// A forward kept in Settings and run in the background: a rule from the
/// connection's own list (`PortForward`), pointed at one saved host, that can be
/// started and stopped without a terminal tab open. Foundation only, so what it
/// puts on a command line is checked off a Mac; `SavedTunnelRunner` runs it.
struct SavedTunnel: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    /// The saved SSH host it goes through. Nil until one is chosen.
    var connectionID: UUID?
    var forward: PortForward
    /// Start it when the app opens.
    var autoStart: Bool

    init(
        id: UUID = UUID(),
        name: String = "New tunnel",
        connectionID: UUID? = nil,
        forward: PortForward = PortForward(),
        autoStart: Bool = false
    ) {
        self.id = id
        self.name = name
        self.connectionID = connectionID
        self.forward = forward
        self.autoStart = autoStart
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Tunnel"
        connectionID = try container.decodeIfPresent(UUID.self, forKey: .connectionID)
        forward = (try? container.decodeIfPresent(PortForward.self, forKey: .forward)) ?? PortForward()
        autoStart = try container.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
    }

    /// One line for a list.
    var summary: String { forward.summary }
}

extension TunnelPlan {
    /// `ssh -N` carrying `forward` through `connection`, for a tunnel that lives
    /// as long as the process does. Nil when the rule cannot be used, so a rule
    /// with a problem never reaches a command line.
    ///
    /// Signs in the way every non-interactive run here does (`baseArguments`:
    /// key or agent, never a typed password). The person's own keep-alive, if
    /// the host sets one, comes first and so wins.
    static func savedArguments(for connection: SSHConnection, forward: PortForward) -> [String]? {
        guard forward.isValid else { return nil }
        var args = ["-N"]
        args.append(contentsOf: baseArguments(for: connection, sharedSocket: nil))
        args.append(contentsOf: ["-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=30"])
        args.append(contentsOf: forward.arguments)
        args.append(connection.destination)
        return args
    }

    /// The loopback port a tunnel listens on *here*, to check it came up. Nil
    /// for a remote forward, which listens on the host.
    static func localListeningPort(of forward: PortForward) -> Int? {
        switch forward.kind {
        case .local, .dynamic: return forward.bindPort
        case .remote: return nil
        }
    }
}
