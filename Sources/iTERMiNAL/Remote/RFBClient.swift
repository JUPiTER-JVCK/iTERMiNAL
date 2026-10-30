import Foundation
import Network

/// A VNC connection: the handshake, the sign-in, and the stream of screen
/// updates, read into an `RFBFramebuffer`. What it speaks is plain RFB 3.3 to
/// 3.8 with no authentication or a VNC password, raw and copy-rectangle
/// encodings, and a desktop that can change size. That is the plain end of the
/// protocol, and it is deliberate: every encoding is code that reads bytes from
/// a server, and each of these is a few lines whose bounds can be seen.
///
/// The connection is not encrypted, and VNC's password check is DES with a
/// challenge anyone watching can read. The window says so, and a service can be
/// set to go through an SSH host instead (`RemoteService.tunnelThrough`), which
/// is the answer for anything past a trusted network.
///
/// The password is used once, to answer the server's challenge, and is not kept.
/// Everything here runs on one serial queue; the callbacks arrive on the main
/// thread.
final class RFBClient {
    var onNeedsPassword: (() -> Void)?
    /// The desktop's name and size, once the connection is up.
    var onConnected: ((String, Int, Int) -> Void)?
    /// The screen changed, or changed size.
    var onFrame: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onClosed: (() -> Void)?

    /// Written once, when the server says how big the screen is.
    private(set) var framebuffer: RFBFramebuffer?

    private let queue = DispatchQueue(label: "com.jupiterjvck.iterminal.rfb", qos: .userInteractive)
    private var connection: NWConnection?
    /// What has arrived and not been read yet starts at `readOffset`; the front
    /// is dropped in pieces, not byte by byte, so reading a large update is not
    /// quadratic.
    private var buffer = Data()
    private var readOffset = 0
    private var pumping = false
    private var wanted = 0
    private var handler: (([UInt8]) -> Void)?
    private var version = RFB.Version(major: 3, minor: 8)
    private var challenge: [UInt8] = []
    private var finished = false
    private var frameScheduled = false

    // MARK: Starting and stopping

