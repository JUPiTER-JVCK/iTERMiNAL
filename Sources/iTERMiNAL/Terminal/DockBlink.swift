import AppKit

/// Blinks the cursor in iTERMiNAL's Dock icon while a command runs.
///
/// The Dock is drawn by macOS at normal (SDR) brightness, so the blink is two
/// ordinary pictures swapped: the icon, and the same icon with the cursor
/// hidden. Which two depends on the app's appearance, and `DockIcon` owns that
/// choice; this only says when the cursor is lit.
///
/// A command "runs" from the shell's start mark (see `ShellIntegration`) to its
/// end, so this needs the shell integration on, and is told by each tab. Any
/// tab running one keeps it going, and it stops when the last of them ends.
/// Stopping puts the icon back as it was. It does nothing while Reduce Motion is
/// on or Settings → Terminal turns it off.
final class DockBlink {
    static let shared = DockBlink()

    private var running = Set<UUID>()
    private var timer: Timer?
    private let interval: TimeInterval = 0.55

    private init() {}

    /// A command started in the tab with this id.
    func begin(_ id: UUID) {
        guard AppSettings.shared.dockBlink else { return }
        running.insert(id)
        guard timer == nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            DockIcon.shared.cursorLit.toggle()
        }
        // Common modes, so it keeps going while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        DockIcon.shared.cursorLit = false
    }

    /// The command in that tab ended, or the tab did. Safe to call for one that
    /// never began.
    func end(_ id: UUID) {
        guard running.remove(id) != nil, running.isEmpty else { return }
        stop()
    }

    /// Stops at once, whatever is running (the setting was turned off).
    func cancel() {
        running.removeAll()
        stop()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        DockIcon.shared.cursorLit = true
    }
}
