import AppKit
import Network

/// Whether this Mac has a network to reach a host over, and when that changes
/// in a way a dropped connection cares about. Read by `TerminalSession` so an
/// automatic reconnect is not spent while there is no network, and starts soon
/// after one comes back rather than when its wait would have ended (see
/// `AutoReconnect`).
///
/// It watches only this Mac's own view of its interfaces (`NWPathMonitor`): it
/// sends nothing anywhere, and needs no permission.
final class NetworkWatch {
    static let shared = NetworkWatch()

    /// Posted on the main thread when there is a network again, when it is a
    /// different one (Wi-Fi to Ethernet, say), and when the Mac wakes from
    /// sleep — each a moment when a connection that dropped may now work.
    static let mayReconnect = Notification.Name("com.jupiterjvck.iterminal.networkMayReconnect")

    /// Main thread only. True until the system says otherwise, so that a
    /// reading taken before the first report behaves as this app always has.
    private(set) var isOnline = true

    private let monitor = NWPathMonitor()
    private var started = false
    /// The interfaces the last report named, to tell a change of network from
    /// a report that changes nothing that matters here.
    private var interfaces: [String] = []
    private var wakeObserver: NSObjectProtocol?

    private init() {}

    /// Starts watching, once; later calls do nothing. Main thread only.
    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let names = path.availableInterfaces.map(\.name)
            DispatchQueue.main.async { self?.update(online: online, interfaces: names) }
        }
        monitor.start(queue: DispatchQueue(label: "com.jupiterjvck.iterminal.network", qos: .utility))
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            NotificationCenter.default.post(name: Self.mayReconnect, object: nil)
        }
    }

    private func update(online: Bool, interfaces names: [String]) {
        let wasOnline = isOnline
        let changed = names != interfaces
        isOnline = online
        interfaces = names
        if online, !wasOnline || changed {
            NotificationCenter.default.post(name: Self.mayReconnect, object: nil)
        }
    }
}
