import Foundation

/// The `ssh` command lines the app runs for itself, apart from a terminal tab:
/// reading a host's listening ports, and carrying a forward. Foundation only,
/// so what is built is checked off a Mac; `PortScanner` and `TunnelManager` are
/// what start the processes.
///
/// Both run with no keyboard, so neither can ask for a password and neither
/// ever sees one: they sign in with a key or the agent, or they ride the
/// sign-in a terminal tab has already made and left open (`SSHControlSocket`).
/// A host that wants a password is told to sign in in a tab, which is the same
/// thing the file browser tells it.
enum TunnelPlan {
    /// Words for what a person can do when a non-interactive sign-in is refused.
    static let signInAdvice =
        "This host needs a sign-in iTERMiNAL can't type for you. Open a terminal tab to it first and leave it open — "
        + "the scan and the forwards share that connection — or add a key with ssh-copy-id."

    /// The arguments common to every non-interactive run, ending before the
    /// destination.
    ///
    /// `ConnectTimeout` keeps a host that does not answer from holding a scan
    /// open; no host-key option is given, so a host not yet trusted fails as
    /// `ssh` outside the app would in a script, rather than being trusted
    /// silently on the strength of a background call.
    static func baseArguments(for connection: SSHConnection, sharedSocket: String?) -> [String] {
        var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
        if connection.port != 22 {
            args.append(contentsOf: ["-p", String(connection.port)])
        }
        if let sharedSocket {
            args.append(contentsOf: SSHControlSocket.clientArguments(path: sharedSocket))
        }
        if let identity = connection.identityFile?.trimmingCharacters(in: .whitespaces), !identity.isEmpty {
            args.append(contentsOf: ["-i", (identity as NSString).expandingTildeInPath, "-o", "IdentitiesOnly=yes"])
        }
        args.append(contentsOf: connection.proxyJumpArguments)
        args.append(contentsOf: connection.optionArguments)
        return args
    }

    /// Run `command` on the host and print what it says.
    static func scanArguments(for connection: SSHConnection, sharedSocket: String?, command: String) -> [String] {
        baseArguments(for: connection, sharedSocket: sharedSocket) + [connection.destination, command]
    }

    /// `ssh -N -L …` for a forward that lives as long as the process does.
    static func forwardProcessArguments(
        for connection: SSHConnection,
        localPort: Int,
        targetHost: String,
        targetPort: Int
    ) -> [String] {
        var args = ["-N", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=30"]
        args.append(contentsOf: baseArguments(for: connection, sharedSocket: nil))
        args.append(contentsOf: ["-L", specification(localPort: localPort, targetHost: targetHost, targetPort: targetPort)])
        args.append(connection.destination)
        return args
    }

    /// `ssh -O forward` (or `-O cancel`) against the connection a terminal tab
    /// holds open: the forward is added to that connection, and goes with it.
    static func controlArguments(
        operation: String,
        for connection: SSHConnection,
        sharedSocket: String,
        localPort: Int,
        targetHost: String,
        targetPort: Int
    ) -> [String] {
        var args = ["-O", operation]
        args.append(contentsOf: baseArguments(for: connection, sharedSocket: sharedSocket))
        args.append(contentsOf: ["-L", specification(localPort: localPort, targetHost: targetHost, targetPort: targetPort)])
        args.append(connection.destination)
        return args
    }

    /// Always on the loopback address: a forward opened from here is for this
    /// Mac alone.
    static func specification(localPort: Int, targetHost: String, targetPort: Int) -> String {
        "127.0.0.1:\(localPort):\(targetHost):\(targetPort)"
    }

    /// Whether a forward may be asked for to this target at all.
    static func problem(targetHost: String, targetPort: Int) -> String? {
        guard PortForward.isPlainHost(targetHost) else {
            return "“\(targetHost)” isn't a host name or address a forward can lead to."
        }
        guard (1...65535).contains(targetPort) else {
            return "\(targetPort) isn't a port."
        }
        return nil
    }

    /// A port nothing is listening on right now, found by asking the system for
    /// one. Another process could take it before `ssh` does; `ExitOnForwardFailure`
    /// turns that into a clear failure instead of a tunnel that is not there.
    static func freeLocalPort() -> Int? {
        #if os(Linux)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = SOCK_STREAM
        #endif
        let descriptor = socket(AF_INET, streamType, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else { return nil }
        let port = Int(UInt16(bigEndian: assigned.sin_port))
        return port > 0 ? port : nil
    }

    /// Whether something accepts connections on `port` of this Mac's loopback.
    static func isAccepting(port: Int) -> Bool {
        #if os(Linux)
        let streamType = Int32(SOCK_STREAM.rawValue)
        #else
        let streamType = SOCK_STREAM
        #endif
        let descriptor = socket(AF_INET, streamType, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// What `ssh` said, cut down to the line that says what went wrong: its
    /// stderr can open with a banner or a warning about a host key.
    static func summarise(_ stderr: String) -> String {
        let lines = stderr
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let meaningful = lines.last { line in
            let lower = line.lowercased()
            return lower.contains("denied") || lower.contains("refused") || lower.contains("failed")
                || lower.contains("could not") || lower.contains("timed out") || lower.contains("no route")
                || lower.contains("changed") || lower.contains("not known") || lower.contains("unreachable")
        }
        return String((meaningful ?? lines.last ?? "ssh gave no reason.").prefix(240))
    }

    /// Whether the failure is the one a sign-in in a terminal fixes.
    static func isSignInFailure(_ stderr: String) -> Bool {
        let lower = stderr.lowercased()
        return lower.contains("permission denied") || lower.contains("authentication failed")
            || lower.contains("no more authentication methods")
    }
}
