import SwiftUI
import AppKit

struct ConnectionsSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var selectedID: UUID?

    var body: some View {
        Form {
            Section("Saved hosts") {
                if settings.sshConnections.isEmpty {
                    Text("No hosts yet. Add one to browse it in the Files panel over SFTP.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Host", selection: $selectedID) {
                        Text("None").tag(UUID?.none)
                        ForEach(settings.sshConnections) { connection in
                            Text("\(connection.name) — \(connection.subtitle)").tag(UUID?.some(connection.id))
                        }
                    }
                }
                HStack {
                    Button("Add Host") { addConnection() }
                    Button("Add This Mac") { addThisMac() }
                    if let selectedID {
                        Button("Remove", role: .destructive) { remove(selectedID) }
                    }
                }
            }

            if let selectedID, let binding = connectionBinding(selectedID) {
                Section("Details") {
                    TextField("Name", text: binding.name)
                    Picker("Transport", selection: binding.transport) {
                        ForEach(SSHTransport.allCases) { transport in
                            Text(transport.label).tag(transport)
                        }
                    }
                    TextField("Host", text: binding.host)
                    TextField("Username", text: binding.username)
                    TextField("Port", value: binding.port, format: .number)
                    TextField("Identity file (optional)", text: Binding(
                        get: { binding.wrappedValue.identityFile ?? "" },
                        set: { binding.wrappedValue.identityFile = $0.isEmpty ? nil : $0 }
                    ), prompt: Text("~/.ssh/id_ed25519"))
                    TextField("Start directory (optional)", text: Binding(
                        get: { binding.wrappedValue.initialPath ?? "" },
                        set: { binding.wrappedValue.initialPath = $0.isEmpty ? nil : $0 }
                    ), prompt: Text("~"))

                    if binding.wrappedValue.transport == .ssh {
                        TextField("Jump host(s) (optional)", text: binding.jumpHosts,
                                  prompt: Text("bastion.example.com"))
                        if let problem = binding.wrappedValue.jumpHostsProblem {
                            Label(problem, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            Text("Hosts to go through on the way, in order, as user@host:port and separated by commas. The terminal and the file browser both use them. Nothing connects directly while this has something wrong with it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Picker("Forward SSH agent", selection: binding.agentForwarding) {
                            ForEach(AgentForwarding.allCases) { choice in
                                Text(choice.label).tag(choice)
                            }
                        }
                        Text(Self.agentCaption(binding.wrappedValue.agentForwarding))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if binding.wrappedValue.transport == .custom {
                        TextField("Command", text: binding.customCommand,
                                  prompt: Text("tailscale ssh %u@%h"))
                        Text("Runs in the terminal as written. %h, %p, %u, and %d expand to host, port, username, and user@host.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        TextField("Extra arguments (optional)", text: binding.extraArguments,
                                  prompt: Text("-o ServerAliveInterval=30"))
                    }

                    ConnectionTestRow(connection: binding.wrappedValue)
                }

                HostOptionsSection(connection: binding)
            }

            QuickConnectSection()

            HostLookupSection()

            RemoteServicesSettingsSection()

            ProxmoxSettingsSection()

            Section("Authentication") {
                Toggle("Share each ssh tab's sign-in with the file browser", isOn: $settings.shareSignInWithFiles)
                Text("On, a new ssh tab keeps its connection open, and the file browser, the port scan and forwards use it. A host that wants a password then needs signing in to once, in a tab, and the file browser fills in by itself; closing the tab ends the sharing. The connection is reachable only by this account, through a private folder. Applies to tabs opened from now on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("""
                iTERMiNAL never stores SSH passwords. Both remote features run the system's own clients, reusing your ssh-agent, keys, and known_hosts.

                Terminal sessions get a real TTY, so ssh can prompt you for a password or 2FA code itself. The file browser runs sftp non-interactively (it has no TTY to prompt on), so it signs in with a key — or through a terminal tab you have signed in to.

                A host that only wants a password: Test File Access, above, says so in plain words. Press Sign In in a Terminal, enter the password in the tab that opens, and keep the tab open — the file browser uses that connection, and the password goes to ssh in the tab, never to iTERMiNAL. Or install a key: it offers to type the ssh-copy-id command, and you press Return and enter the password once.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// What each choice does, in a line, under the picker.
    private static func agentCaption(_ choice: AgentForwarding) -> String {
        switch choice {
        case .sshConfig:
            return "Adds nothing: ~/.ssh/config decides, as it does for ssh outside this app."
        case .never:
            return "Never forwards, even where ~/.ssh/config says to."
        case .ask:
            return "Asks each time a tab connects or reconnects. Return answers no."
        case .always:
            return "Forwards on every connection. While you are connected, a program on the host — or anyone who can act as you there — can use your keys to sign in elsewhere."
        }
    }

    private func addConnection() {
        let connection = SSHConnection(name: "New Host", host: "", username: NSUserName())
        settings.sshConnections.append(connection)
        selectedID = connection.id
    }

    /// This Mac as a host, for trying a connection, a port forward or the
    /// remote ports list against a machine that is certainly there. It needs
    /// Remote Login switched on in System Settings → General → Sharing, which
    /// this does not do.
    private func addThisMac() {
        let connection = SSHConnection(name: "This Mac", host: "127.0.0.1", username: NSUserName())
        settings.sshConnections.append(connection)
        selectedID = connection.id
    }

    private func remove(_ id: UUID) {
        settings.sshConnections.removeAll { $0.id == id }
        selectedID = nil
    }

    /// Looks the element up by id on every access, so the binding stays valid
    /// even when the list is reordered or edited underneath it.
    private func connectionBinding(_ id: UUID) -> Binding<SSHConnection>? {
        guard settings.sshConnections.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: {
                settings.sshConnections.first { $0.id == id }
                    ?? SSHConnection(name: "", host: "", username: "")
            },
            set: { newValue in
                guard let index = settings.sshConnections.firstIndex(where: { $0.id == id }) else { return }
                settings.sshConnections[index] = newValue
            }
        )
    }
}
