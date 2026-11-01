import AppKit
import Carbon.HIToolbox

/// macOS's secure keyboard input: while it is on, other apps cannot read what
/// is typed here (the protection a password field gets). Off by default.
///
/// It is on only while the setting is on *and* this is the active app. The
/// system switch is global, so holding it while another app is in front would
/// stop that app's keyboard tools from working for no benefit, and a call left
/// outstanding would outlive a crash. `SecureInputState` keeps the counted
/// enable and disable calls balanced; this type makes them.
///
/// Main thread only.
final class SecureKeyboardEntry {
    static let shared = SecureKeyboardEntry()

    private var state = SecureInputState()

    /// Whether this app has secure input on at the moment.
    var isEngaged: Bool { state.engaged }

    /// Makes secure input match the setting and whether this app is active.
    /// Called when the setting changes and when the app gains or loses focus.
    func refresh(enabled: Bool) {
        update(wanted: enabled && NSApplication.shared.isActive)
    }

    /// Lets go of secure input whatever the setting says. For quitting.
    func release() {
        update(wanted: false)
    }

    private func update(wanted: Bool) {
        state.update(wanted: wanted) { action in
            switch action {
            case .enable:
                return EnableSecureEventInput() == noErr
            case .disable:
                return DisableSecureEventInput() == noErr
            }
        }
    }
}
