import Foundation
import AppKit

/// The forwards the app has open for its own use — a port chosen from the
/// Remote Ports list, or a screen-sharing service reached through a host.
///
/// A forward is one of two things. When a terminal tab is signed in to the host
/// and keeping its connection open (`SSHControlSocket`), the forward is added
/// to *that* connection with `ssh -O forward`, and ends with it. Otherwise it is
/// an `ssh -N` of its own, signed in with a key or the agent, which this
/// object starts and stops. Either way it listens on this Mac's loopback only,
/// on a port the system picked.
///
/// Nothing here types a password, and a forward that needs one is reported as
/// needing a sign-in in a terminal.
final class TunnelManager: ObservableObject {
    static let shared = TunnelManager()

    struct Tunnel: Identifiable, Equatable {
        let id: UUID
        let connectionID: UUID
        let connectionName: String
        let localPort: Int
        let targetHost: String
        let targetPort: Int
        /// Whether it rides a terminal tab's open connection.
        let viaSharedSignIn: Bool

        var summary: String {
            "localhost:\(localPort) → \(targetHost):\(targetPort) via \(connectionName)"
        }
    }

    @Published private(set) var tunnels: [Tunnel] = []

    /// The `ssh -N` behind each tunnel that has one. Main-thread only.
    private var processes: [UUID: Process] = [:]
    /// What it takes to cancel a tunnel that rides a shared connection.
    private var shares: [UUID: (connection: SSHConnection, socket: String)] = [:]

    private let queue = DispatchQueue(label: "com.jupiterjvck.iterminal.tunnels", qos: .userInitiated)
    private var quitObserver: NSObjectProtocol?

