import SwiftUI

/// Discovery state for one Proxmox host, kept out of the view so a refresh in
/// flight survives the Form redrawing.
///
/// Everything here describes exactly one host, and `hostID` says which. That
/// is not bookkeeping: a fetched certificate shown under a different host
/// would let "Trust" pin host A's certificate onto host B, which is precisely
/// the confusion pinning exists to prevent. Results that arrive after the
/// selection moved on are dropped rather than displayed.
@MainActor
final class ProxmoxBrowserModel: ObservableObject {
    @Published private(set) var guests: [ProxmoxGuest] = []
    @Published private(set) var status: String = ""
    @Published private(set) var isLoading = false
    /// A fingerprint fetched but not yet trusted, held so the user can compare
    /// it against what Proxmox shows before anything is pinned.
    @Published private(set) var candidateFingerprint: String?

    /// The host every published value above belongs to.
    private(set) var hostID: UUID?

    /// Point the model at a different host, discarding everything about the
    /// previous one. Work still in flight for the old host is ignored when it
    /// lands, because `hostID` no longer matches.
    func select(_ host: ProxmoxHost?) {
        guard host?.id != hostID else { return }
        hostID = host?.id
        guests = []
        status = ""
        candidateFingerprint = nil
        isLoading = false
    }

    /// A one-off message about the currently selected host.
    func note(_ message: String, for host: ProxmoxHost) {
        guard hostID == host.id else { return }
        status = message
    }

    func refresh(host: ProxmoxHost) async {
        hostID = host.id
        isLoading = true
        status = "Connecting to \(host.host)…"

        let client = ProxmoxClient(host: host)
        do {
            let found = try await client.discover()
            guard hostID == host.id else { return }
            guests = found
            let running = found.filter(\.isRunning).count
            status = found.isEmpty
                ? "Connected. This cluster reports no VMs or containers."
                : "\(found.count) found, \(running) running."
        } catch {
            guard hostID == host.id else { return }
            guests = []
            status = Self.failureMessage(error, client: client, host: host)
        }
        if hostID == host.id { isLoading = false }
    }

    func probe(host: ProxmoxHost) async {
        hostID = host.id
        isLoading = true
        status = "Fetching the certificate…"

        let fingerprint = await ProxmoxClient.probeFingerprint(for: host)
        guard hostID == host.id else { return }
        isLoading = false

        if let fingerprint {
            candidateFingerprint = fingerprint
            status = "Compare this with Proxmox → Datacenter → your node → Certificates before trusting it."
        } else {
            candidateFingerprint = nil
            status = "No certificate came back. Check the address and port."
        }
    }

    /// Blame the certificate only when a certificate was actually refused.
    ///
    /// A missing token is thrown before any request is made, and a mistyped
    /// address or an unreachable host never reaches a trust decision either —
    /// telling the user to go and confirm a certificate in any of those cases
    /// sends them to the one place that cannot help.
    private static func failureMessage(
        _ error: Error,
        client: ProxmoxClient,
        host: ProxmoxHost
    ) -> String {
        guard let refused = client.lastRefusedFingerprint else {
            return error.localizedDescription
        }
        let shown = CertificateFingerprint.display(refused)
        if host.isPinned {
            return "This host presented \(shown), which is not the certificate pinned for it. If you replaced the certificate, forget the old one and confirm the new one below."
        }
        return "The system does not trust this host's certificate (\(shown)). Fetch and confirm it below to pin it."
    }
}

