import Foundation

/// What a well-known port is for, and what choosing it should do.
struct PortService: Hashable {
    let name: String
    let summary: String
    let action: ListeningPort.Action

    init(_ name: String, _ summary: String, _ action: ListeningPort.Action = .forward) {
        self.name = name
        self.summary = summary
        self.action = action
    }
}

/// A TCP port something is listening on, as read from the output of `ss`,
/// `netstat` or `lsof`. Foundation only: the parsing is checked off a Mac, and
/// what *runs* those commands is `PortScanner`.
///
/// Only `port` and `address` are always known. Everything else is whatever the
/// machine's tools happened to say — `ss` and `lsof` name other accounts' sockets
/// only for root, `netstat` names none — so every other field may be empty and an
/// empty one never means "nothing".
struct ListeningPort: Identifiable, Hashable {
    enum Scope: Int, Hashable {
        /// Only this machine can reach it: 127.0.0.1 or ::1.
        case loopback
        /// Anything that can reach the machine can reach it: `*`, 0.0.0.0 or ::.
        case allInterfaces
        /// Bound to one particular address.
        case specific
    }

    /// What choosing a port does.
    enum Action: String, Hashable {
        /// Opens it in the browser panel.
        case browser
        /// Opens a terminal to the host.
        case ssh
        /// Hands it to the system's screen-sharing client.
        case vnc
        /// Hands it to the system's remote-desktop client.
        case rdp
        /// Not a web page: forwards it (on a host) and copies the address to use.
        case forward
    }

    /// One labelled fact about a port, for the detail view.
    struct Detail: Hashable {
        let label: String
        let value: String
    }

    let port: Int
    /// The address as the tool printed it, normalised: `*`, `0.0.0.0` and `::`
    /// are all kept as written.
    let address: String
    /// The program that owns it, when the tool said. `ss -p` only says for the
    /// account's own processes, and `lsof` likewise, so nil is common and never
    /// a claim that nothing owns it.
    var process: String?
    var pid: Int? = nil
    var user: String? = nil
    /// The owner's full command line, with anything that looks like a secret hidden.
    var command: String? = nil
    /// How long the owner has been running, as `ps` prints it (`1-02:03:04`).
    var elapsed: String? = nil
    /// When the owner started, in the machine's own clock and words.
    var startedAt: String? = nil
    /// Every address it is bound to: a server often has an IPv4 and an IPv6 socket.
    var addresses: [String] = []
    /// `IPv4` and/or `IPv6`, where the tool said or the address shows.
    var families: [String] = []
    /// `ss`: the most connections waiting to be accepted.
    var backlog: Int? = nil
    /// Connections waiting to be accepted right now.
    var queued: Int? = nil
    /// Open connections to this port at the last scan, and some of who is on the other end.
    var connectionCount = 0
    var peers: [String] = []

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

    // MARK: What it is

    /// What the port is known for: by the program that owns it where that is
    /// known (a Postgres on 5433 is still Postgres), by the number otherwise.
    var service: PortService? { PortCatalog.service(for: port, process: process) }

    /// What choosing it does. Anything not recognised is tried as a web page,
    /// which is what a dev server on an unremarkable port nearly always is.
    var action: Action { service?.action ?? .browser }

    /// Whether to browse to it with https.
    var prefersHTTPS: Bool { port == 443 || port == 8443 }

    /// `127.0.0.1:8080` or `[::1]:8080`.
    static func hostPort(_ address: String, _ port: Int) -> String {
        address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
    }

    /// One short line of what is known, for under the port in the list.
    func summaryLine() -> String {
        var parts: [String] = [scopeLabel]
        if let user, !user.isEmpty { parts.append(user) }
        if let pid { parts.append("pid \(pid)") }
        if let elapsed, let up = ListeningPorts.describeElapsed(elapsed) { parts.append("up \(up)") }
        if connectionCount > 0 {
            parts.append(connectionCount == 1 ? "1 connection" : "\(connectionCount) connections")
        }
        return parts.joined(separator: " · ")
    }

