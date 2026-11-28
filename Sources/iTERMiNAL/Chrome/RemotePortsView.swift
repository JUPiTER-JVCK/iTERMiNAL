import SwiftUI
import AppKit

/// What the Remote Ports list is showing, and what asking it for something does.
///
/// It scans the machine the focused terminal is on — a saved host for a remote
/// tab, this Mac for anything else — and only while the list is open: once when
/// it opens, again every few seconds while it stays open, and on request. Nothing
/// polls in the background, which is the whole of what "off by default, so the
/// scan only runs when you ask for it" can honestly mean.
final class RemotePortsModel: ObservableObject {
    @Published private(set) var ports: [ListeningPort] = []
    @Published private(set) var isScanning = false
    @Published private(set) var error: PortToolError?
    /// Where the list came from, for its heading.
    @Published private(set) var machineName = "This Mac"
    /// Set while a forward is being made, so a second click does not start a second.
    @Published private(set) var openingPort: Int?
    @Published var note: String?

    private var connection: SSHConnection?
    private var timer: Timer?
    /// A scan that finishes after the list moved to another machine is not for it.
    private var generation = 0

    static let refreshInterval: TimeInterval = 5

    func start(store: WorkspaceStore) {
        retarget(store: store)
        scan()
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            guard let self, !self.isScanning else { return }
            self.scan()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        generation += 1
        isScanning = false
    }

    /// Looks at the focused terminal again, so reopening the list on another
    /// tab scans that tab's machine.
    private func retarget(store: WorkspaceStore) {
        let session = store.focusedSession
        let next = session?.kind.isRemote == true ? session?.connection : nil
        if next?.id != connection?.id {
            ports = []
            error = nil
        }
        connection = next
        machineName = next.map { $0.name.isEmpty ? $0.host : $0.name } ?? "This Mac"
    }

    func scan() {
        generation += 1
        let mine = generation
        isScanning = true
        let target: PortScanner.Target
        if let connection {
            target = .host(connection)
        } else {
            target = .thisMac
        }
        PortScanner.scan(target) { [weak self] result in
            guard let self, self.generation == mine else { return }
            self.isScanning = false
            switch result {
            case .success(let found):
                self.ports = found
                self.error = nil
            case .failure(let failure):
                self.error = failure
            }
        }
    }

    /// What choosing `port` does: whatever fits what it is. A web page opens in
    /// the browser panel, ssh opens a terminal tab, VNC and RDP go to the
    /// system's client, and anything else (a database, a cache) is forwarded
    /// and its address copied, since there is no page to show for it.
    func activate(
        _ port: ListeningPort,
        store: WorkspaceStore,
        settings: AppSettings,
        dismiss: @escaping () -> Void
    ) {
        guard openingPort == nil else { return }
        note = nil
        switch port.action {
        case .browser:
            open(port, store: store)
        case .ssh:
            if let connection, port.port == connection.port {
                store.newTab(kind: .remote(connection.id))
                dismiss()
            } else if connection == nil {
                copy("ssh -p \(port.port) localhost")
                note = "Copied ssh -p \(port.port) localhost"
            } else {
                forwardAndCopy(port)
            }
        case .vnc, .rdp:
            let service = RemoteService(
                name: machineName,
                kind: port.action == .vnc ? .vnc : .rdp,
                host: connection == nil ? "localhost" : port.forwardHost,
                port: port.port,
                tunnelThrough: connection?.id
            )
            openingPort = port.port
            RemoteServiceLauncher.open(service, store: store, settings: settings) { [weak self] failure in
                DispatchQueue.main.async {
                    self?.openingPort = nil
                    if let failure { self?.error = PortToolError(failure.localizedDescription) }
                }
            }
        case .forward:
            forwardAndCopy(port)
        }
    }

    /// The facts about `port`, as text for the clipboard.
    func copyDetails(_ port: ListeningPort) {
        let lines = port.details(machine: machineName, onHost: connection != nil)
            .map { "\($0.label): \($0.value)" }
        copy((["Port \(port.port) on \(machineName)"] + lines).joined(separator: "\n"))
        note = "Copied the details of port \(port.port)"
    }

    /// Whether the list is of a saved host rather than this Mac.
    var isOnHost: Bool { connection != nil }