struct ProxmoxSettingsSection: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = ProxmoxBrowserModel()
    @State private var selectedID: UUID?
    @State private var tokenSecret: String = ""

    var body: some View {
        Section("Proxmox") {
            if settings.proxmoxHosts.isEmpty {
                Text("No Proxmox hosts yet. Add one to list its VMs and open their consoles in the browser panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Host", selection: $selectedID) {
                    Text("None").tag(UUID?.none)
                    ForEach(settings.proxmoxHosts) { host in
                        Text("\(host.name) — \(host.subtitle)").tag(UUID?.some(host.id))
                    }
                }
            }
            HStack {
                Button("Add Proxmox Host") { addHost() }
                if let selectedID {
                    Button("Remove", role: .destructive) { remove(selectedID) }
                }
            }
        }
        // Changing hosts must not carry the previous host's certificate,
        // token field, or guest list across.
        .onChange(of: selectedID) { _, newValue in
            tokenSecret = ""
            model.select(settings.proxmoxHosts.first { $0.id == newValue })
        }

        if let selectedID, let binding = hostBinding(selectedID) {
            Section("Proxmox details") {
                TextField("Name", text: binding.name)
                TextField("Address", text: binding.host, prompt: Text("pve.lan"))
                TextField("Port", value: binding.port, format: .number)
                TextField("Token ID", text: binding.tokenID,
                          prompt: Text("root@pam!iterminal"))
                SecureField("Token secret", text: $tokenSecret)
                    .onSubmit { saveToken(for: binding.wrappedValue) }
                Button("Save Token") { saveToken(for: binding.wrappedValue) }
                    .disabled(tokenSecret.isEmpty)
                Text("""
                Create the token in Proxmox under Datacenter → Permissions → API Tokens. \
                Only the secret is kept in the Keychain; the token ID is stored with the host.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Certificate") {
                if let pinned = binding.wrappedValue.pinnedFingerprint, !pinned.isEmpty {
                    LabeledContent("Pinned") {
                        Text(CertificateFingerprint.display(pinned))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Button("Forget Certificate") {
                        binding.wrappedValue.pinnedFingerprint = nil
                    }
                } else {
                    Text("Nothing pinned yet. A default Proxmox install serves a self-signed certificate, which this app will not accept until you have confirmed it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let candidate = model.candidateFingerprint,
                   model.hostID == binding.wrappedValue.id {
                    LabeledContent("Server presented") {
                        Text(CertificateFingerprint.display(candidate))
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Button("Trust This Certificate") {
                        binding.wrappedValue.pinnedFingerprint = candidate
                        model.select(binding.wrappedValue)
                    }
                }

                Button("Fetch Certificate") {
                    let host = binding.wrappedValue
                    Task { await model.probe(host: host) }
                }
                Text("Pinning applies to this host and port alone, and covers both the API and the console in the browser panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Virtual machines") {
                HStack {
                    Button("Refresh") {
                        let host = binding.wrappedValue
                        Task { await model.refresh(host: host) }
                    }
                    .disabled(model.isLoading)
                    if model.isLoading {
                        ProgressView().controlSize(.small)
                    }
                }

                if !model.status.isEmpty {
                    Text(model.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if model.hostID == binding.wrappedValue.id {
                    ForEach(model.guests) { guest in
                        ProxmoxGuestRow(
                            guest: guest,
                            host: binding.wrappedValue,
                            onAddSSH: { addSSHConnection(for: $0, host: binding.wrappedValue) }
                        )
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func addHost() {
        let host = ProxmoxHost(name: "Proxmox", host: "")
        settings.proxmoxHosts.append(host)
        selectedID = host.id
        tokenSecret = ""
        model.select(host)
    }

    private func remove(_ id: UUID) {
        if let host = settings.proxmoxHosts.first(where: { $0.id == id }) {
            // The token outlives the host record otherwise, leaving a secret
            // in the Keychain for something the user has deleted.
            _ = KeychainStore.delete(host.keychainAccount)
        }
        settings.proxmoxHosts.removeAll { $0.id == id }
        selectedID = nil
        tokenSecret = ""
        model.select(nil)
    }

    private func saveToken(for host: ProxmoxHost) {
        guard !tokenSecret.isEmpty else { return }
        let saved = KeychainStore.set(tokenSecret, for: host.keychainAccount)
        model.note(saved ? "Token saved to the Keychain."
                         : "The Keychain refused to save the token.", for: host)
        // Never keep it in view state once it is stored.
        tokenSecret = ""
    }

    /// Turns a discovered guest into a saved SSH host, so a Linux VM found
    /// here becomes connectable with the machinery the app already has.
    private func addSSHConnection(for guest: ProxmoxGuest, host: ProxmoxHost) {
        guard let address = guest.primaryAddress else { return }
        let connection = SSHConnection(
            name: guest.displayName,
            host: address,
            username: NSUserName()
        )
        settings.sshConnections.append(connection)
        model.note("Added \(guest.displayName) (\(address)) to saved hosts.", for: host)
    }

    private func hostBinding(_ id: UUID) -> Binding<ProxmoxHost>? {
        guard settings.proxmoxHosts.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: {
                settings.proxmoxHosts.first { $0.id == id }
                    ?? ProxmoxHost(name: "", host: "")
            },
            set: { newValue in
                guard let index = settings.proxmoxHosts.firstIndex(where: { $0.id == id }) else { return }
                settings.proxmoxHosts[index] = newValue
            }
        )
    }
}

/// One VM or container, with the two things worth doing to it.
private struct ProxmoxGuestRow: View {
    let guest: ProxmoxGuest
    let host: ProxmoxHost
    let onAddSSH: (ProxmoxGuest) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(guest.isRunning ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(guest.displayName)
                    .font(.system(size: 12, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Console") { openConsole() }
                .disabled(!guest.isRunning)
            if guest.primaryAddress != nil {
                Button("Add SSH") { onAddSSH(guest) }
            }
        }
    }

    private var subtitle: String {
        var parts = ["\(guest.kind.label) \(guest.vmid)", guest.status]
        if let address = guest.primaryAddress { parts.append(address) }
        return parts.joined(separator: " · ")
    }

    /// Proxmox already serves a noVNC console over its web UI, so opening it
    /// in the app's browser panel is the whole feature — no VNC client, and no
    /// dependence on a port that Proxmox does not actually leave listening.
    private func openConsole() {
        // Straight off the host: building this URL is pure string work, and
        // constructing a client to do it would spin up a URLSession per click.
        guard let url = host.consoleURL(for: guest) else { return }
        WorkspaceStore.shared.openLinkFromTerminal(url.absoluteString)
    }
}