    /// What choosing the port will do, in words, for `onHost` (a saved host, as
    /// against this Mac).
    func actionSummary(onHost: Bool, machine: String) -> String {
        switch action {
        case .browser:
            let scheme = prefersHTTPS ? "https" : "http"
            return onHost
                ? "Forwards \(forwardHost):\(port) from \(machine) to a port on this Mac, then opens it in the browser panel"
                : "Opens \(scheme)://localhost:\(port) in the browser panel"
        case .ssh:
            return onHost
                ? "Opens a terminal tab on \(machine)"
                : "Copies the ssh command for this Mac"
        case .vnc:
            return onHost
                ? "Forwards it from \(machine) and opens the system's Screen Sharing client"
                : "Opens the system's Screen Sharing client on localhost:\(port)"
        case .rdp:
            return onHost
                ? "Forwards it from \(machine) and opens the system's Remote Desktop client"
                : "Opens the system's Remote Desktop client on localhost:\(port)"
        case .forward:
            return onHost
                ? "Forwards \(forwardHost):\(port) from \(machine) to a port on this Mac and copies that address"
                : "Copies localhost:\(port) (not a web page, so nothing is opened)"
        }
    }

    /// Every fact there is about the port, in the order worth reading it, with
    /// nothing for what is not known.
    func details(machine: String, onHost: Bool) -> [Detail] {
        var rows: [Detail] = []
        func add(_ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            rows.append(Detail(label: label, value: value))
        }

        if let service {
            add("Service", service.name)
            add("About", service.summary)
        }
        add("Port range", PortCatalog.range(of: port))

        // Source: where connections to it arrive.
        let bound = addresses.isEmpty ? [address] : addresses
        let shown = bound.map { Self.hostPort($0, port) }.joined(separator: ", ")
        add("Source", scope == .allInterfaces ? "All interfaces — \(shown)" : shown)

        // Destination: who it will talk to.
        switch scope {
        case .loopback: add("Destination", "Only programs on \(machine) itself (loopback)")
        case .allInterfaces: add("Destination", "Anything that can reach \(machine), on any network it is on")
        case .specific: add("Destination", "Anything that can reach \(address)")
        }

        var transport = "TCP"
        if !families.isEmpty { transport += " · " + families.joined(separator: ", ") }
        add("Protocol", transport)

        add("Process", process)
        add("PID", pid.map { String($0) })
        add("User", user)
        add("Command", command)
        if let elapsed, let up = ListeningPorts.describeElapsed(elapsed) {
            add("Running", startedAt.map { "\(up) — started \($0)" } ?? up)
        } else {
            add("Started", startedAt)
        }

        if connectionCount > 0 {
            var line = connectionCount == 1 ? "1 open connection" : "\(connectionCount) open connections"
            if !peers.isEmpty { line += " from " + peers.joined(separator: ", ") }
            add("Connections", line)
        } else {
            add("Connections", "None open at the last scan")
        }
        if let backlog {
            add("Accept queue", "\(queued ?? 0) waiting, room for \(backlog)")
        }

        add("Choosing it", actionSummary(onHost: onHost, machine: machine))
        return rows
    }
}

/// What the common ports are for. The number is a hint — anything can listen
/// anywhere — so it is only ever used to describe a port, never to decide what
/// is on it, and the owning program's name wins where there is one.
enum PortCatalog {
    static func service(for port: Int, process: String?) -> PortService? {
        if let name = process?.lowercased() {
            for (needle, hinted) in processHints where name.contains(needle) {
                if let service = table[hinted] { return service }
            }
        }
        return table[port]
    }

    static func range(of port: Int) -> String {
        switch port {
        case 0...1023: return "System (well-known) port, 0–1023"
        case 1024...49151: return "Registered port, 1024–49151"
        default: return "Dynamic (private) port, 49152–65535"
        }
    }

    /// A program name that says what a port is whatever number it uses.
    private static let processHints: [(String, Int)] = [
        ("sshd", 22), ("screensharing", 5900), ("vnc", 5900), ("xrdp", 3389),
        ("postgres", 5432), ("mysqld", 3306), ("mariadbd", 3306), ("mongod", 27017),
        ("redis", 6379), ("memcached", 11211), ("nginx", 80), ("httpd", 80),
        ("apache", 80), ("caddy", 80), ("cupsd", 631), ("smbd", 445),
        ("jupyter", 8888),
    ]