    func connect(host: String, port: Int) {
        queue.async { [weak self] in
            guard let self, self.connection == nil else { return }
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)), port > 0, port <= 65535 else {
                self.fail("\(port) isn't a port.")
                return
            }
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.receiveMore()
                    self.readVersion()
                case .failed(let error):
                    self.fail("Couldn't connect to \(host): \(error.localizedDescription)")
                case .waiting(let error):
                    // Refused, or no route: it would keep trying, which a person
                    // watching a window is not helped by.
                    self.fail("Couldn't connect to \(host): \(error.localizedDescription)")
                case .cancelled:
                    self.closed()
                default:
                    break
                }
            }
            connection.start(queue: self.queue)
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.finished = true
            self.connection?.cancel()
            self.connection = nil
        }
    }

    // MARK: Reading

    private func receiveMore() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.pump()
            }
            if let error {
                self.fail("The connection dropped: \(error.localizedDescription)")
            } else if isComplete {
                self.fail("The server closed the connection.")
            } else {
                self.receiveMore()
            }
        }
    }

    /// Calls `then` with the next `count` bytes, when they have arrived.
    private func read(_ count: Int, _ then: @escaping ([UInt8]) -> Void) {
        wanted = count
        handler = then
        pump()
    }

    /// Hands each waiting reader its bytes. Not re-entrant on purpose: a reader
    /// that asks for the next piece from inside its own callback only sets it up
    /// and returns, and this loop carries on. Called recursively instead, a
    /// server that sent thousands of small rectangles in one update would nest
    /// one call per rectangle, on a thread with a small stack.
    private func pump() {
        guard !pumping else { return }
        pumping = true
        defer { pumping = false }
        while let current = handler, buffer.count - readOffset >= wanted, !finished {
            let chunk = Array(buffer.subdata(in: readOffset..<(readOffset + wanted)))
            readOffset += wanted
            if readOffset == buffer.count || readOffset > (1 << 20) {
                buffer.removeSubrange(0..<readOffset)
                readOffset = 0
            }
            handler = nil
            current(chunk)
        }
    }

    /// Reads and drops `count` bytes, a piece at a time.
    private func skip(_ count: Int, then: @escaping () -> Void) {
        guard count > 0 else {
            then()
            return
        }
        let piece = min(count, 1 << 16)
        read(piece) { [weak self] _ in
            self?.skip(count - piece, then: then)
        }
    }

    private func send(_ bytes: [UInt8]) {
        connection?.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            if let error { self?.fail("The connection dropped: \(error.localizedDescription)") }
        })
    }

    // MARK: Handshake

    private func readVersion() {
        read(12) { [weak self] bytes in
            guard let self else { return }
            guard let server = RFB.parseVersion(bytes) else {
                self.fail("That isn't a VNC server: it didn't start with RFB.")
                return
            }
            guard let mine = RFB.clientVersion(for: server) else {
                self.fail("This server speaks RFB \(server.major).\(server.minor), which this viewer doesn't.")
                return
            }
            self.version = mine
            self.send(RFB.versionBytes(mine))
            if mine.minor == 3 {
                self.readLegacySecurity()
            } else {
                self.readSecurityTypes()
            }
        }
    }

    /// RFB 3.3: the server picks, as one 32-bit number.
    private func readLegacySecurity() {
        read(4) { [weak self] bytes in
            guard let self else { return }
            switch RFB.u32(bytes, 0) {
            case 0: self.readFailureReason()
            case 1: self.sendClientInit()
            case 2: self.readChallenge()
            default: self.fail(RFB.unsupportedSecurityMessage([UInt8(truncatingIfNeeded: RFB.u32(bytes, 0))]))
            }
        }
    }

    private func readSecurityTypes() {
        read(1) { [weak self] count in
            guard let self else { return }
            guard count[0] > 0 else {
                self.readFailureReason()
                return
            }
            self.read(Int(count[0])) { [weak self] offered in
                guard let self else { return }
                guard let chosen = RFB.chooseSecurity(from: offered) else {
                    self.fail(RFB.unsupportedSecurityMessage(offered))
                    return
                }
                self.send([chosen])
                if chosen == RFB.securityNone {
                    // 3.7 has no result for "none"; 3.8 does.
                    if self.version.minor >= 8 { self.readSecurityResult() } else { self.sendClientInit() }
                } else {
                    self.readChallenge()
                }
            }
        }
    }

    private func readFailureReason() {
        read(4) { [weak self] length in
            guard let self else { return }
            let size = Int(RFB.u32(length, 0))
            guard size <= RFB.maxNameLength else {
                self.fail("The server refused the connection.")
                return
            }
            self.read(size) { [weak self] reason in
                let text = String(decoding: reason, as: UTF8.self).filter { !$0.isNewline || $0 == " " }
                self?.fail(text.isEmpty ? "The server refused the connection." : "The server refused the connection: \(text)")
            }
        }
    }

    private func readChallenge() {
        read(16) { [weak self] bytes in
            guard let self else { return }
            self.challenge = bytes
            DispatchQueue.main.async { self.onNeedsPassword?() }
        }
    }

    /// Answers the server's challenge. The password is used here and not kept.
    func submit(password: String) {
        queue.async { [weak self] in
            guard let self, !self.finished, self.challenge.count == 16 else { return }
            guard let answer = RFBAuth.response(challenge: self.challenge, password: password) else {
                self.fail("The password couldn't be used.")
                return
            }
            self.challenge = []
            self.send(answer)
            self.readSecurityResult()
        }
    }

    private func readSecurityResult() {
        read(4) { [weak self] bytes in
            guard let self else { return }
            if RFB.u32(bytes, 0) == 0 {
                self.sendClientInit()
            } else if self.version.minor >= 8 {
                self.readFailureReason()
            } else {
                self.fail("The password wasn't accepted.")
            }
        }
    }

    private func sendClientInit() {
        // Shared: do not disconnect whoever else is looking at the screen.
        send([1])
        read(24) { [weak self] header in
            guard let self else { return }
            guard let info = RFB.parseServerInit(header) else {
                self.fail("The server gave a screen size this viewer won't use.")
                return
            }
            self.read(info.nameLength) { [weak self] nameBytes in
                guard let self else { return }
                let name = String(decoding: nameBytes, as: UTF8.self)
                    .unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }
                    .map(String.init).joined()
                guard let framebuffer = RFBFramebuffer(width: info.width, height: info.height) else {
                    self.fail("There isn't memory for a screen that size.")
                    return
                }
                self.framebuffer = framebuffer
                self.send(RFB.setPixelFormat())
                self.send(RFB.setEncodings([RFB.encodingCopyRect, RFB.encodingRaw, RFB.encodingDesktopSize]))
                self.requestUpdate(incremental: false)
                DispatchQueue.main.async { self.onConnected?(name, info.width, info.height) }
                self.readMessage()
            }
        }
    }

    // MARK: Updates

    private func requestUpdate(incremental: Bool) {
        guard let size = framebuffer?.size else { return }
        send(RFB.framebufferUpdateRequest(incremental: incremental, x: 0, y: 0, width: size.width, height: size.height))
    }

    private func readMessage() {
        read(1) { [weak self] type in
            guard let self else { return }
            switch type[0] {
            case 0:
                self.read(3) { [weak self] header in
                    self?.readRect(remaining: RFB.u16(header, 1))
                }
            case 2:
                self.readMessage()
            case 3:
                self.read(7) { [weak self] header in
                    guard let self else { return }
                    let length = Int(RFB.u32(header, 3))
                    guard length <= RFB.maxCutTextLength else {
                        self.fail("The server sent more clipboard text than this viewer will read.")
                        return
                    }
                    self.skip(length) { [weak self] in self?.readMessage() }
                }
            default:
                self.fail("The server sent something this viewer doesn't understand (message \(type[0])).")
            }
        }
    }

    private func readRect(remaining: Int) {
        guard remaining > 0 else {
            scheduleFrame()
            requestUpdate(incremental: true)
            readMessage()
            return
        }
        read(12) { [weak self] bytes in
            guard let self, let framebuffer = self.framebuffer, let rect = RFB.parseRect(bytes) else {
                self?.fail("The server sent a damaged update.")
                return
            }
            let next = { [weak self] in self?.readRect(remaining: remaining - 1) }
            switch rect.encoding {
            case RFB.encodingRaw:
                let size = framebuffer.size
                guard RFB.rectFits(rect, width: size.width, height: size.height) else {
                    self.fail("The server drew outside the screen.")
                    return
                }
                guard rect.width > 0, rect.height > 0 else {
                    next()
                    return
                }
                self.read(rect.width * rect.height * 4) { rows in
                    framebuffer.writeRaw(x: rect.x, y: rect.y, width: rect.width, height: rect.height, rows: rows)
                    next()
                }
            case RFB.encodingCopyRect:
                self.read(4) { [weak self] source in
                    guard let self else { return }
                    let size = framebuffer.size
                    let origin = RFB.Rect(x: RFB.u16(source, 0), y: RFB.u16(source, 2), width: rect.width, height: rect.height, encoding: 0)
                    guard RFB.rectFits(rect, width: size.width, height: size.height),
                          RFB.rectFits(origin, width: size.width, height: size.height) else {
                        self.fail("The server copied outside the screen.")
                        return
                    }
                    framebuffer.copy(fromX: origin.x, fromY: origin.y, toX: rect.x, toY: rect.y, width: rect.width, height: rect.height)
                    next()
                }
            case RFB.encodingDesktopSize:
                guard framebuffer.resize(width: rect.width, height: rect.height) else {
                    self.fail("The server changed the screen to a size this viewer won't use.")
                    return
                }
                // The server draws the whole screen again after a resize.
                next()
            default:
                self.fail("The server used an encoding this viewer doesn't have (\(rect.encoding)).")
            }
        }
    }

    /// One redraw a frame at most, however many rectangles arrived.
    private func scheduleFrame() {
        guard !frameScheduled else { return }
        frameScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.queue.async { self.frameScheduled = false }
            self.onFrame?()
        }
    }

    // MARK: Input

    func sendKey(down: Bool, keysym: UInt32) {
        queue.async { [weak self] in
            guard let self, self.framebuffer != nil, !self.finished else { return }
            self.send(RFB.keyEvent(down: down, keysym: keysym))
        }
    }

    func sendPointer(buttons: UInt8, x: Int, y: Int) {
        queue.async { [weak self] in
            guard let self, self.framebuffer != nil, !self.finished else { return }
            self.send(RFB.pointerEvent(buttons: buttons, x: max(0, min(x, 65535)), y: max(0, min(y, 65535))))
        }
    }

    // MARK: Ending

    private func fail(_ message: String) {
        guard !finished else { return }
        finished = true
        connection?.cancel()
        connection = nil
        DispatchQueue.main.async { [weak self] in self?.onFailure?(message) }
    }

    private func closed() {
        DispatchQueue.main.async { [weak self] in self?.onClosed?() }
    }
}
