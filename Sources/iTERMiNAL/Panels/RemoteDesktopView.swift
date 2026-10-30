import SwiftUI
import AppKit

/// The window a remote desktop opens in.
struct RemoteDesktopWindow: View {
    let sessionID: UUID?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let sessionID, let session = RemoteDesktopRegistry.shared.session(withID: sessionID) {
            RemoteDesktopContent(session: session)
                .onDisappear { RemoteDesktopRegistry.shared.remove(sessionID) }
        } else {
            // A window restored from a last launch: its connection did not
            // survive the quit.
            VStack(spacing: 10) {
                Text("This remote desktop session has ended.")
                Button("Close") { dismiss() }
            }
            .frame(minWidth: 320, minHeight: 140)
            .padding()
        }
    }
}

private struct RemoteDesktopContent: View {
    @ObservedObject var session: RemoteDesktopSession
    @State private var password = ""
    @FocusState private var passwordFocused: Bool

    var body: some View {
        ZStack {
            Color.black
            switch session.state {
            case .connected:
                RemoteDesktopSurface(session: session)
            case .needsPassword:
                passwordForm
            case .connecting:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Connecting to \(session.host)…")
                        .foregroundStyle(.white.opacity(0.8))
                }
            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.orange)
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .frame(maxWidth: 420)
                        .textSelection(.enabled)
                    Button("Try Again") { session.retry() }
                }
                .padding()
            case .closed:
                Text("The connection is closed.")
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .frame(minWidth: 480, minHeight: 320)
        .navigationTitle(title)
    }

    private var title: String {
        session.desktopName.isEmpty ? session.title : "\(session.title) — \(session.desktopName)"
    }

    private var passwordForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Password for \(session.host)")
                .font(.headline)
                .foregroundStyle(.white)
            SecureField("VNC password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .focused($passwordFocused)
                .onSubmit(send)
            HStack {
                Button("Connect", action: send)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
                Button("Cancel") { session.close() }
            }
            Text(session.isTunneled
                 ? "Asked each time and never saved. The connection goes through SSH."
                 : "Asked each time and never saved. This connection is not encrypted, and a VNC password protects little on a network others can watch: use \"Go through\" an SSH host for anything past a network you trust.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 320, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .onAppear { passwordFocused = true }
    }

    private func send() {
        guard !password.isEmpty else { return }
        let typed = password
        // Cleared before it is sent, so it is not left in the field behind the
        // window; the client uses it once and keeps nothing.
        password = ""
        session.submit(password: typed)
    }
}

/// The screen, drawn, with the mouse and keyboard sent to it.
private struct RemoteDesktopSurface: NSViewRepresentable {
    @ObservedObject var session: RemoteDesktopSession

    func makeNSView(context: Context) -> RemoteDesktopNSView {
        let view = RemoteDesktopNSView(session: session)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: RemoteDesktopNSView, context: Context) {
        // Reading `frame` is what ties this to the screen changing.
        _ = session.frame
        nsView.screenChanged()
    }
}

final class RemoteDesktopNSView: NSView {
    private let session: RemoteDesktopSession
    private var buttons: UInt8 = 0
    /// What was sent as pressed for each key, so releasing it releases the same.
    private var pressed: [UInt16: UInt32] = [:]
    private var heldModifiers: [UInt32: Bool] = [:]
    private var trackingArea: NSTrackingArea?

    init(session: RemoteDesktopSession) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    func screenChanged() {
        needsDisplay = true
    }

    // MARK: Drawing