    private static let table: [Int: PortService] = [
        21: PortService("FTP", "File Transfer Protocol: unencrypted file transfers."),
        22: PortService("SSH", "Secure Shell: remote login, and file transfer through sftp and scp.", .ssh),
        23: PortService("Telnet", "Unencrypted remote login; replaced by SSH."),
        25: PortService("SMTP", "Mail delivery between servers."),
        53: PortService("DNS", "Domain name resolver."),
        80: PortService("HTTP", "Web server.", .browser),
        110: PortService("POP3", "Mail retrieval."),
        111: PortService("rpcbind", "RPC port mapper, used by NFS."),
        139: PortService("NetBIOS", "Windows file sharing over NetBIOS."),
        143: PortService("IMAP", "Mail retrieval and sync."),
        389: PortService("LDAP", "Directory service."),
        443: PortService("HTTPS", "Web server over TLS.", .browser),
        445: PortService("SMB", "Windows and macOS file sharing."),
        465: PortService("SMTPS", "Mail submission over TLS."),
        548: PortService("AFP", "Apple Filing Protocol: macOS file sharing."),
        587: PortService("SMTP submission", "Mail submission from clients."),
        631: PortService("CUPS / IPP", "Printing service; its admin page is a web page.", .browser),
        636: PortService("LDAPS", "Directory service over TLS."),
        993: PortService("IMAPS", "Mail retrieval and sync over TLS."),
        995: PortService("POP3S", "Mail retrieval over TLS."),
        1080: PortService("SOCKS", "SOCKS proxy."),
        1433: PortService("SQL Server", "Microsoft SQL Server database."),
        1521: PortService("Oracle DB", "Oracle database listener."),
        1883: PortService("MQTT", "Message broker for devices and sensors."),
        2049: PortService("NFS", "Network File System."),
        2375: PortService("Docker API", "Docker daemon API, unencrypted: anyone who reaches it controls the machine."),
        2376: PortService("Docker API (TLS)", "Docker daemon API over TLS."),
        2379: PortService("etcd", "etcd client API."),
        2380: PortService("etcd peer", "etcd cluster traffic."),
        3000: PortService("Dev server", "Where Node, Rails, Grafana and many dev servers listen by default.", .browser),
        3306: PortService("MySQL", "MySQL or MariaDB database."),
        3389: PortService("RDP", "Windows Remote Desktop.", .rdp),
        4200: PortService("Angular dev server", "ng serve's default.", .browser),
        4222: PortService("NATS", "NATS message broker."),
        5000: PortService("Web app", "Flask's default, a Docker registry — and AirPlay Receiver on a Mac.", .browser),
        5037: PortService("adb", "Android Debug Bridge server."),
        5173: PortService("Vite dev server", "Vite's default.", .browser),
        5432: PortService("PostgreSQL", "PostgreSQL database."),
        5601: PortService("Kibana", "Kibana's web interface.", .browser),
        5672: PortService("AMQP", "RabbitMQ and other AMQP brokers."),
        5900: PortService("VNC", "Screen sharing (Remote Framebuffer).", .vnc),
        5984: PortService("CouchDB", "CouchDB's HTTP API.", .browser),
        6379: PortService("Redis", "Redis key-value store."),
        6443: PortService("Kubernetes API", "Kubernetes API server."),
        7000: PortService("AirPlay / Cassandra", "AirPlay Receiver on a Mac; Cassandra's cluster port elsewhere."),
        8000: PortService("Dev server", "Where Python's http.server, Django and others listen by default.", .browser),
        8080: PortService("HTTP (alternate)", "Web server or proxy on its common second port.", .browser),
        8081: PortService("HTTP (alternate)", "Web server, Metro bundler or admin page.", .browser),
        8086: PortService("InfluxDB", "InfluxDB's HTTP API.", .browser),
        8443: PortService("HTTPS (alternate)", "Web server over TLS on its common second port.", .browser),
        8500: PortService("Consul", "Consul's HTTP API and web interface.", .browser),
        8888: PortService("Jupyter", "Jupyter Notebook and similar.", .browser),
        9000: PortService("Web app", "PHP-FPM, SonarQube, MinIO and various web tools.", .browser),
        9090: PortService("Prometheus", "Prometheus's web interface, or Cockpit.", .browser),
        9092: PortService("Kafka", "Kafka broker."),
        9200: PortService("Elasticsearch", "Elasticsearch's HTTP API.", .browser),
        9229: PortService("Node inspector", "Node.js debugger: lets a client run code in the process."),
        11211: PortService("memcached", "Memcached cache."),
        15672: PortService("RabbitMQ admin", "RabbitMQ's management interface.", .browser),
        27017: PortService("MongoDB", "MongoDB database."),
        50051: PortService("gRPC", "Conventional gRPC port."),
    ]
}

enum ListeningPorts {
    /// More than a machine has any use for showing, and a bound on what a
    /// misbehaving host can make this hold.
    static let maxPorts = 512
    static let maxInputBytes = 1_000_000
    /// Processes and connections are read for the ports' sake only; a host with
    /// more than this is read as far as here and no further.
    static let maxProcesses = 20_000
    static let maxConnections = 20_000

