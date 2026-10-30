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

    /// Opens `port` in the in-app browser: directly for a port on this Mac,
    /// through a forward for one on a host.
    func open(_ port: ListeningPort, https: Bool? = nil, store: WorkspaceStore) {
        guard openingPort == nil else { return }
        let secure = https ?? (port.port == 443 || port.port == 8443)
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

/// The globe in the status bar's left corner, and the list it opens.
struct RemotePortsButton: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var tunnels = TunnelManager.shared
    @StateObject private var model = RemotePortsModel()
    @State private var isOpen = false

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "globe")
                    .font(.system(size: 11, weight: .medium))
                if !tunnels.tunnels.isEmpty {
                    Text("\(tunnels.tunnels.count)")
                        .font(.system(size: 10, weight: .medium))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(isOpen ? theme.textPrimary : theme.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Listening ports on the focused terminal's machine")
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            RemotePortsPopover(model: model)
                .environmentObject(store)
        }
        .onChange(of: isOpen) { _, open in
            if open {
                model.start(store: store)
            } else {
                model.stop()
            }
        }
    }
}

private struct RemotePortsPopover: View {
    @ObservedObject var model: RemotePortsModel
    @ObservedObject private var tunnels = TunnelManager.shared
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Listening ports")
                        .font(.system(size: 12, weight: .semibold))
                    Text(model.machineName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
            }

            if model.ports.isEmpty {
                Text(model.isScanning ? "Scanning…" : "No listening TCP ports found.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.ports) { port in
                            row(port)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }

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

            Text("Choosing a port opens it in the browser panel. On a host, it goes through an ssh forward that listens on this Mac only.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 340)
    }

    private func row(_ port: ListeningPort) -> some View {
        Button {
            model.open(port, store: store)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: port.isLikelyWeb ? "safari" : "network")
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text(String(port.port))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .frame(width: 52, alignment: .leading)
                VStack(alignment: .leading, spacing: 0) {
                    Text(port.process ?? "—")
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Text(port.scopeLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if model.openingPort == port.port {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.openingPort != nil)
        .contextMenu {
            Button("Open in Browser Panel") { model.open(port, https: false, store: store) }
            Button("Open as HTTPS") { model.open(port, https: true, store: store) }
            Divider()
            Button("Forward and Copy Address") { model.forwardAndCopy(port) }
        }
    }
}
