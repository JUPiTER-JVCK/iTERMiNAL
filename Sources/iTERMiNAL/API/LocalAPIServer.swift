import Foundation
import Darwin
import Security

/// Unix-domain-socket server exposing the app's scripting API.
///
/// Security posture: the socket lives in the app's Application Support
/// directory (mode 0700) as a 0600 socket, so only this user's processes can
/// connect at all; every request must additionally carry the token stored in
/// the keychain. The API can type into live shells, so it stays off until the
/// user enables it in Settings → Security. Turning it off, or replacing the
/// token, ends every connection that is open.
final class LocalAPIServer {
    static let shared = LocalAPIServer()

    static let tokenAccount = "local-api-token"

    /// The longest any one command may be asked to take: `host.exec`'s own
    /// limit, which `browser.wait` is held to as well.
    static let longestCommand: TimeInterval = ScriptedCommand.maxTimeout

    /// How long a request waits for its reply. Longer than `longestCommand`, so
    /// a command that runs to its own limit reports that itself — for
    /// `host.exec`, exit 124 and what it printed — instead of being cut off here
    /// a moment before. It was 120 seconds, `host.exec`'s limit exactly, and
    /// this clock starts first, so a command given all of it never reported.
    static let replyTimeout: TimeInterval = longestCommand + 30

    private let acceptQueue = DispatchQueue(label: "com.jupiterjvck.iterminal.api.accept", qos: .utility)
    private let stateQueue = DispatchQueue(label: "com.jupiterjvck.iterminal.api.state")

    private var listenFD: Int32 = -1
    private var running = false

    /// The connections open now, by descriptor, so turning the API off or
    /// replacing its token can end them. A client that had subscribed to events
    /// otherwise stayed connected — and went on receiving them — for as long as
    /// it liked: nothing after `subscribe` asks for the token again.
    private let clientsLock = NSLock()
    private var clients: Set<Int32> = []

    /// How many connections may be open at once, subscriptions included. Each
    /// holds a worker thread from the shared global queues for as long as it
    /// is open, and up to a request line's worth of buffer
    /// (`RequestLineBuffer.defaultLimit`), so without this the line cap bounded
    /// one connection but not how many a process could open. Kept low because
    /// the rest of the app runs its own work on those queues. Only this user's
    /// processes can connect, so this is robustness, not access control.
    static let maxConnections = 32

    private init() {}

