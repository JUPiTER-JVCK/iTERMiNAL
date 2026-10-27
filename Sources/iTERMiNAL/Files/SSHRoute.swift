import Foundation

// How a saved connection reaches its host: through which jump hosts, and
// whether the ssh-agent's keys go along. Foundation only, so the rules are
// checked off a Mac like the rest of the connection logic; what runs the
// arguments is `SessionLaunch` for a terminal and `SFTPFileSystemProvider` for
// the file browser.

// MARK: - Jump hosts

/// A chain of hosts to go through on the way to the one a connection names —
/// a bastion, or several in a row — written the way ssh's own `-J` takes them:
/// `[user@]host[:port]`, separated by commas.
///
/// The text is checked here before it reaches a command line, and what does not
/// pass is refused rather than trimmed to something that does: a connection
/// that is meant to go through a bastion must never quietly go direct.
enum JumpHosts {
    /// More hops than anyone needs, and a bound on what one setting can ask ssh
    /// to start.
    static let maxHops = 5
    static let maxLength = 512

    enum Outcome: Equatable {
        /// Nothing written: connect directly.
        case none
        /// Each hop as `[user@]host[:port]`, spelled out the way it will be passed.
        case hops([String])
        /// Something is wrong; a sentence for the person who wrote it.
        case invalid(String)
    }

    static func parse(_ text: String) -> Outcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        guard trimmed.count <= maxLength else {
            return .invalid("That is too long for a list of jump hosts.")
        }
        var hops: [String] = []
        for piece in trimmed.split(separator: ",", omittingEmptySubsequences: false) {
            switch parseHop(String(piece)) {
            case .success(let hop): hops.append(hop)
            case .failure(let problem): return .invalid(problem.message)
            }
        }
        guard hops.count <= maxHops else {
            return .invalid("At most \(maxHops) jump hosts, in the order they are to be used.")
        }
        return .hops(hops)
    }

    private struct HopProblem: Error {
        let message: String
    }

    private static func parseHop(_ piece: String) -> Result<String, HopProblem> {
        let hop = piece.trimmingCharacters(in: .whitespaces)
        func bad(_ why: String) -> Result<String, HopProblem> {
            .failure(HopProblem(message: why))
        }
        guard !hop.isEmpty else {
            return bad("A jump host is missing — check for a doubled or a trailing comma.")
        }
        // A coarse first gate on the alphabet: quotes, `%` tokens, a slash for a
        // URL, whitespace and the rest of what ssh or a shell would treat
        // specially are outside it. The checks on each part below look at every
        // character again, so no one of them is all that stands between a
        // character and a command line.
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-@:[]")
        guard hop.allSatisfy({ allowed.contains($0) }) else {
            return bad("“\(hop)” isn't a jump host. Write host, user@host or host:port.")
        }

        var user: String?
        var rest = hop
        let parts = hop.split(separator: "@", omittingEmptySubsequences: false)
        if parts.count > 2 {
            return bad("“\(hop)” has more than one @.")
        }
        if parts.count == 2 {
            let name = String(parts[0])
            guard !name.isEmpty else {
                return bad("There is nothing before the @ in “\(hop)”.")
            }
            guard isUserName(name) else {
                return bad("“\(name)” isn't a user name ssh would accept.")
            }
            guard !parts[1].isEmpty else {
                return bad("“\(hop)” has no host after the @.")
            }
            user = name
            rest = String(parts[1])
        }

        var host: String
        var port: String?
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else {
                return bad("“\(hop)” has an opening [ and no ].")
            }
            let inside = String(rest[rest.index(after: rest.startIndex)..<close])
            guard isIPv6Literal(inside) else {
                return bad("“\(inside)” isn't an IPv6 address.")
            }
            host = "[\(inside)]"
            let after = rest[rest.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":") else {
                    return bad("“\(hop)” has something after the ].")
                }
                port = String(after.dropFirst())
            }
        } else {
            guard !rest.contains("[") && !rest.contains("]") else {
                return bad("“\(hop)” has a bracket outside an IPv6 address.")
            }
            let colons = rest.filter { $0 == ":" }.count
            if colons > 1 {
                return bad("An IPv6 address needs square brackets, like [::1]:22.")
            }
            if colons == 1 {
                let split = rest.split(separator: ":", omittingEmptySubsequences: false)
                host = String(split[0])
                port = String(split[1])
            } else {
                host = rest
            }
            guard isHostName(host) else {
                return bad("“\(host)” isn't a host name or address ssh would accept.")
            }
            // ssh reads `ProxyJump=none` as "no jump", so a host by that name
            // would turn the whole setting off while looking like it was on.
            guard host.lowercased() != "none" else {
                return bad("“none” can't be a jump host: to go direct, leave the box empty.")
            }
        }

        var spelledPort: String?
        if let port {
            guard !port.isEmpty else {
                return bad("A port is missing after the colon in “\(hop)”.")
            }
            guard port.allSatisfy(\.isASCIIDigit),
                  let number = Int(port), (1...65535).contains(number) else {
                return bad("“\(port)” isn't a port, which is a number from 1 to 65535.")
            }
            // Spelled as a number, so `022` and `22` are the same hop.
            spelledPort = String(number)
        }

        var spelled = host
        if let user { spelled = "\(user)@\(spelled)" }
        if let spelledPort { spelled += ":\(spelledPort)" }
        return .success(spelled)
    }

    /// Letters, digits and `._-`, not starting with a dash: a name that begins
    /// with one would be read by ssh as an option.
    private static func isUserName(_ name: String) -> Bool {
        guard let first = name.first, first != "-" else { return false }
        return name.allSatisfy { $0.isASCIILetterOrDigit || "._-".contains($0) }
    }

    /// A DNS name or an IPv4 address: starts with a letter or digit, then
    /// letters, digits and `._-`. A trailing dot (a fully qualified name) is
    /// allowed.
    private static func isHostName(_ host: String) -> Bool {
        guard let first = host.first, first.isASCIILetterOrDigit else { return false }
        return host.allSatisfy { $0.isASCIILetterOrDigit || "._-".contains($0) }
    }

    /// Hex digits, colons and, for the tail of a mapped address, dots — with at
    /// least one colon, which is what makes it an IPv6 address.
    private static func isIPv6Literal(_ text: String) -> Bool {
        guard text.contains(":"), text.count <= 45 else { return false }
        return text.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
    }

    /// What a connection that is not made for want of usable jump hosts is told.
    static func refusal(_ problem: String) -> String {
        "Not connecting: the jump hosts for this connection can't be used. \(problem) Fix them under Settings → Connections."
    }

    /// The value for `-o ProxyJump=`: the hops, comma-separated. Nil when there
    /// is nothing to jump through — and when the text is invalid, which is why
    /// a caller has to look at `parse` first and refuse: nil means "connect
    /// directly" here and must never be reached by way of a mistake.
    static func proxyJumpValue(_ text: String) -> String? {
        guard case .hops(let hops) = parse(text) else { return nil }
        return hops.joined(separator: ",")
    }
}

