import Foundation

/// A TCP port something is listening on, as read from the output of `ss`,
/// `netstat` or `lsof`. Foundation only: the parsing is checked off a Mac, and
/// what *runs* those commands is `PortScanner`.
struct ListeningPort: Identifiable, Hashable {
    enum Scope: Int, Hashable {
        /// Only this machine can reach it: 127.0.0.1 or ::1.
        case loopback
        /// Anything that can reach the machine can reach it: `*`, 0.0.0.0 or ::.
        case allInterfaces
        /// Bound to one particular address.
        case specific
    }

    let port: Int
    /// The address as the tool printed it, normalised: `*`, `0.0.0.0` and `::`
    /// are all kept as written.
    let address: String
    /// The program that owns it, when the tool said. `ss -p` only says for the
    /// account's own processes, and `lsof` likewise, so nil is common and never
    /// a claim that nothing owns it.
    let process: String?

    var id: Int { port }

    var scope: Scope {
        switch address {
        case "127.0.0.1", "::1", "localhost": return .loopback
        case "*", "0.0.0.0", "::", "[::]", "": return .allInterfaces
        default: return address.hasPrefix("127.") ? .loopback : .specific
        }
    }

    var scopeLabel: String {
        switch scope {
        case .loopback: return "this machine only"
        case .allInterfaces: return "all interfaces"
        case .specific: return address
        }
    }

    /// The host to name as a forward's target, from the machine the port is on:
    /// the address it is bound to when that is one particular IPv4 address
    /// (`localhost` would not reach it), `localhost` otherwise. An IPv6
    /// address is not offered — see `PortForward.isPlainHost` — and falls back
    /// to `localhost`, which reaches a dual-stack listener.
    var forwardHost: String {
        if scope == .specific, PortForward.isPlainHost(address), address.contains(".") {
            return address
        }
        return "localhost"
    }

    /// Ports that are usually a web page. A hint for ordering and for the icon,
    /// not a claim about what is actually listening there.
    var isLikelyWeb: Bool {
        Self.commonWebPorts.contains(port) || (3000...3999).contains(port) || (8000...8999).contains(port)
    }

    static let commonWebPorts: Set<Int> = [80, 443, 5000, 5173, 4200, 9000, 9090]
}

enum ListeningPorts {
    /// More than a machine has any use for showing, and a bound on what a
    /// misbehaving host can make this hold.
    static let maxPorts = 512
    static let maxInputBytes = 1_000_000

    // MARK: Commands

    /// What to run on a remote host. Tried in order, the first that succeeds
    /// being used: `ss` (Linux), `netstat` in its Linux and then its BSD forms,
    /// `lsof`. The line is read by the host's login shell, so it uses nothing
    /// beyond `||` and a redirect, which every shell it is likely to meet has.
    static let remoteCommand =
        "ss -tlnp 2>/dev/null || netstat -tln 2>/dev/null || netstat -an -p tcp 2>/dev/null"
        + " || lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null"

    /// Arguments for `lsof` on this Mac.
    static let localLsofArguments = ["-nP", "-iTCP", "-sTCP:LISTEN"]
    /// Arguments for `netstat` on this Mac, which sees every listener where
    /// `lsof` only sees the account's own.
    static let localNetstatArguments = ["-an", "-p", "tcp"]

    // MARK: Parsing

