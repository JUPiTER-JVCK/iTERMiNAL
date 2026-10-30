import Foundation

/// Runs the tunnels saved in Settings → Connections, each as an `ssh -N` of its
/// own, in the background: started and stopped from Settings, or at launch for
/// the ones marked so.
///
/// They sign in as every non-interactive run here does — a key or the agent,
/// `BatchMode=yes`, never a typed password — so a host that wants one is
/// reported as failed with the reason, and a key (Settings → Connections →
/// Set Up Key Login) is the way forward. A tunnel lives as long as the app: it
/// is stopped when the app quits, and nothing is left running behind it.
final class SavedTunnelRunner: ObservableObject {
    static let shared = SavedTunnelRunner()

    enum State: Equatable {
        case stopped
        case starting
        case running
        case failed(String)

        var label: String {
            switch self {
            case .stopped: return "Stopped"
            case .starting: return "Starting…"
            case .running: return "Running"
            case .failed(let reason): return reason
            }
        }

        var isActive: Bool { self == .starting || self == .running }
    }

    @Published private(set) var states: [UUID: State] = [:]

    /// Main-thread only.
    private var processes: [UUID: Process] = [:]
    /// Tunnels stopped on purpose, so their ending is not reported as a failure.
    private var stopping: Set<UUID> = []

    private let queue = DispatchQueue(label: "com.jupiterjvck.iterminal.savedtunnels", qos: .utility)

    private init() {}

    func state(of id: UUID) -> State { states[id] ?? .stopped }

    // MARK: Starting

    func startAutomatic(settings: AppSettings) {
        for tunnel in settings.savedTunnels where tunnel.autoStart {
            start(tunnel, settings: settings)
        }
    }

    func start(_ tunnel: SavedTunnel, settings: AppSettings) {
        guard !state(of: tunnel.id).isActive else { return }

        guard let hostID = tunnel.connectionID,
              let connection = settings.sshConnections.first(where: { $0.id == hostID }) else {
            states[tunnel.id] = .failed("Choose a host for this tunnel.")
            return
        }
        if let problem = connection.jumpHostsProblem {
            states[tunnel.id] = .failed(JumpHosts.refusal(problem))
            return
        }
        guard connection.transport != .custom else {
            states[tunnel.id] = .failed("This host connects with a custom command, so there is no ssh to tunnel through.")
            return
        }
        if let problem = tunnel.forward.problem {
            states[tunnel.id] = .failed(problem)
            return
        }
        guard let arguments = TunnelPlan.savedArguments(for: connection, forward: tunnel.forward) else {
            states[tunnel.id] = .failed("This forward can't be used.")
            return
        }
        guard let ssh = SessionLaunch.resolveExecutable("ssh") else {
            states[tunnel.id] = .failed("Couldn't find ssh on this Mac.")
            return
        }
        // Something already answering on the port would look like this tunnel
        // coming up, when ssh was about to fail to bind it.
        let listening = TunnelPlan.localListeningPort(of: tunnel.forward)
        if let listening, TunnelPlan.isAccepting(port: listening) {
            states[tunnel.id] = .failed("Port \(listening) on this Mac is already in use.")
            return
        }

        states[tunnel.id] = .starting
        stopping.remove(tunnel.id)
        let id = tunnel.id
        let host = connection.host
        queue.async { [weak self] in
            let outcome = Self.launch(ssh: ssh, arguments: arguments, listening: listening, host: host)
            DispatchQueue.main.async {
                guard let self else { return }
                // Stopped while it was starting.
                if self.stopping.contains(id) {
                    if case .success(let process) = outcome, process.isRunning { process.terminate() }
                    self.stopping.remove(id)
                    self.states[id] = .stopped
                    return
                }
                switch outcome {
                case .failure(let error):
                    self.states[id] = .failed(error.message)
                case .success(let process):
                    self.processes[id] = process
                    self.states[id] = .running
                    process.terminationHandler = { [weak self] _ in
                        DispatchQueue.main.async { self?.ended(id) }
                    }
                    // It may have ended between starting and being recorded.
                    if !process.isRunning { self.ended(id) }
                }
            }
        }
    }

    /// Runs on `queue`. Ready when the local port answers (for a forward that
    /// listens here), or once ssh has stayed up past its sign-in (for one that
    /// listens on the host, which has nothing to connect to here); failed when
    /// ssh exits first, which `ExitOnForwardFailure` makes it do on any trouble.
    private static func launch(
        ssh: String,
        arguments: [String],
        listening: Int?,
        host: String
    ) -> Result<Process, PortToolError> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ssh)
        process.arguments = arguments
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

        let started = Date()
        let deadline = started.addingTimeInterval(20)
        while Date() < deadline {
            if !process.isRunning {
                errorPipe.fileHandleForReading.readabilityHandler = nil
                let text = captured.value
                let needsSignIn = TunnelPlan.isSignInFailure(text)
                let reason = TunnelPlan.summarise(text)
                return .failure(PortToolError(
                    needsSignIn ? "\(reason) A background tunnel can't type a password: set up key login for this host." : reason,
                    needsSignIn: needsSignIn
                ))
            }
            if let listening {
                if TunnelPlan.isAccepting(port: listening) {
                    errorPipe.fileHandleForReading.readabilityHandler = nil
                    return .success(process)
                }
            } else if Date().timeIntervalSince(started) >= 6 {
                errorPipe.fileHandleForReading.readabilityHandler = nil
                return .success(process)
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        process.terminate()
        errorPipe.fileHandleForReading.readabilityHandler = nil
        return .failure(PortToolError("\(host) didn't answer in time."))
    }

    /// A running tunnel's ssh ended. Reported as a failure unless it was stopped
    /// on purpose.
    private func ended(_ id: UUID) {
        processes[id] = nil
        if stopping.remove(id) != nil {
            states[id] = .stopped
        } else if state(of: id) == .running {
            states[id] = .failed("The connection ended. Start it again to reopen it.")
        }
    }

    // MARK: Stopping

    func stop(_ id: UUID) {
        switch state(of: id) {
        case .starting:
            stopping.insert(id)
        case .running:
            stopping.insert(id)
            if let process = processes[id], process.isRunning {
                process.terminate()
            } else {
                ended(id)
            }
        case .stopped, .failed:
            states[id] = .stopped
        }
    }

    func stopAll() {
        for (id, process) in processes where process.isRunning {
            stopping.insert(id)
            process.terminate()
        }
    }
}