private extension Character {
    var isASCIIDigit: Bool { self >= "0" && self <= "9" }

    var isASCIILetterOrDigit: Bool {
        isASCIIDigit || (self >= "a" && self <= "z") || (self >= "A" && self <= "Z")
    }
}

// MARK: - Agent forwarding

/// What a connection does about the ssh-agent: whether the keys in it can be
/// used from the host being connected to. Forwarding lets a program there —
/// and anyone who can act as you there, such as root — ask the agent on this
/// Mac to sign in elsewhere for as long as the connection is open. The keys
/// themselves never leave this Mac either way; the risk is the use of them.
enum AgentForwarding: String, Codable, CaseIterable, Identifiable {
    /// Add nothing: `~/.ssh/config` decides, as it does for ssh outside the app.
    case sshConfig
    /// Never, whatever the config says.
    case never
    /// Ask before each connection — each new tab and each reconnect.
    case ask
    /// Always.
    case always

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sshConfig: return "As in ~/.ssh/config"
        case .never: return "Never"
        case .ask: return "Ask each time I connect"
        case .always: return "Always"
        }
    }

    /// Whether the answer has to come from the person before ssh starts.
    var needsAnswer: Bool { self == .ask }

    /// ssh's arguments for this choice. `approved` is the person's answer to
    /// the question `.ask` puts; the other choices ignore it. A "no" is
    /// spelled out as `ForwardAgent=no` rather than left out, because the
    /// config may say yes and a refusal has to hold against it.
    func arguments(approved: Bool) -> [String] {
        switch self {
        case .sshConfig: return []
        case .never: return ["-o", "ForwardAgent=no"]
        case .always: return ["-A"]
        case .ask: return approved ? ["-A"] : ["-o", "ForwardAgent=no"]
        }
    }
}

// MARK: - What a connection adds to a command line

extension SSHConnection {
    /// The jump hosts that apply: only ssh goes through them. mosh starts with
    /// an ssh but then talks to the host directly over UDP, which a host behind
    /// a bastion cannot accept, and a custom command is the person's own.
    var jumpHostsOutcome: JumpHosts.Outcome {
        transport == .ssh ? JumpHosts.parse(jumpHosts) : .none
    }

    /// Why the jump hosts cannot be used, or nil when they can (or are empty).
    /// A connection with a reason does not connect at all.
    var jumpHostsProblem: String? {
        if case .invalid(let message) = jumpHostsOutcome { return message }
        return nil
    }

    /// `-o ProxyJump=…` for ssh, sftp and ssh-copy-id alike, or nothing.
    /// Empty is also what an invalid list gives; callers check
    /// `jumpHostsProblem` first.
    var proxyJumpArguments: [String] {
        guard let value = JumpHosts.proxyJumpValue(jumpHosts), transport == .ssh else { return [] }
        return ["-o", "ProxyJump=\(value)"]
    }
}