    // MARK: Commands

    /// What separates what the host sends back: the listening ports, then its
    /// processes, then its open connections. Plain words, because the line is
    /// read by the host's login shell, and `@`, `=`, `-` and the like mean
    /// something to one shell or another.
    static let processMarker = "iterminal_ps_section"
    static let connectionMarker = "iterminal_conn_section"
    /// Printed only when none of the port-listing tools worked.
    static let missingMarker = "iterminal_none_section"

    /// What to run on a remote host. Tried in order, the first that succeeds
    /// being used: `ss` (Linux), `netstat` in its Linux and then its BSD forms,
    /// `lsof`. Then the host's processes, for who owns each port and since when,
    /// and its open connections, for who is on the other end. The line is read
    /// by the host's login shell, so it uses nothing beyond `||`, `;` and a
    /// redirect, which every shell it is likely to meet has. Whatever is not
    /// there just prints nothing.
    static let remoteCommand =
        "ss -tlnp 2>/dev/null || netstat -tln 2>/dev/null || netstat -an -p tcp 2>/dev/null"
        + " || lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null || echo \(missingMarker);"
        + " echo \(processMarker);"
        + " ps -eww -o pid=,user=,etime=,lstart=,args= 2>/dev/null;"
        + " echo \(connectionMarker);"
        + " ss -tn 2>/dev/null || netstat -tn 2>/dev/null"

    /// Arguments for `lsof` on this Mac.
    static let localLsofArguments = ["-nP", "-iTCP", "-sTCP:LISTEN"]
    /// Arguments for `netstat` on this Mac, which sees every listener where
    /// `lsof` only sees the account's own.
    static let localNetstatArguments = ["-an", "-p", "tcp"]
    /// Arguments for `ps` on this Mac.
    static let localPsArguments = ["-axww", "-o", "pid=,user=,etime=,lstart=,command="]

    // MARK: Parsing

    /// A scan of a host: its ports, and whether it had no tool to list them with.
    struct Scan {
        var ports: [ListeningPort]
        var toolsMissing: Bool
    }

    /// What `ps` said about one process.
    struct ProcessEntry: Hashable {
        let pid: Int
        let user: String
        let elapsed: String
        let startedAt: String
        let command: String
    }

    /// Reads everything `remoteCommand` printed: the ports, joined to their
    /// owners and their open connections.
    static func parseScan(_ output: String) -> Scan {
        enum Section { case listing, processes, connections }
        var current = Section.listing
        var listing: [Substring] = []
        var processes: [Substring] = []
        var connections: [Substring] = []
        var missing = false

        let bounded = bound(output)
        for line in bounded.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == missingMarker {
                missing = true
            } else if trimmed == processMarker {
                current = .processes
            } else if trimmed == connectionMarker {
                current = .connections
            } else {
                switch current {
                case .listing: listing.append(line)
                case .processes: processes.append(line)
                case .connections: connections.append(line)
                }
            }
        }

