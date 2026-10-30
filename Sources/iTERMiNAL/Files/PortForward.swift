import Foundation

// Port forwards and the connection options that sit beside them. Foundation
// only, so what ends up on an `ssh` command line is checked off a Mac like the
// rest of the connection logic: the values are validated here, and nothing a
// person typed reaches an argument without passing through it.

/// One forwarding rule on a saved connection, in the three forms `ssh` has.
struct PortForward: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        /// `-L`: a port on this Mac that leads to `targetHost:targetPort` as
        /// the host sees it.
        case local
        /// `-R`: a port on the host that leads back to `targetHost:targetPort`
        /// as this Mac sees it.
        case remote
        /// `-D`: a SOCKS5 proxy on this Mac that sends whatever it is asked for
        /// out through the host.
        case dynamic

        var id: String { rawValue }

        var label: String {
            switch self {
            case .local: return "Local (-L)"
            case .remote: return "Remote (-R)"
            case .dynamic: return "SOCKS5 (-D)"
            }
        }

        var flag: String {
            switch self {
            case .local: return "-L"
            case .remote: return "-R"
            case .dynamic: return "-D"
            }
        }
    }

    var id: UUID
    var kind: Kind
    /// The port that listens: on this Mac for `local` and `dynamic`, on the host
    /// for `remote`.
    var bindPort: Int
    /// Where it leads. Unused by `dynamic`.
    var targetHost: String
    var targetPort: Int

    init(
        id: UUID = UUID(),
        kind: Kind = .local,
        bindPort: Int = 8080,
        targetHost: String = "localhost",
        targetPort: Int = 80
    ) {
        self.id = id
        self.kind = kind
        self.bindPort = bindPort
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = (try? container.decodeIfPresent(Kind.self, forKey: .kind)) ?? .local
        bindPort = try container.decodeIfPresent(Int.self, forKey: .bindPort) ?? 8080
        targetHost = try container.decodeIfPresent(String.self, forKey: .targetHost) ?? "localhost"
        targetPort = try container.decodeIfPresent(Int.self, forKey: .targetPort) ?? 80
    }

    /// Why this rule cannot be used, in a clause, or nil when it can.
    var problem: String? {
        guard (1024...65535).contains(bindPort) else {
            return "The listening port must be between 1024 and 65535; lower ones need root."
        }
        guard kind != .dynamic else { return nil }
        guard PortForward.isPlainHost(targetHost) else {
            return "“\(targetHost)” isn't a host name or address ssh would accept here."
        }
        guard (1...65535).contains(targetPort) else {
            return "The target port must be between 1 and 65535."
        }
        return nil
    }

    var isValid: Bool { problem == nil }

    /// The value after the flag. Always bound to the loopback address, so a
    /// forward is reachable from this Mac (or, for `remote`, from the host) and
    /// from nothing else on the network — opening one to the network is a
    /// decision to make in `~/.ssh/config`, not a side effect of a text field.
    var specification: String {
        switch kind {
        case .local, .remote:
            return "127.0.0.1:\(bindPort):\(targetHost):\(targetPort)"
        case .dynamic:
            return "127.0.0.1:\(bindPort)"
        }
    }

    /// The two arguments for `ssh`, or none for a rule that is not valid.
    var arguments: [String] {
        isValid ? [kind.flag, specification] : []
    }

    /// A short line for a list.
    var summary: String {
        switch kind {
        case .local: return "Local \(bindPort) → \(targetHost):\(targetPort)"
        case .remote: return "Remote \(bindPort) → \(targetHost):\(targetPort)"
        case .dynamic: return "SOCKS5 on \(bindPort)"
        }
    }

    /// A host name, an IPv4 address or `localhost`. IPv6 literals are left out:
    /// their colons would be read by `ssh` as separators, and brackets for them
    /// are one more thing to get wrong in a text field.
    static func isPlainHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253, !host.hasPrefix("-"), !host.hasPrefix(".") else { return false }
        return host.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39)
                || (scalar.value >= 0x41 && scalar.value <= 0x5A)
                || (scalar.value >= 0x61 && scalar.value <= 0x7A)
                || "._-".unicodeScalars.contains(scalar)
        }
    }
}

/// Which address family `ssh` is limited to.
enum IPFamily: String, Codable, CaseIterable, Identifiable {
    case any
    case v4
    case v6

    var id: String { rawValue }

    var label: String {
        switch self {
        case .any: return "Either"
        case .v4: return "IPv4 only"
        case .v6: return "IPv6 only"
        }
    }

    var arguments: [String] {
        switch self {
        case .any: return []
        case .v4: return ["-4"]
        case .v6: return ["-6"]
        }
    }
}

extension SSHConnection {
    static let keepAliveRange = 5...600

    /// What the connection's own options add to an `ssh` or `sftp` command line:
    /// the address family, compression and a keep-alive. Only ssh takes them —
    /// mosh and a custom command are not given arguments they may not know.
    ///
    /// Each is written only when it was asked for, so a connection that sets
    /// none leaves `~/.ssh/config` in charge, as it always did. Where the
    /// person's own extra arguments name the same option, theirs come first
    /// and ssh keeps the first it is given.
    var optionArguments: [String] {
        guard transport == .ssh else { return [] }
        var args = ipFamily.arguments
        if compression { args.append("-C") }
        if keepAliveSeconds > 0 {
            let seconds = min(max(keepAliveSeconds, Self.keepAliveRange.lowerBound), Self.keepAliveRange.upperBound)
            args.append(contentsOf: ["-o", "ServerAliveInterval=\(seconds)"])
        }
        return args
    }

    /// `-L`, `-R` and `-D` for each rule that can be used. A rule that cannot
    /// is left out, and `forwardProblems` says why, so the list never carries
    /// half of one onto a command line.
    var forwardArguments: [String] {
        guard transport == .ssh else { return [] }
        return forwards.flatMap(\.arguments)
    }

    /// One line per rule that cannot be used.
    var forwardProblems: [String] {
        forwards.compactMap { forward in
            forward.problem.map { "\(forward.summary): \($0)" }
        }
    }
}