    /// Opens `port` in the in-app browser: directly for a port on this Mac,
    /// through a forward for one on a host.
    func open(_ port: ListeningPort, https: Bool? = nil, store: WorkspaceStore) {
        guard openingPort == nil else { return }
        let secure = https ?? port.prefersHTTPS
        func browse(_ localPort: Int) {
            store.openLinkFromTerminal("\(secure ? "https" : "http")://localhost:\(localPort)")
        }
        guard let connection else {
            browse(port.port)
            return
        }
        openingPort = port.port
        note = nil
        TunnelManager.shared.open(
            through: connection,
            targetHost: port.forwardHost,
            targetPort: port.port
        ) { [weak self] result in
            self?.openingPort = nil
            switch result {
            case .success(let tunnel):
                browse(tunnel.localPort)
            case .failure(let failure):
                self?.error = failure
            }
        }
    }

    /// Forwards without opening anything, and copies the address.
    func forwardAndCopy(_ port: ListeningPort) {
        guard let connection else {
            copy("localhost:\(port.port)")
            note = "Copied localhost:\(port.port)"
            return
        }
        guard openingPort == nil else { return }
        openingPort = port.port
        TunnelManager.shared.open(
            through: connection,
            targetHost: port.forwardHost,
            targetPort: port.port
        ) { [weak self] result in
            self?.openingPort = nil
            switch result {
            case .success(let tunnel):
                self?.copy("localhost:\(tunnel.localPort)")
                self?.note = "Copied localhost:\(tunnel.localPort)"
            case .failure(let failure):
                self?.error = failure
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The status bar's right corner: a globe that opens the Connect list and, when
/// turned on in Settings, a second icon that opens the Listening ports. Two
/// buttons with a popover each, rather than one popover with tabs, so each
/// opens at its own fixed size and always in the same place. Either can be
/// turned off under Appearance → Status.
struct RemotePortsButton: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(spacing: 10) {
            if settings.showConnectButton {
                ConnectButton()
            }
            if settings.showRemotePorts {
                PortsButton()
            }
        }
    }
}

/// The globe: saved hosts, screen sharing and machines on this network.
private struct ConnectButton: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID
    @State private var isOpen = false

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        Button {
            isOpen.toggle()
        } label: {
            Image(systemName: "globe")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isOpen ? theme.textPrimary : theme.textSecondary)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Connect to a host")
        .accessibilityLabel("Connect to a host")
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            ConnectList(dismiss: { isOpen = false })
                .padding(12)
                .frame(width: 340)
                .environmentObject(store)
        }
    }
}

/// The listening ports of the focused terminal's machine, with a count of the
/// forwards that are open.
private struct PortsButton: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID
    @ObservedObject private var tunnels = TunnelManager.shared
    @StateObject private var model = RemotePortsModel()
    @State private var isOpen = false

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11, weight: .medium))
                if !tunnels.tunnels.isEmpty {
                    Text("\(tunnels.tunnels.count)")
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(isOpen ? theme.textPrimary : theme.textSecondary)
            .frame(minWidth: 22, minHeight: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("See listening ports")
        .accessibilityLabel("Listening ports")
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            RemotePortsPopover(model: model, dismiss: { isOpen = false })
                .environmentObject(store)
        }
    }
}

