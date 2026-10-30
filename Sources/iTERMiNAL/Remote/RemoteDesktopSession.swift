import Foundation

extension Notification.Name {
    /// Asks the main window to open a remote-desktop window; `userInfo["id"]`
    /// is the session's UUID.
    static let openRemoteDesktop = Notification.Name("iTERMiNAL.OpenRemoteDesktop")
}

/// One remote desktop in a window of its own: where it is, what state the
/// connection is in, and the client behind it.
final class RemoteDesktopSession: ObservableObject, Identifiable {
    enum State: Equatable {
        case connecting
        case needsPassword
        case connected
        case failed(String)
        case closed
    }

    let id = UUID()
    let title: String
    let host: String
    let port: Int
    /// Carried through an SSH forward, so what crosses the network is encrypted.
    let isTunneled: Bool

    @Published private(set) var state: State = .connecting
    @Published private(set) var desktopName = ""
    /// Changes whenever the screen does, so a view that shows it redraws.
    @Published private(set) var frame = 0
    @Published private(set) var screenSize = (width: 0, height: 0)

    private(set) var client = RFBClient()

    var framebuffer: RFBFramebuffer? { client.framebuffer }

    init(title: String, host: String, port: Int, isTunneled: Bool) {
        self.title = title
        self.host = host
        self.port = port
        self.isTunneled = isTunneled
        wire()
    }

    private func wire() {
        client.onNeedsPassword = { [weak self] in self?.state = .needsPassword }
        client.onConnected = { [weak self] name, width, height in
            guard let self else { return }
            self.desktopName = name
            self.screenSize = (width, height)
            self.state = .connected
        }
        client.onFrame = { [weak self] in
            guard let self else { return }
            if let size = self.client.framebuffer?.size, size.width != self.screenSize.width || size.height != self.screenSize.height {
                self.screenSize = (size.width, size.height)
            }
            self.frame &+= 1
        }
        client.onFailure = { [weak self] message in self?.state = .failed(message) }
        client.onClosed = { [weak self] in
            guard let self else { return }
            // A failure keeps its message; only a plain close says "closed".
            if case .failed = self.state { return }
            self.state = .closed
        }
    }

    func start() {
        client.connect(host: host, port: port)
    }

    /// Answers the server's password challenge. Used once and not kept.
    func submit(password: String) {
        state = .connecting
        client.submit(password: password)
    }

    /// Connects again, from the start, with a fresh client.
    func retry() {
        client.disconnect()
        client = RFBClient()
        state = .connecting
        desktopName = ""
        wire()
        start()
    }

    func close() {
        client.disconnect()
        if state != .closed { state = .closed }
    }
}

/// The open remote-desktop sessions, so a window can find its session by id.
final class RemoteDesktopRegistry: ObservableObject {
    static let shared = RemoteDesktopRegistry()
    private var sessions: [UUID: RemoteDesktopSession] = [:]

    private init() {}

    func add(_ session: RemoteDesktopSession) {
        sessions[session.id] = session
    }

    func session(withID id: UUID) -> RemoteDesktopSession? {
        sessions[id]
    }

    func remove(_ id: UUID) {
        sessions[id]?.close()
        sessions[id] = nil
    }
}