        let listingText = listing.joined(separator: "\n")
        let ports = parse(listingText)
        // A BSD host's listing already carries its open connections.
        let peers = parseConnections(listingText + "\n" + connections.joined(separator: "\n"))
        let owners = ports.contains(where: { $0.pid != nil })
            ? parseProcesses(processes.joined(separator: "\n"))
            : [:]
        return Scan(
            ports: enrich(ports, processes: owners, connections: peers),
            toolsMissing: missing && ports.isEmpty
        )
    }

    /// Every listening port in `output`, once each, in port order. Lines that
    /// are not a listener — headers, established connections, blank lines — are
    /// skipped, and so is anything it cannot make sense of.
    static func parse(_ output: String) -> [ListeningPort] {
        var found: [ListeningPort] = []
        for rawLine in bound(output).split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            if let entry = parseLine(String(rawLine)) { found.append(entry) }
            if found.count >= maxPorts * 4 { break }
        }
        return merge(found)
    }

    private static func bound(_ output: String) -> String {
        output.utf8.count > maxInputBytes
            ? String(decoding: Array(output.utf8.prefix(maxInputBytes)), as: UTF8.self)
            : output
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
            byPort[entry.port] = combine(existing, entry)
        }
        return byPort.values.sorted { $0.port < $1.port }.prefix(maxPorts).map { $0 }
    }

    private static func combine(_ existing: ListeningPort, _ entry: ListeningPort) -> ListeningPort {
        var merged = rank(entry.scope) > rank(existing.scope) ? entry : existing
        merged.process = existing.process ?? entry.process
        merged.pid = existing.pid ?? entry.pid
        merged.user = existing.user ?? entry.user
        merged.backlog = existing.backlog ?? entry.backlog
        merged.queued = existing.queued ?? entry.queued
        merged.addresses = unique(existing.addresses + entry.addresses)
        merged.families = unique(existing.families + entry.families)
        return merged
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where !seen.contains(value) {
            seen.insert(value)
            result.append(value)
        }
        return result
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
            var entry = ListeningPort(port: port, address: host, process: cleaned(tokens[0]))
            entry.addresses = [host]
            if tcp >= 5 {
                entry.pid = Int(tokens[1])
                entry.user = cleaned(tokens[2])
                if tokens[4].hasPrefix("IPv") { entry.families = [tokens[4]] }
            }
            if entry.families.isEmpty, let inferred = family(of: host) { entry.families = [inferred] }
            return entry
        }

        // ss: `LISTEN 0 4096 127.0.0.1:8080 0.0.0.0:* users:(("node",pid=1,fd=3))`
        if tokens[0] == "LISTEN" {
            guard let (host, port) = splitAddress(tokens[3]) else { return nil }
            let field = tokens.dropFirst(5).first { $0.hasPrefix("users:") }
            var entry = ListeningPort(port: port, address: host, process: field.flatMap(ssProcessName))
            entry.pid = field.flatMap(ssPID)
            entry.addresses = [host]
            entry.queued = Int(tokens[1])
            entry.backlog = Int(tokens[2])
            if let inferred = family(of: host) { entry.families = [inferred] }
            return entry
        }

        // netstat, Linux and BSD: `tcp 0 0 0.0.0.0:22 0.0.0.0:* LISTEN`,
        // `tcp4 0 0 *.22 *.* LISTEN`. Only the listening state, and only tcp.
        if tokens[0].hasPrefix("tcp"), tokens.contains("LISTEN") {
            guard let (host, port) = splitAddress(tokens[3]) else { return nil }
            var entry = ListeningPort(port: port, address: host, process: nil)
            entry.addresses = [host]
            entry.queued = Int(tokens[1])
            switch tokens[0] {
            case "tcp4": entry.families = ["IPv4"]
            case "tcp6": entry.families = ["IPv6"]
            case "tcp46": entry.families = ["IPv4", "IPv6"]
            default:
                if let inferred = family(of: host) { entry.families = [inferred] }
            }
            return entry
        }
        return nil
    }

    /// `IPv4` or `IPv6` where the address itself says; nil for a wildcard.
    private static func family(of host: String) -> String? {
        if host.contains(":") { return "IPv6" }
        if host.isEmpty || host == "*" { return nil }
        return host.allSatisfy { ($0 >= "0" && $0 <= "9") || $0 == "." } ? "IPv4" : nil
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

    /// `users:(("node",pid=1,fd=3))` → `1`.
    private static func ssPID(_ field: String) -> Int? {
        guard let open = field.range(of: "pid=") else { return nil }
        let digits = field[open.upperBound...].prefix(while: { $0 >= "0" && $0 <= "9" })
        return Int(digits)
    }

    /// lsof writes a space in a name as `\x20`; a name is shown, never run, but
    /// a control character in it has no business in a list.
    private static func cleaned(_ name: String) -> String? {
        printable(name.replacingOccurrences(of: "\\x20", with: " "), limit: 48)
    }

    private static func printable(_ text: String, limit: Int) -> String? {
        let scalars = String(text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F })
        let trimmed = scalars.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(limit))
    }

    // MARK: Owners and connections

    /// Reads `ps -o pid=,user=,etime=,lstart=,args=`: the pid, the account, how
    /// long it has run (`[[dd-]hh:]mm:ss`), the five words of the start time,
    /// then the command line. A line that is not that is skipped.
    static func parseProcesses(_ output: String) -> [Int: ProcessEntry] {
        var result: [Int: ProcessEntry] = [:]
        for rawLine in bound(output).split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let tokens = rawLine.split(
                maxSplits: 8,
                omittingEmptySubsequences: true,
                whereSeparator: { $0 == " " || $0 == "\t" }
            )
            guard tokens.count >= 8, let pid = Int(tokens[0]),
                  describeElapsed(String(tokens[2])) != nil else { continue }
            let started = tokens[3...7].joined(separator: " ")
            let command = tokens.count > 8
                ? (printable(String(tokens[8]), limit: 240).map(redact) ?? "")
                : ""
            result[pid] = ProcessEntry(
                pid: pid,
                user: printable(String(tokens[1]), limit: 32) ?? "",
                elapsed: String(tokens[2]),
                startedAt: printable(started, limit: 40) ?? "",
                command: command
            )
            if result.count >= maxProcesses { break }
        }
        return result
    }

    /// Reads established connections out of `ss -tn`, `netstat -tn` or BSD
    /// `netstat`, as local port → the address on the other end of each.
    static func parseConnections(_ output: String) -> [Int: [String]] {
        var byPort: [Int: [String]] = [:]
        var total = 0
        for rawLine in bound(output).split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let tokens = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard tokens.count >= 5 else { continue }
            let established = tokens[0] == "ESTAB"
                || (tokens[0].hasPrefix("tcp") && tokens.last == "ESTABLISHED")
            guard established,
                  let (_, localPort) = splitAddress(tokens[3]),
                  let (peerHost, _) = splitAddress(tokens[4]) else { continue }
            let peer = peerHost.hasPrefix("::ffff:") ? String(peerHost.dropFirst(7)) : peerHost
            byPort[localPort, default: []].append(peer)
            total += 1
            if total >= maxConnections { break }
        }
        return byPort
    }

    /// Adds to each port what its owner's process and its open connections say.
    static func enrich(
        _ ports: [ListeningPort],
        processes: [Int: ProcessEntry],
        connections: [Int: [String]]
    ) -> [ListeningPort] {
        ports.map { port in
            var next = port
            if let pid = port.pid, let entry = processes[pid] {
                if next.user == nil, !entry.user.isEmpty { next.user = entry.user }
                if !entry.command.isEmpty { next.command = entry.command }
                next.elapsed = entry.elapsed
                if !entry.startedAt.isEmpty { next.startedAt = entry.startedAt }
                if next.process == nil { next.process = programName(of: entry.command) }
            }
            if let peers = connections[port.port], !peers.isEmpty {
                next.connectionCount = peers.count
                var seen = Set<String>()
                var distinct: [String] = []
                for peer in peers where !seen.contains(peer) {
                    seen.insert(peer)
                    distinct.append(peer)
                    if distinct.count >= 5 { break }
                }
                next.peers = distinct
            }
            return next
        }
    }

    /// `/usr/bin/node server.js` → `node`.
    private static func programName(of command: String) -> String? {
        guard let first = command.split(separator: " ").first,
              let name = first.split(separator: "/").last else { return nil }
        return cleaned(String(name))
    }

    /// A command line goes on screen, so what looks like a secret in one does
    /// not: the value of `--password=…` and the word after `--token …`.
    static func redact(_ command: String) -> String {
        let sensitive = ["pass", "secret", "token", "key", "auth", "credential"]
        var words = command.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var maskNext = false
        for index in words.indices {
            let word = words[index]
            if maskNext {
                maskNext = false
                if !word.hasPrefix("-") {
                    words[index] = "••••"
                    continue
                }
            }
            if let equals = word.firstIndex(of: "=") {
                let name = word[..<equals].lowercased()
                if sensitive.contains(where: { name.contains($0) }) {
                    words[index] = String(word[..<equals]) + "=••••"
                }
            } else if word.hasPrefix("-") {
                let name = word.lowercased()
                if sensitive.contains(where: { name.contains($0) }) { maskNext = true }
            }
        }
        return words.joined(separator: " ")
    }

    /// `ps` elapsed time, `[[dd-]hh:]mm:ss`, as two units of what a person
    /// would say: `1d 2h`, `3h 12m`, `5m`, `42s`. Nil for anything else.
    static func describeElapsed(_ etime: String) -> String? {
        var days = 0
        var rest = Substring(etime)
        if let dash = etime.firstIndex(of: "-") {
            guard let value = Int(etime[..<dash]) else { return nil }
            days = value
            rest = etime[etime.index(after: dash)...]
        }
        let parts = rest.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        guard (2...3).contains(parts.count), !parts.contains(where: { $0 == nil }) else { return nil }
        let numbers = parts.compactMap { $0 }
        let hours = numbers.count == 3 ? numbers[0] : 0
        let minutes = numbers[numbers.count - 2]
        let seconds = numbers[numbers.count - 1]
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }
}