    private init() {
        // A child `ssh -N` is not stopped by its parent exiting.
        quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.closeAll()
        }
    }

    deinit {
        if let quitObserver { NotificationCenter.default.removeObserver(quitObserver) }
    }

    // MARK: Opening

    /// A forward from this Mac to `targetHost:targetPort` as `connection`'s host
    /// sees it. Reuses one already open for the same target. `completion`
    /// arrives on the main thread.
    func open(
        through connection: SSHConnection,
        targetHost: String,
        targetPort: Int,
        completion: @escaping (Result<Tunnel, PortToolError>) -> Void
    ) {
        if let existing = tunnels.first(where: {
            $0.connectionID == connection.id && $0.targetHost == targetHost && $0.targetPort == targetPort
        }), isAlive(existing) {
            completion(.success(existing))
            return
        }
        if let problem = connection.jumpHostsProblem {
            completion(.failure(PortToolError(JumpHosts.refusal(problem))))
            return
        }
        if let problem = TunnelPlan.problem(targetHost: targetHost, targetPort: targetPort) {
            completion(.failure(PortToolError(problem)))
            return
        }
        guard connection.transport != .custom else {
            completion(.failure(PortToolError("This host connects with a custom command, so there is no ssh to forward through.")))
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.start(connection: connection, targetHost: targetHost, targetPort: targetPort)
            DispatchQueue.main.async {
                switch result {
                case .success(let started):
                    self.tunnels.append(started.tunnel)
                    if let process = started.process {
                        self.processes[started.tunnel.id] = process
                        process.terminationHandler = { [weak self] _ in
                            DispatchQueue.main.async { self?.forget(started.tunnel.id) }
                        }
                        // It may have ended between starting and being recorded.
                        if !process.isRunning { self.forget(started.tunnel.id) }
                    }
                    if let socket = started.socket {
                        self.shares[started.tunnel.id] = (connection, socket)
                    }
                    completion(.success(started.tunnel))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    private struct Started {
        let tunnel: Tunnel
        let process: Process?
        let socket: String?
    }

    /// Runs on `queue`.
    private func start(
        connection: SSHConnection,
        targetHost: String,
        targetPort: Int
    ) -> Result<Started, PortToolError> {
        guard let ssh = SessionLaunch.resolveExecutable("ssh") else {
            return .failure(PortToolError("Couldn't find ssh on this Mac."))
        }
        guard let port = TunnelPlan.freeLocalPort() else {
            return .failure(PortToolError("Couldn't find a free port on this Mac."))
        }
        let name = connection.name.isEmpty ? connection.host : connection.name
        func tunnel(shared: Bool) -> Tunnel {
            Tunnel(
                id: UUID(),
                connectionID: connection.id,
                connectionName: name,
                localPort: port,
                targetHost: targetHost,
                targetPort: targetPort,
                viaSharedSignIn: shared
            )
        }

        // Preferred: join the connection a terminal tab holds open.
        if let socket = SSHControlSocket.liveSocket(for: connection, base: NSTemporaryDirectory()) {
            let arguments = TunnelPlan.controlArguments(
                operation: "forward",
                for: connection,
                sharedSocket: socket,
                localPort: port,
                targetHost: targetHost,
                targetPort: targetPort
            )
            if let result = ProcessRunner.run(ssh, arguments, timeout: 15), result.status == 0, !result.timedOut {
                return .success(Started(tunnel: tunnel(shared: true), process: nil, socket: socket))
            }
            // Refused by the open connection: try one of its own.
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ssh)
        process.arguments = TunnelPlan.forwardProcessArguments(
            for: connection,
            localPort: port,
            targetHost: targetHost,
            targetPort: targetPort
        )
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        let captured = LockedText()
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
            } else {
                captured.append(chunk)
            }
        }
        do {
            try process.run()
        } catch {
            errorPipe.fileHandleForReading.readabilityHandler = nil
            return .failure(PortToolError("Couldn't start ssh."))
        }

        // Ready when something answers on the local port; failed when ssh
        // exits first, which `ExitOnForwardFailure` makes it do on any trouble.
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if !process.isRunning {
                errorPipe.fileHandleForReading.readabilityHandler = nil
                let text = captured.value
                let needsSignIn = TunnelPlan.isSignInFailure(text)
                let reason = TunnelPlan.summarise(text)
                return .failure(PortToolError(
                    needsSignIn ? "\(reason)\n\(TunnelPlan.signInAdvice)" : reason,
                    needsSignIn: needsSignIn
                ))
            }
            if TunnelPlan.isAccepting(port: port) {
                errorPipe.fileHandleForReading.readabilityHandler = nil
                return .success(Started(tunnel: tunnel(shared: false), process: process, socket: nil))
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        process.terminate()
        errorPipe.fileHandleForReading.readabilityHandler = nil
        return .failure(PortToolError("\(connection.host) didn't answer in time."))
    }

    // MARK: Closing

    func close(_ id: UUID) {
        if let process = processes[id], process.isRunning {
            process.terminate()
        }
        if let share = shares[id], let tunnel = tunnels.first(where: { $0.id == id }),
           let ssh = SessionLaunch.resolveExecutable("ssh") {
            let arguments = TunnelPlan.controlArguments(
                operation: "cancel",
                for: share.connection,
                sharedSocket: share.socket,
                localPort: tunnel.localPort,
                targetHost: tunnel.targetHost,
                targetPort: tunnel.targetPort
            )
            // Best effort: the connection may be gone already, which cancels it.
            queue.async { _ = ProcessRunner.run(ssh, arguments, timeout: 10) }
        }
        forget(id)
    }

    func closeAll() {
        for id in tunnels.map(\.id) { close(id) }
    }

    private func forget(_ id: UUID) {
        processes[id] = nil
        shares[id] = nil
        tunnels.removeAll { $0.id == id }
    }

    private func isAlive(_ tunnel: Tunnel) -> Bool {
        if let process = processes[tunnel.id] { return process.isRunning }
        if let share = shares[tunnel.id] { return SSHControlSocket.isLive(share.socket) }
        return false
    }
}

/// Text collected from a pipe on another queue.
final class LockedText {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        if data.count < 64 * 1024 { data.append(chunk) }
        lock.unlock()
    }

    var value: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
