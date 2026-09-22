import SwiftUI
import AppKit

/// Settings → Connections → the two sections that are not SSH hosts: what the
/// network is advertising right now, and the screen-sharing endpoints saved by
/// hand.
struct RemoteServicesSettingsSection: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: WorkspaceStore
    // Observed, not owned: the browser is a singleton that keeps listening
    // while the settings window is closed, so this view must not be the thing
    // that decides its lifetime.
    @ObservedObject private var discovery = ServiceDiscovery.shared
    @State private var message: String?
    /// Services currently being resolved, so a row can say it is working
    /// rather than appearing to do nothing for a few seconds.
    @State private var resolving: Set<String> = []

    var body: some View {
        Section("On this network") {
            if discovery.permissionLikelyDenied {
                Text("Nothing can be discovered without local network access. macOS asks once; if it was declined, grant it under System Settings → Privacy & Security → Local Network and press Refresh.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if discovery.services.isEmpty {
                Text(discovery.isBrowsing
                     ? "Listening for machines advertising screen sharing, SSH or file sharing…"
                     : "Not listening.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(discovery.services) { service in
                HStack(spacing: 8) {
                    Image(systemName: service.kind.icon)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(service.name)
                        Text(service.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if resolving.contains(service.id) {
                        Text("Connecting…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Connect") { connect(service) }
                        Button("Save") { save(service) }
                    }
                }
            }

            HStack {
                Button(discovery.isBrowsing ? "Refresh" : "Start Listening") {
                    message = nil
                    discovery.restart()
                }
                if discovery.isBrowsing {
                    Button("Stop") { discovery.stop() }
                }
            }

            Text("Browsing only — this advertises nothing about this Mac, and opens no connection until you pick something. A Bonjour listing names a service, not an address, so the address is looked up at the moment you connect.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { discovery.start() }

        Section("Screen sharing and remote desktop") {
            ForEach($settings.remoteServices) { $service in
                DisclosureGroup(service.name.isEmpty ? "Untitled" : service.name) {
                    Picker("Protocol", selection: $service.kind) {
                        ForEach(RemoteServiceKind.allCases) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    TextField("Name", text: $service.name)
                    TextField("Host", text: $service.host, prompt: Text("studio.local"))
                    TextField("Port", value: $service.port, format: .number)
                    TextField("Username (optional)", text: $service.username)
                    HStack {
                        Button("Connect") { open(service) }
                        Button("Remove", role: .destructive) {
                            settings.remoteServices.removeAll { $0.id == service.id }
                        }
                    }
                }
            }

            Button("Add Service") {
                settings.remoteServices.append(
                    RemoteService(name: "New service", kind: .vnc, host: "")
                )
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("""
            iTERMiNAL does not implement VNC or RDP. It hands the address to whichever app on this Mac has registered the scheme — Screen Sharing for vnc://, Microsoft Remote Desktop or similar for rdp:// — so that client is what authenticates and no password is ever stored here.

            SSH, SFTP and web entries open inside the app instead: a terminal tab, the Files panel, and the browser panel.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    private func connect(_ service: DiscoveredService) {
        message = nil
        resolving.insert(service.id)
        discovery.resolve(service) { result in
            resolving.remove(service.id)
            switch result {
            case .success(let resolved):
                open(RemoteService(
                    name: service.name,
                    kind: service.kind,
                    host: resolved.host,
                    port: resolved.port
                ))
            case .failure(let error):
                message = error.localizedDescription
            }
        }
    }

    private func save(_ service: DiscoveredService) {
        message = nil
        resolving.insert(service.id)
        discovery.resolve(service) { result in
            resolving.remove(service.id)
            switch result {
            case .success(let resolved):
                let saved = RemoteService(
                    name: service.name,
                    kind: service.kind,
                    host: resolved.host,
                    port: resolved.port
                )
                // SSH and SFTP belong in the saved-hosts list, not here —
                // that is the list the sidebar, palette and dock all read.
                if saved.kind.isHandledInApp, saved.kind != .web {
                    let connection = RemoteServiceLauncher.savedConnection(
                        for: saved,
                        settings: settings
                    )
                    message = "Saved \(connection.name) under SSH hosts."
                } else {
                    settings.remoteServices.append(saved)
                    message = "Saved \(saved.name)."
                }
            case .failure(let error):
                message = error.localizedDescription
            }
        }
    }

    private func open(_ service: RemoteService) {
        RemoteServiceLauncher.open(service, store: store, settings: settings) { error in
            message = error?.localizedDescription
        }
    }
}
