import Foundation
import Darwin
import Security

/// Unix-domain-socket server exposing the app's scripting API.
///
/// Security posture: the socket lives in the app's Application Support
/// directory (mode 0700) as a 0600 socket, so only this user's processes can
/// connect at all; every request must additionally carry the token stored in
/// the keychain. The API can type into live shells, so it stays off until the
/// user enables it in Settings → Security.
final class LocalAPIServer {
    static let shared = LocalAPIServer()

    static let tokenAccount = "local-api-token"

    private let acceptQueue = DispatchQueue(label: "com.jupiterjvck.iterminal.api.accept", qos: .utility)
    private let stateQueue = DispatchQueue(label: "com.jupiterjvck.iterminal.api.state")

    private var listenFD: Int32 = -1
    private var running = false

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

    @discardableResult
    func ensureToken() -> String {
        if let existing = KeychainStore.get(Self.tokenAccount), !existing.isEmpty {
            writeTokenMirror(existing)
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = Data(bytes).base64EncodedString()
        KeychainStore.set(token, for: Self.tokenAccount)
        writeTokenMirror(token)
        return token
    }

    func regenerateToken() -> String {
        KeychainStore.delete(Self.tokenAccount)
        return ensureToken()
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
            _ = ensureToken()

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
                DispatchQueue.global(qos: .userInitiated).async {
                    self.serve(client: client)
                }
            }
        }
    }

    // MARK: Connection handling

    private func serve(client fd: Int32) {
        defer { Darwin.close(fd) }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)

        while isRunning {
            // Consume any complete lines already buffered.
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                if lineData.isEmpty { continue }
                let response = process(lineData)
                if !write(fd: fd, data: response) { return }
            }

            let count = chunk.withUnsafeMutableBytes { pointer -> Int in
                guard let base = pointer.baseAddress else { return -1 }
                return Darwin.read(fd, base, pointer.count)
            }
            if count <= 0 { return }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    /// Decodes one request line, runs it on the main queue, and encodes the
    /// reply. Blocking this connection's own queue while the main queue works
    /// is safe — the main queue never waits on API connections.
    private func process(_ line: Data) -> Data {
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

        let semaphore = DispatchSemaphore(value: 0)
        var reply = APIResponse.failure(id: request.id, message: "No response produced.")
        DispatchQueue.main.async {
            APIRouter.shared.handle(request) { response in
                reply = response
                semaphore.signal()
            }
        }
        if semaphore.wait(timeout: .now() + 120) == .timedOut {
            return APIResponse.failure(id: request.id, message: "Command timed out.").jsonLine()
        }
        return reply.jsonLine()
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