    // MARK: Paths

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("iTERMiNAL", isDirectory: true)
    }

    var socketPath: String {
        Self.supportDirectory.appendingPathComponent("api.sock").path
    }

    /// A 0600 mirror of the keychain token so the CLI can authenticate
    /// without triggering a keychain prompt on every invocation.
    var tokenPath: String {
        Self.supportDirectory.appendingPathComponent("api.token").path
    }

    var isRunning: Bool {
        stateQueue.sync { running }
    }

    // MARK: Token

    /// Returns the API token, minting one if needed. Nil means no token could
    /// be produced — the caller must not fall back to anything weaker.
    @discardableResult
    func ensureToken() -> String? {
        if let existing = KeychainStore.get(Self.tokenAccount), !existing.isEmpty {
            writeTokenMirror(existing)
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            // A failed RNG would leave the buffer as zeros; a predictable
            // token is worse than no API, so refuse rather than degrade.
            NSLog("Local API: secure random generation failed (status \(status))")
            return nil
        }
        let token = Data(bytes).base64EncodedString()
        guard KeychainStore.set(token, for: Self.tokenAccount) else {
            NSLog("Local API: could not store the token in the keychain")
            return nil
        }
        writeTokenMirror(token)
        return token
    }

    func regenerateToken() -> String? {
        KeychainStore.delete(Self.tokenAccount)
        let token = ensureToken()
        // What connected with the old token goes with it. A request on an open
        // connection is checked against the new one anyway; a subscription,
        // made once, is not.
        disconnectClients()
        return token
    }

    private func writeTokenMirror(_ token: String) {
        ensureSupportDirectory()
        let url = URL(fileURLWithPath: tokenPath)
        try? Data(token.utf8).write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenPath)
    }

    private func ensureSupportDirectory() {
        let directory = Self.supportDirectory
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    // MARK: Lifecycle

    func applyEnabledState(_ enabled: Bool) {
        if enabled {
            start()
        } else {
            stop()
        }
    }

    func start() {
        stateQueue.sync {
            guard !running else { return }
            ensureSupportDirectory()
            guard ensureToken() != nil else {
                NSLog("Local API: no authentication token available; not listening")
                return
            }

            unlink(socketPath)

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                NSLog("Local API: socket() failed (errno \(errno))")
                return
            }

            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(socketPath.utf8)
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            guard pathBytes.count < capacity else {
                NSLog("Local API: socket path too long for sockaddr_un")
                Darwin.close(fd)
                return
            }
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pointer.withMemoryRebound(to: UInt8.self, capacity: capacity) { destination in
                    for (index, byte) in pathBytes.enumerated() {
                        destination[index] = byte
                    }
                    destination[pathBytes.count] = 0
                }
            }

            let size = socklen_t(MemoryLayout<sockaddr_un>.size)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.bind(fd, sockaddrPointer, size)
                }
            }
            guard bound == 0 else {
                NSLog("Local API: bind() failed (errno \(errno))")
                Darwin.close(fd)
                return
            }

            chmod(socketPath, 0o600)

            guard Darwin.listen(fd, 8) == 0 else {
                NSLog("Local API: listen() failed (errno \(errno))")
                Darwin.close(fd)
                unlink(socketPath)
                return
            }

            listenFD = fd
            running = true
            NSLog("Local API listening at \(socketPath)")
            acceptLoop(fd: fd)
        }
    }

    func stop() {
        stateQueue.sync {
            guard running else { return }
            running = false
            if listenFD >= 0 {
                Darwin.close(listenFD)
                listenFD = -1
            }
            unlink(socketPath)
        }
        // Off is off for whoever is already connected, too.
        disconnectClients()
    }

    private func acceptLoop(fd: Int32) {
        acceptQueue.async { [weak self] in
            while true {
                let client = Darwin.accept(fd, nil, nil)
                guard let self, self.isRunning else {
                    if client >= 0 { Darwin.close(client) }
                    break
                }
                if client < 0 {
                    // The listener was closed (shutdown) or interrupted.
                    if errno == EINTR { continue }
                    break
                }
                // A client that is gone by the time a reply or an event is
                // written to it must not take the app with it. Writing to it
                // raises SIGPIPE, which by default ends the process; with this
                // the write fails instead, whatever else in the process does
                // about the signal.
                var noSignal: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                guard self.track(client) else {
                    // One short line to a socket nothing has written to yet,
                    // so this does not wait on the client.
                    let message = "Too many connections to iTERMiNAL are open (\(LocalAPIServer.maxConnections)). Close one and try again."
                    self.write(fd: client, data: APIResponse.failure(id: nil, message: message).jsonLine())
                    Darwin.close(client)
                    continue
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    self.serve(client: client)
                }
            }
        }
    }

    // MARK: Connection handling

    private func serve(client fd: Int32) {
        // Each connection gets an id (for event subscriptions) and a serial
        // write queue, so pushed events can never interleave with replies.
        let connectionID = UUID()
        let writeQueue = DispatchQueue(
            label: "com.jupiterjvck.iterminal.api.write.\(connectionID.uuidString)"
        )
        var alive = true

        let send: (Data) -> Void = { [weak self] data in
            guard let self else { return }
            writeQueue.async {
                guard alive else { return }
                if !self.write(fd: fd, data: data) { alive = false }
            }
        }

        defer {
            EventBus.shared.unsubscribe(id: connectionID)
            // Drains anything already queued before the descriptor closes.
            writeQueue.sync { alive = false }
            // Out of the list before it closes, so `disconnectClients` never
            // shuts down a number the system has since handed to something else.
            untrack(fd)
            Darwin.close(fd)
        }

        // This runs before any token is checked, so lines are capped
        // (`RequestLineBuffer.defaultLimit`): what is buffered for one
        // connection never passes the cap plus one read.
        var lines = RequestLineBuffer()
        var chunk = [UInt8](repeating: 0, count: 4096)

        while isRunning {
            // Consume any complete lines already buffered.
            while let next = lines.next() {
                switch next {
                case .line(let lineData):
                    if lineData.isEmpty { continue }
                    send(process(lineData, connectionID: connectionID, send: send))
                case .tooLong:
                    // Said once, then the connection ends: what follows is the
                    // rest of a line that will not be read. The reply is queued
                    // ahead of the close in `defer`, which drains the queue.
                    send(APIResponse.failure(id: nil, message: lines.refusal).jsonLine())
                    return
                }
            }

            let count = chunk.withUnsafeMutableBytes { pointer -> Int in
                guard let base = pointer.baseAddress else { return -1 }
                return Darwin.read(fd, base, pointer.count)
            }
            if count <= 0 { return }
            lines.append(chunk[0..<count])
        }
    }

    /// Decodes one request line, runs it on the main queue, and encodes the
    /// reply. Blocking this connection's own queue while the main queue works
    /// is safe — the main queue never waits on API connections.
    private func process(
        _ line: Data,
        connectionID: UUID,
        send: @escaping (Data) -> Void
    ) -> Data {
        let request: APIRequest
        do {
            request = try APIRequest(jsonLine: line)
        } catch {
            return APIResponse.failure(id: nil, message: error.localizedDescription).jsonLine()
        }

        guard let expected = KeychainStore.get(Self.tokenAccount), !expected.isEmpty else {
            return APIResponse.failure(id: request.id, message: "API token unavailable.").jsonLine()
        }
        guard let provided = request.token, constantTimeEquals(provided, expected) else {
            return APIResponse.failure(id: request.id, message: "Unauthorized: missing or invalid token.").jsonLine()
        }

        // Subscriptions are owned by the connection, so they're handled here
        // rather than in the router.
        switch request.command {
        case "subscribe":
            let requested = (request.params["events"] as? [String])?.filter { !$0.isEmpty } ?? []
            var names = Set(requested)
            if names.isEmpty { names = ["*"] }
            EventBus.shared.subscribe(id: connectionID, to: names) { event in
                if let data = try? JSONSerialization.data(withJSONObject: event.payload) {
                    send(data)
                }
            }
            return APIResponse.success(id: request.id, [
                "subscribed": names.sorted(),
                "available": EventBus.allEvents,
            ]).jsonLine()

        case "unsubscribe":
            EventBus.shared.unsubscribe(id: connectionID)
            return APIResponse.success(id: request.id).jsonLine()

        default:
            break
        }

        let semaphore = DispatchSemaphore(value: 0)
        var reply = APIResponse.failure(id: request.id, message: "No response produced.")
        DispatchQueue.main.async {
            APIRouter.shared.handle(request) { response in
                reply = response
                semaphore.signal()
            }
        }
        if semaphore.wait(timeout: .now() + Self.replyTimeout) == .timedOut {
            return APIResponse.failure(id: request.id, message: "Command timed out.").jsonLine()
        }
        return reply.jsonLine()
    }

    // MARK: Open connections

    /// Adds a connection to the list, unless `maxConnections` are open already.
    private func track(_ fd: Int32) -> Bool {
        clientsLock.lock()
        defer { clientsLock.unlock() }
        guard clients.count < Self.maxConnections else { return false }
        clients.insert(fd)
        return true
    }

    private func untrack(_ fd: Int32) {
        clientsLock.lock()
        clients.remove(fd)
        clientsLock.unlock()
    }

    /// Ends every open connection. `shutdown`, not `close`: the thread serving
    /// each one is waiting in `read`, which then returns, and that thread closes
    /// its own descriptor — so none is closed twice, or while it is in use.
    private func disconnectClients() {
        clientsLock.lock()
        defer { clientsLock.unlock() }
        for fd in clients {
            Darwin.shutdown(fd, SHUT_RDWR)
        }
    }

    private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<left.count {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    @discardableResult
    private func write(fd: Int32, data: Data) -> Bool {
        var payload = data
        payload.append(0x0A)
        return payload.withUnsafeBytes { pointer -> Bool in
            guard var base = pointer.baseAddress else { return false }
            var remaining = pointer.count
            while remaining > 0 {
                let written = Darwin.write(fd, base, remaining)
                if written <= 0 { return false }
                remaining -= written
                base = base.advanced(by: written)
            }
            return true
        }
    }
}
