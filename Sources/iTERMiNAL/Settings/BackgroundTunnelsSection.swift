import SwiftUI

/// Settings → Connections → forwards that run in the background.
struct BackgroundTunnelsSection: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var runner = SavedTunnelRunner.shared

    var body: some View {
        Section("Background tunnels") {
            if settings.savedTunnels.isEmpty {
                Text("No tunnels yet. A tunnel keeps a port forward open through a saved host without a terminal tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach($settings.savedTunnels) { $tunnel in
                DisclosureGroup {
                    editor($tunnel)
                } label: {
                    header(tunnel)
                }
            }
            Button("Add Tunnel") {
                settings.savedTunnels.append(SavedTunnel(connectionID: settings.sshConnections.first?.id))
            }
            Text("Each tunnel is an ssh -N of its own through the host you pick. It signs in with a key or your agent — a background process has no keyboard, so a host that only takes a password fails with that reason; Set Up Key Login on the host fixes it. Tunnels listen on this Mac's loopback only, run until you stop them or quit iTERMiNAL, and are not restarted if the connection drops.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func header(_ tunnel: SavedTunnel) -> some View {
        let state = runner.state(of: tunnel.id)
        return HStack(spacing: 8) {
            Circle()
                .fill(color(for: state))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(tunnel.name.isEmpty ? "Untitled" : tunnel.name)
                Text(tunnel.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if state.isActive {
                Button("Stop") { runner.stop(tunnel.id) }
            } else {
                Button("Start") { runner.start(tunnel, settings: settings) }
            }
        }
    }

    @ViewBuilder
    private func editor(_ tunnel: Binding<SavedTunnel>) -> some View {
        let state = runner.state(of: tunnel.wrappedValue.id)
        TextField("Name", text: tunnel.name)
        Picker("Through", selection: tunnel.connectionID) {
            Text("Choose a host").tag(UUID?.none)
            ForEach(settings.sshConnections) { connection in
                Text(connection.name.isEmpty ? connection.host : connection.name)
                    .tag(UUID?.some(connection.id))
            }
        }
        Picker("Kind", selection: tunnel.forward.kind) {
            ForEach(PortForward.Kind.allCases) { kind in
                Text(kind.label).tag(kind)
            }
        }
        HStack {
            Text(tunnel.wrappedValue.forward.kind == .remote ? "Port on the host" : "Port on this Mac")
            Spacer()
            TextField("Port", value: tunnel.forward.bindPort, format: .number.grouping(.never))
                .frame(width: 80)
                .multilineTextAlignment(.trailing)
        }
        if tunnel.wrappedValue.forward.kind != .dynamic {
            HStack {
                Text(tunnel.wrappedValue.forward.kind == .remote ? "Leads to, on this Mac" : "Leads to, from the host")
                Spacer()
                TextField("Host", text: tunnel.forward.targetHost)
                    .frame(width: 140)
                Text(":")
                TextField("Port", value: tunnel.forward.targetPort, format: .number.grouping(.never))
                    .frame(width: 70)
            }
        }
        if let problem = tunnel.wrappedValue.forward.problem {
            Label(problem, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        Toggle("Start when iTERMiNAL opens", isOn: tunnel.autoStart)
        if case .failed(let reason) = state {
            Label(reason, systemImage: "xmark.octagon.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        Button("Remove", role: .destructive) {
            runner.stop(tunnel.wrappedValue.id)
            let id = tunnel.wrappedValue.id
            settings.savedTunnels.removeAll { $0.id == id }
        }
    }

    private func color(for state: SavedTunnelRunner.State) -> Color {
        switch state {
        case .running: return .green
        case .starting: return .yellow
        case .failed: return .red
        case .stopped: return .secondary
        }
    }
}