    /// Where the screen sits in the view: as large as fits, centred, in its own
    /// proportions.
    private var screenRect: NSRect {
        let size = session.framebuffer?.size ?? (width: 0, height: 0)
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / CGFloat(size.width), bounds.height / CGFloat(size.height))
        let width = CGFloat(size.width) * scale
        let height = CGFloat(size.height) * scale
        return NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        NSBezierPath.fill(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext,
              let image = session.framebuffer?.image() else { return }
        let target = screenRect
        guard !target.isEmpty else { return }
        // The view is flipped; a CGImage is drawn upright in unflipped space.
        context.saveGState()
        context.translateBy(x: target.minX, y: target.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
        context.restoreGState()
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    /// The point in the remote screen's own pixels, clamped to it.
    private func remotePoint(_ event: NSEvent) -> (Int, Int)? {
        guard let size = session.framebuffer?.size, size.width > 0, size.height > 0 else { return nil }
        let rect = screenRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let x = Int(((point.x - rect.minX) / rect.width) * CGFloat(size.width))
        let y = Int(((point.y - rect.minY) / rect.height) * CGFloat(size.height))
        return (max(0, min(x, size.width - 1)), max(0, min(y, size.height - 1)))
    }

    private func sendPointer(_ event: NSEvent) {
        guard let (x, y) = remotePoint(event) else { return }
        session.client.sendPointer(buttons: buttons, x: x, y: y)
    }

    private func set(_ bit: UInt8, down: Bool, _ event: NSEvent) {
        if down { buttons |= bit } else { buttons &= ~bit }
        sendPointer(event)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        set(1, down: true, event)
    }
    override func mouseUp(with event: NSEvent) { set(1, down: false, event) }
    override func rightMouseDown(with event: NSEvent) { set(4, down: true, event) }
    override func rightMouseUp(with event: NSEvent) { set(4, down: false, event) }
    override func otherMouseDown(with event: NSEvent) { set(2, down: true, event) }
    override func otherMouseUp(with event: NSEvent) { set(2, down: false, event) }
    override func mouseMoved(with event: NSEvent) { sendPointer(event) }
    override func mouseDragged(with event: NSEvent) { sendPointer(event) }
    override func rightMouseDragged(with event: NSEvent) { sendPointer(event) }
    override func otherMouseDragged(with event: NSEvent) { sendPointer(event) }

    override func scrollWheel(with event: NSEvent) {
        guard let (x, y) = remotePoint(event), event.scrollingDeltaY != 0 else { return }
        // A wheel step is a press and release of button 4 (up) or 5 (down).
        let bit: UInt8 = event.scrollingDeltaY > 0 ? 8 : 16
        session.client.sendPointer(buttons: buttons | bit, x: x, y: y)
        session.client.sendPointer(buttons: buttons, x: x, y: y)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat || pressed[event.keyCode] != nil else { return }
        guard let keysym = keysym(for: event) else { return }
        pressed[event.keyCode] = keysym
        session.client.sendKey(down: true, keysym: keysym)
    }

    override func keyUp(with event: NSEvent) {
        guard let keysym = pressed.removeValue(forKey: event.keyCode) else { return }
        session.client.sendKey(down: false, keysym: keysym)
    }

    /// Modifier keys are sent as they go down and up. Command is the remote
    /// machine's Super (Windows) key; Option is Alt.
    override func flagsChanged(with event: NSEvent) {
        let flags = event.modifierFlags
        let states: [(UInt32, Bool)] = [
            (RFB.shiftKeysym, flags.contains(.shift)),
            (RFB.controlKeysym, flags.contains(.control)),
            (RFB.altKeysym, flags.contains(.option)),
            (RFB.superKeysym, flags.contains(.command)),
        ]
        for (keysym, down) in states where (heldModifiers[keysym] ?? false) != down {
            heldModifiers[keysym] = down
            session.client.sendKey(down: down, keysym: keysym)
        }
    }

    /// With Control or Command held the character is the key's own, so Ctrl+C
    /// is `c` with Control down; otherwise it is what the key produced, so
    /// Shift+a is `A`.
    private func keysym(for event: NSEvent) -> UInt32? {
        if let special = RFB.specialKeysym(forKeyCode: event.keyCode) { return special }
        let flags = event.modifierFlags
        let text = (flags.contains(.control) || flags.contains(.command))
            ? event.charactersIgnoringModifiers
            : event.characters
        guard let scalar = text?.unicodeScalars.first else { return nil }
        return RFB.keysym(forCharacter: scalar)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Keys with Command held belong to the remote machine while this has
        // focus, except the ones that close or hide this window.
        guard window?.firstResponder === self, event.modifierFlags.contains(.command) else { return false }
        let key = event.charactersIgnoringModifiers ?? ""
        if ["w", "q", "h", "m", ","].contains(key) { return false }
        guard let keysym = keysym(for: event) else { return false }
        // Pressed and released at once: macOS does not deliver the release of a
        // key it treated as a shortcut, and the key would stay down over there.
        session.client.sendKey(down: true, keysym: keysym)
        session.client.sendKey(down: false, keysym: keysym)
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Whatever was held when focus left is released on the far side.
        if window == nil { releaseEverything() }
    }

    override func resignFirstResponder() -> Bool {
        releaseEverything()
        return super.resignFirstResponder()
    }

    private func releaseEverything() {
        for (_, keysym) in pressed { session.client.sendKey(down: false, keysym: keysym) }
        pressed.removeAll()
        for (keysym, down) in heldModifiers where down { session.client.sendKey(down: false, keysym: keysym) }
        heldModifiers.removeAll()
        buttons = 0
    }
}
