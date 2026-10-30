import SwiftUI
import AppKit

/// Settings → Connections → the two sections that are not SSH hosts: what the
/// network is advertising right now, and the screen-sharing endpoints saved by
/// hand.
struct RemoteServicesSettingsSection: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.openWindow) private var openWindow
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
                    if service.kind == .vnc {
                        Picker("Open with", selection: $service.viewer) {
                            ForEach(RemoteViewer.allCases) { viewer in
                                Text(viewer.label).tag(viewer)
                            }
                        }
                        if service.viewer == .builtIn {
                            Text("Opens a window in this app. It does no sign-in or a VNC password, asked each time and never saved; macOS Screen Sharing's own sign-in is not supported unless “VNC viewers may control screen with password” is on. The picture is sent uncompressed, so it suits a local network or a tunnel better than a slow link. The connection is not encrypted unless it goes through an SSH host.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !service.kind.isHandledInApp {
                        Picker("Go through", selection: $service.tunnelThrough) {
                            Text("Connect directly").tag(UUID?.none)
                            ForEach(settings.sshConnections) { connection in
                                Text("SSH: \(connection.name.isEmpty ? connection.host : connection.name)")
                                    .tag(UUID?.some(connection.id))
                            }
                        }
                        if service.tunnelThrough != nil {
                            Text("The host above is read as the SSH host sees it. An ssh forward carries the connection to a port on this Mac, and the client is pointed there. It signs in with a key or an open terminal tab, never a typed password.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button("Connect") { open(service) }
                        Button("Remove", role: .destructive) {
                            settings.remoteServices.removeAll { $0.id == service.id }
                        }
                    }
                }
            }

            HStack {
                Button("Add Service") {
                    settings.remoteServices.append(
                        RemoteService(name: "New service", kind: .vnc, host: "")
                    )
                }
                Button("Share This Mac's Screen…") {
                    RemoteServiceLauncher.openSharingSettings()
                }
            }

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("""
            iTERMiNAL does not implement VNC or RDP. It hands the address to whichever app on this Mac has registered the scheme — Screen Sharing for vnc://, Microsoft Remote Desktop or similar for rdp:// — so that client is what authenticates and no password is ever stored here.

            SSH, SFTP and web entries open inside the app instead: a terminal tab, the Files panel, and the browser panel.

            Share This Mac's Screen opens System Settings → General → Sharing, where Screen Sharing is switched on or off. iTERMiNAL does not change it.
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
        let launch = {
            RemoteServiceLauncher.open(service, store: store, settings: settings) { error in
                message = error?.localizedDescription
            }
        }
        // The built-in viewer's window is opened by the main window, which has
        // to be there to hear it.
        if service.kind == .vnc, service.viewer == .builtIn {
            openWindow(id: "main")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: launch)
        } else {
            launch()
        }
    }
}
