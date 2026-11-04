import AppKit
import Network

/// Asks macOS for the Local Network permission before it is needed, and opens
/// its settings when it was not given. See `LocalNetwork` for why it matters.
///
/// macOS puts its question up when the app itself does something on the local
/// network. An `ssh` the app starts is held to the app's answer, but connecting
/// from it is not reliably what makes the question appear — so a person who
/// never opened the discovery list in Settings → Connections could be refused
/// with `No route to host` without ever being asked. Browsing for SSH services
/// for a moment is what asks: it is the same browse that list does, publishes
/// nothing about this Mac, and connects to nothing.
///
/// Once per launch is enough. When the permission was already given, or
/// already declined, macOS asks nothing and the browse just ends.
enum LocalNetworkPermission {
    private static var asked = false
    private static var browser: NWBrowser?

    /// Puts the question, if macOS still has it to ask. Main thread only.
    static func ask() {
        guard !asked else { return }
        asked = true
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: "_ssh._tcp", domain: nil), using: parameters)
        browser.stateUpdateHandler = { state in
            if case .failed = state { Self.finish() }
        }
        Self.browser = browser
        browser.start(queue: .main)
        // Long enough for the question to go up; the answer does not depend on
        // the browse still running.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { Self.finish() }
    }

    private static func finish() {
        browser?.cancel()
        browser = nil
    }

    /// Opens Privacy & Security → Local Network.
    static func openSettings() {
        if let url = URL(string: LocalNetwork.settingsURL) {
            NSWorkspace.shared.open(url)
        }
    }
}