private struct RemotePortsPopover: View {
    @ObservedObject var model: RemotePortsModel
    let dismiss: () -> Void
    @ObservedObject private var tunnels = TunnelManager.shared
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID
    /// Ports it has been asked to show every fact about.
    @State private var expanded: Set<Int> = []

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        portsContent(theme: theme)
            .padding(12)
            .frame(width: 460)
            // Scanning runs only while the list is open.
            .onAppear { model.start(store: store) }
            .onDisappear { model.stop() }
    }

    private func portsContent(theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Listening ports")
                        .font(.system(size: 12, weight: .semibold))
                    Text(model.machineName)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                if model.isScanning {
                    ProgressView().controlSize(.small)
                }
                Button {
                    model.scan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Scan again")
                .disabled(model.isScanning)
            }

            if let error = model.error {
                Label(error.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = model.note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
            }

            // A fixed height, so the popover is the same size whatever is in it.
            ScrollView {
                if model.ports.isEmpty {
                    Text(model.isScanning ? "Scanning…" : "No listening TCP ports found.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                } else {
                    VStack(spacing: 2) {
                        ForEach(model.ports) { port in
                            row(port, theme: theme)
                        }
                    }
                }
            }
            .frame(height: 340)

            if !tunnels.tunnels.isEmpty {
                Divider()
                Text("Open forwards")
                    .font(.system(size: 11, weight: .semibold))
                ForEach(tunnels.tunnels) { tunnel in
                    HStack {
                        Text(tunnel.summary)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 6)
                        Button {
                            tunnels.close(tunnel.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .help("Close this forward")
                    }
                }
            }

            Text("Choosing a port does what fits it: a web page opens in the browser panel, ssh opens a tab, VNC and RDP open the system's client, and anything else (a database, say) is forwarded and its address copied. On a host that goes through an ssh forward that listens on this Mac only. The arrow shows everything known about a port.")
                .font(.system(size: 10))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func icon(for port: ListeningPort) -> String {
        switch port.action {
        case .browser: return port.isLikelyWeb ? "safari" : "network"
        case .ssh: return "terminal"
        case .vnc: return "display"
        case .rdp: return "macwindow.on.rectangle"
        case .forward: return "arrow.triangle.branch"
        }
    }

    private func row(_ port: ListeningPort, theme: Theme) -> some View {
        let isExpanded = expanded.contains(port.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 2) {
                Button {
                    model.activate(port, store: store, settings: settings, dismiss: dismiss)
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon(for: port))
                            .frame(width: 16)
                            .padding(.top, 1)
                            .foregroundStyle(theme.textSecondary)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(String(port.port))
                                    .font(.system(size: 12, weight: .medium))
                                    .monospacedDigit()
                                if let name = port.service?.name {
                                    Text(name)
                                        .font(.system(size: 11, weight: .medium))
                                        .lineLimit(1)
                                }
                                if let process = port.process {
                                    Text(process)
                                        .font(.system(size: 11))
                                        .foregroundStyle(theme.textSecondary)
                                        .lineLimit(1)
                                }
                            }
                            Text(port.summaryLine())
                                .font(.system(size: 10))
                                .foregroundStyle(theme.textSecondary)
                                .lineLimit(1)
                            if let about = port.service?.summary {
                                Text(about)
                                    .font(.system(size: 10))
                                    .foregroundStyle(theme.textSecondary)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 4)
                        if model.openingPort == port.port {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .padding(.vertical, 3)
                    .padding(.leading, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.openingPort != nil)
                .help(port.actionSummary(onHost: model.isOnHost, machine: model.machineName))

                Button {
                    if isExpanded { expanded.remove(port.id) } else { expanded.insert(port.id) }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(isExpanded ? "Hide details" : "Show everything known about this port")
                .accessibilityLabel(isExpanded ? "Hide details of port \(port.port)" : "Show details of port \(port.port)")
            }

            if isExpanded {
                detailGrid(port, theme: theme)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isExpanded ? theme.surface : Color.clear)
        )
        .contextMenu {
            Button("Choose Port") {
                model.activate(port, store: store, settings: settings, dismiss: dismiss)
            }
            Divider()
            Button("Open in Browser Panel") { model.open(port, https: false, store: store) }
            Button("Open as HTTPS") { model.open(port, https: true, store: store) }
            Button("Forward and Copy Address") { model.forwardAndCopy(port) }
            Divider()
            Button("Copy Details") { model.copyDetails(port) }
        }
    }

    private func detailGrid(_ port: ListeningPort, theme: Theme) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 3) {
            ForEach(port.details(machine: model.machineName, onHost: model.isOnHost), id: \.label) { detail in
                GridRow {
                    Text(detail.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .gridColumnAlignment(.trailing)
                    Text(detail.value)
                        .font(.system(size: 10, design: detail.label == "Command" ? .monospaced : .default))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
        .padding(.bottom, 8)
    }
}

/// Saved SSH/mosh hosts (a new tab), saved screen-sharing endpoints (through the
/// system's client) and anything the network is advertising.
private struct ConnectList: View {
    let dismiss: () -> Void

    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID
    @ObservedObject private var discovery = ServiceDiscovery.shared
    /// Set once the person has asked to look for machines, so the next time the
    /// list opens it looks again and the green marks are there without asking
    /// twice. Never set by anything but pressing the button.
    @AppStorage("globeNetworkScan") private var scanOptIn = false

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        VStack(alignment: .leading, spacing: 10) {
            // A fixed height, so the popover is the same size whatever is in it.
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    group("Saved hosts", theme: theme) {
                        if settings.sshConnections.isEmpty {
                            Text("No saved hosts — add one in Settings → Connections")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.textSecondary)
                                .padding(.horizontal, 6)
                        } else {
                            ForEach(settings.sshConnections) { connection in
                                row(
                                    icon: "terminal",
                                    title: connection.name,
                                    detail: connection.subtitle,
                                    live: isAdvertised(connection),
                                    theme: theme
                                ) {
                                    store.newTab(kind: .remote(connection.id))
                                    dismiss()
                                }
                            }
                        }
                    }

                    if !settings.remoteServices.isEmpty {
                        group("Screen sharing", theme: theme) {
                            ForEach(settings.remoteServices) { service in
                                row(
                                    icon: "display",
                                    title: service.name,
                                    detail: service.subtitle,
                                    live: isAdvertised(service),
                                    theme: theme
                                ) {
                                    RemoteServiceLauncher.open(service, store: store, settings: settings)
                                    dismiss()
                                }
                            }
                        }
                    }

                    if !discovery.services.isEmpty {
                        group("On this network", theme: theme) {
                            ForEach(discovery.services) { service in
                                row(
                                    icon: "network",
                                    title: service.name,
                                    detail: service.kind.shortLabel,
                                    live: true,
                                    theme: theme
                                ) {
                                    connect(service)
                                    dismiss()
                                }
                            }
                        }
                    }
                }
            }
            .frame(height: 300)

            Divider()
            if discovery.isBrowsing {
                HStack(spacing: 5) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(.green)
                    Text("Green: advertising on this network now")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textSecondary)
                }
                .padding(.horizontal, 6)
            }
            // Discovery is started by asking, not at launch, so a user who
            // never asks is never asked for local network access.
            Button(discovery.isBrowsing ? "Refresh Network Scan" : "Look for Machines on This Network") {
                scanOptIn = true
                discovery.restart()
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
        }
        .onAppear {
            if scanOptIn { discovery.start() }
        }
    }

    /// Whether something the network is advertising right now is this saved
    /// host: an ssh or sftp service under the same name or address.
    private func isAdvertised(_ connection: SSHConnection) -> Bool {
        discovery.services.contains { service in
            (service.kind == .ssh || service.kind == .sftp)
                && (ServiceNameMatch.matches(service.name, connection.name)
                    || ServiceNameMatch.matches(service.name, connection.host))
        }
    }

    /// The same for a saved screen-sharing, desktop or web service: one of its
    /// own kind (ssh and sftp count as one) under the same name or address.
    private func isAdvertised(_ saved: RemoteService) -> Bool {
        func family(_ kind: RemoteServiceKind) -> RemoteServiceKind { kind == .sftp ? .ssh : kind }
        return discovery.services.contains { service in
            family(service.kind) == family(saved.kind)
                && (ServiceNameMatch.matches(service.name, saved.name)
                    || ServiceNameMatch.matches(service.name, saved.host))
        }
    }

    private func group<Content: View>(_ title: String, theme: Theme, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 6)
            content()
        }
    }

    /// `live` marks something that is advertising itself on the network right
    /// now, as against one that is only saved: its icon is green.
    private func row(
        icon: String,
        title: String,
        detail: String,
        live: Bool,
        theme: Theme,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 16)
                    .foregroundStyle(live ? Color.green : theme.textSecondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(live ? "Advertising on this network now" : "")
        .accessibilityValue(live ? "Available on this network" : "")
    }

    /// Resolves the advertised service to an address, then opens it. The
    /// lookup is why this is not a one-liner: Bonjour hands out a service
    /// name, and nothing knows the host behind it until something asks.
    private func connect(_ service: DiscoveredService) {
        discovery.resolve(service) { result in
            guard case .success(let resolved) = result else { return }
            RemoteServiceLauncher.open(
                RemoteService(
                    name: service.name,
                    kind: service.kind,
                    host: resolved.host,
                    port: resolved.port
                ),
                store: store,
                settings: settings
            )
        }
    }
}
