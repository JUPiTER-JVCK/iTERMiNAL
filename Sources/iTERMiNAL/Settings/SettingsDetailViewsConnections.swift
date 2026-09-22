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

                    if binding.wrappedValue.transport == .custom {
                        TextField("Command", text: binding.customCommand,
                                  prompt: Text("tailscale ssh %u@%h"))
                        Text("Runs in the terminal as written. %h, %p, %u, and %d expand to host, port, username, and user@host.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        TextField("Extra arguments (optional)", text: binding.extraArguments,
                                  prompt: Text("-A -J bastion"))
                    }
                }
            }

            RemoteServicesSettingsSection()

            ProxmoxSettingsSection()

            Section("Authentication") {
                Text("""
                iTERMiNAL never stores SSH passwords. Both remote features run the system's own clients, reusing your ssh-agent, keys, and known_hosts.

                Terminal sessions get a real TTY, so ssh can prompt you for a password or 2FA code itself. The file browser runs sftp non-interactively (it has no TTY to prompt on), so browsing a host requires key-based authentication.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func addConnection() {
        let connection = SSHConnection(name: "New Host", host: "", username: NSUserName())
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
