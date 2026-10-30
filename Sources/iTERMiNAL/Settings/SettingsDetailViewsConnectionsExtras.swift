import SwiftUI
import AppKit

/// Settings → Connections → the chosen host's terminal type, address family,
/// compression, keep-alive and port forwards.
struct HostOptionsSection: View {
    @Binding var connection: SSHConnection
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Section("Sign-in") {
            Button("Set Up Key Login…") {
                // Typed into a tab and left for you to run: it makes a key if
                // you have none and asks for the host's password once, in ssh.
                WorkspaceStore.shared.newTab(typing: RemoteProblem.keyLoginCommand(for: connection))
                openWindow(id: "main")
            }
            .disabled(connection.transport == .custom || connection.host.trimmingCharacters(in: .whitespaces).isEmpty)
            Text("Opens a terminal tab with the command typed in: it creates an ed25519 key if you have none (asking whether to give it a passphrase), then installs it on this host with ssh-copy-id, which asks for the host's password once. Press Return to run it. After that the file browser and everything else sign in without a password. Nothing runs until you press Return.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section("Terminal and transport") {
            Picker("Terminal type", selection: $connection.terminalTypeTag) {
                Text("Use the remote default").tag("")
                ForEach(TerminalType.allCases) { type in
                    Text(type.label).tag(type.rawValue)
                }
            }
            if let type = TerminalType(rawValue: connection.terminalTypeTag) {
                Text(type.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let hint = type.installHint {
                    Text("If this host doesn't know the name: \(hint)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if connection.transport == .ssh {
                Picker("Address family", selection: $connection.ipFamily) {
                    ForEach(IPFamily.allCases) { family in
                        Text(family.label).tag(family)
                    }
                }
                Toggle("Compress the connection (-C)", isOn: $connection.compression)
                Stepper(value: $connection.keepAliveSeconds, in: 0...SSHConnection.keepAliveRange.upperBound, step: 5) {
                    HStack {
                        Text("Keep-alive")
                        Spacer()
                        Text(connection.keepAliveSeconds == 0 ? "As in ~/.ssh/config" : "every \(connection.keepAliveSeconds) s")
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Each is added to the ssh command only when set here, so leaving them alone leaves ~/.ssh/config in charge. They apply to the terminal, the file browser and port scans.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                forwardsEditor
            } else {
                Text("Address family, compression, keep-alive and port forwards are ssh options; this host connects another way.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var forwardsEditor: some View {
        ForEach($connection.forwards) { $forward in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Picker("", selection: $forward.kind) {
                        ForEach(PortForward.Kind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    TextField("Port", value: $forward.bindPort, format: .number.grouping(.never))
                        .frame(width: 70)
                    if forward.kind != .dynamic {
                        Text("→")
                        TextField("Host", text: $forward.targetHost)
                        Text(":")
                        TextField("Port", value: $forward.targetPort, format: .number.grouping(.never))
                            .frame(width: 70)
                    }
                    Spacer(minLength: 0)
                    Button(role: .destructive) {
                        connection.forwards.removeAll { $0.id == forward.id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
                if let problem = forward.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        Button("Add Port Forward") {
            connection.forwards.append(PortForward())
        }
        Text("Opened with every ssh terminal tab on this host. Local: a port on this Mac that leads to a host and port as the server sees them. Remote: a port on the server that leads back to one on this Mac. SOCKS5: a proxy on this Mac that goes out through the server. Each listens on the loopback address only, and a rule that isn't valid is left out. A second tab on the same host finds the port taken and carries on without that forward.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// Settings → Connections → type a host, or a pattern, and go.
struct QuickConnectSection: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: WorkspaceStore
    @State private var text = ""
    @State private var message: String?

    /// More than this at once is saved, not opened: a typo in a range should
    /// not become a screenful of tabs.
    private static let openLimit = 8

    private var outcome: HostShorthand.Outcome? {
        text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : HostShorthand.parse(text)
    }

    var body: some View {
        Section("Quick connect") {
            HStack {
                TextField("Host or pattern", text: $text,
                          prompt: Text("deploy@web[1-3].example.com:2222"))
                    .onSubmit(connect)
                Button(buttonTitle, action: connect)
                    .disabled(!canConnect)
            }
            switch outcome {
            case .targets(let targets)?:
                Text(targets.count == 1
                     ? targets[0].display
                     : "\(targets.count) hosts: \(targets.prefix(3).map(\.display).joined(separator: ", "))\(targets.count > 3 ? ", …" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .invalid(let problem)?:
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case nil:
                EmptyView()
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("user@host:port, or ssh -p 2222 user@host. A pattern names several hosts: [1-3] counts (and [01-10] pads), {a,b} chooses. Hosts are saved under SSH hosts so the next connect is one click, and a host already saved is reused.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var targets: [HostShorthand.Target] {
        if case .targets(let list)? = outcome { return list }
        return []
    }

    private var canConnect: Bool { !targets.isEmpty }

    private var buttonTitle: String {
        let count = targets.count
        return count > 1 ? "Connect to \(count)" : "Connect"
    }

    private func connect() {
        let list = targets
        guard !list.isEmpty else { return }
        var opened = 0
        var created = 0
        for target in list {
            let user = target.user ?? NSUserName()
            let port = target.port ?? 22
            let existing = settings.sshConnections.first {
                $0.host.caseInsensitiveCompare(target.host) == .orderedSame
                    && $0.port == port
                    && $0.username == user
            }
            let connection: SSHConnection
            if let existing {
                connection = existing
            } else {
                connection = SSHConnection(name: target.host, host: target.host, port: port, username: user)
                settings.sshConnections.append(connection)
                created += 1
            }
            if list.count <= Self.openLimit {
                store.newTab(kind: .remote(connection.id))
                opened += 1
            }
        }
        if list.count > Self.openLimit {
            message = "Saved \(created) new host\(created == 1 ? "" : "s"). That is more than \(Self.openLimit), so none were opened."
        } else {
            message = "Opened \(opened) tab\(opened == 1 ? "" : "s")\(created > 0 ? ", saved \(created) new host\(created == 1 ? "" : "s")" : "")."
            text = ""
        }
    }
}

/// Settings → Connections → what a name or an address is, by this Mac's own
/// resolver.
struct HostLookupSection: View {
    @State private var query = ""
    @State private var isWorking = false
    @State private var lines: [String] = []

    var body: some View {
        Section("Look up a host") {
            HStack {
                TextField("Name or IP address", text: $query, prompt: Text("example.com or 192.168.1.20"))
                    .onSubmit(lookUp)
                Button("Look Up", action: lookUp)
                    .disabled(isWorking || query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if isWorking {
                ProgressView().controlSize(.small)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
            }
            Text("Uses this Mac's own resolver, so what it shows is what ssh would connect to. Nothing is sent to a lookup service.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func lookUp() {
        let asked = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty, !isWorking else { return }
        isWorking = true
        lines = []
        DispatchQueue.global(qos: .userInitiated).async {
            var result: [String] = []
            if let address = HostLookup.classify(asked) {
                result.append("\(address.text)  \(address.family.rawValue)")
                result.append("  \(address.kind.label)")
                if let name = HostLookup.reverse(address.text) {
                    result.append("  Name: \(name)")
                } else {
                    result.append("  No name found for it.")
                }
            } else {
                let addresses = HostLookup.resolve(asked)
                if addresses.isEmpty {
                    result.append("“\(asked)” didn't resolve to an address.")
                }
                for address in addresses {
                    result.append("\(address.text)  \(address.family.rawValue)")
                    result.append("  \(address.kind.label)")
                }
            }
            DispatchQueue.main.async {
                lines = result
                isWorking = false
            }
        }
    }
}