    /// Every listening port in `output`, once each, in port order. Lines that
    /// are not a listener — headers, established connections, blank lines — are
    /// skipped, and so is anything it cannot make sense of.
    static func parse(_ output: String) -> [ListeningPort] {
        let bounded = output.utf8.count > maxInputBytes
            ? String(decoding: Array(output.utf8.prefix(maxInputBytes)), as: UTF8.self)
            : output
        var found: [ListeningPort] = []
        for rawLine in bounded.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            if let entry = parseLine(String(rawLine)) { found.append(entry) }
            if found.count >= maxPorts * 4 { break }
        }
        return merge(found)
    }

    /// Joins entries for the same port — the IPv4 and IPv6 sockets of one
    /// server, or the same listener seen by two tools — into one. The widest
    /// scope wins, because that is what the port can be reached from, and a
    /// process name is kept from whichever entry had one.
    static func merge(_ entries: [ListeningPort]) -> [ListeningPort] {
        var byPort: [Int: ListeningPort] = [:]
        for entry in entries {
            guard let existing = byPort[entry.port] else {
                byPort[entry.port] = entry
                continue
            }
            let wider = rank(entry.scope) > rank(existing.scope) ? entry : existing
            byPort[entry.port] = ListeningPort(
                port: entry.port,
                address: wider.address,
                process: existing.process ?? entry.process
            )
        }
        return byPort.values.sorted { $0.port < $1.port }.prefix(maxPorts).map { $0 }
    }

    private static func rank(_ scope: ListeningPort.Scope) -> Int {
        switch scope {
        case .loopback: return 0
        case .specific: return 1
        case .allInterfaces: return 2
        }
    }

    private static func parseLine(_ line: String) -> ListeningPort? {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.count >= 4 else { return nil }

        // lsof: `node 123 me 23u IPv4 0x… 0t0 TCP *:3000 (LISTEN)`
        if let tcp = tokens.firstIndex(of: "TCP"), tcp + 1 < tokens.count,
           tokens.last == "(LISTEN)" {
            guard let (host, port) = splitAddress(tokens[tcp + 1]) else { return nil }
            return ListeningPort(port: port, address: host, process: cleaned(tokens[0]))
        }

        // ss: `LISTEN 0 4096 127.0.0.1:8080 0.0.0.0:* users:(("node",pid=1,fd=3))`
        if tokens[0] == "LISTEN" {
            guard let (host, port) = splitAddress(tokens[3]) else { return nil }
            let owner = tokens.dropFirst(5).first { $0.hasPrefix("users:") }.flatMap(ssProcessName)
            return ListeningPort(port: port, address: host, process: owner)
        }

        // netstat, Linux and BSD: `tcp 0 0 0.0.0.0:22 0.0.0.0:* LISTEN`,
        // `tcp4 0 0 *.22 *.* LISTEN`. Only the listening state, and only tcp.
        if tokens[0].hasPrefix("tcp"), tokens.contains("LISTEN") {
            guard let (host, port) = splitAddress(tokens[3]) else { return nil }
            return ListeningPort(port: port, address: host, process: nil)
        }
        return nil
    }

    /// Splits `host:port`, `[host]:port`, `host.port` (BSD) and `*:port`.
    static func splitAddress(_ token: String) -> (String, Int)? {
        var text = token
        // `fe80::1%lo0:8080` — the scope is not part of the address.
        if let percent = text.firstIndex(of: "%") {
            let afterScope = text[percent...].firstIndex(where: { $0 == ":" || $0 == "." })
            if let afterScope {
                text = String(text[..<percent]) + String(text[afterScope...])
            } else {
                text = String(text[..<percent])
            }
        }
        if let colon = text.lastIndex(of: ":") {
            let tail = text[text.index(after: colon)...]
            if let port = port(from: tail) {
                var host = String(text[..<colon])
                if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
                // netstat on Linux prints `:::22` for `[::]:22`.
                if host == "::" || host == ":" { host = "::" }
                return (host.isEmpty ? "*" : host, port)
            }
        }
        if let dot = text.lastIndex(of: ".") {
            let tail = text[text.index(after: dot)...]
            if let port = port(from: tail) {
                let host = String(text[..<dot])
                return (host.isEmpty ? "*" : host, port)
            }
        }
        return nil
    }

    private static func port(from text: Substring) -> Int? {
        guard !text.isEmpty, text.count <= 5, text.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let value = Int(text), (1...65535).contains(value) else { return nil }
        return value
    }

    /// `users:(("node",pid=1,fd=3))` → `node`.
    private static func ssProcessName(_ field: String) -> String? {
        guard let open = field.range(of: "((\"") else { return nil }
        let rest = field[open.upperBound...]
        guard let close = rest.firstIndex(of: "\"") else { return nil }
        return cleaned(String(rest[..<close]))
    }

    /// lsof writes a space in a name as `\x20`; a name is shown, never run, but
    /// a control character in it has no business in a list.
    private static func cleaned(_ name: String) -> String? {
        let text = name.replacingOccurrences(of: "\\x20", with: " ")
        let printable = String(text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F })
        let trimmed = printable.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(48))
    }
}
