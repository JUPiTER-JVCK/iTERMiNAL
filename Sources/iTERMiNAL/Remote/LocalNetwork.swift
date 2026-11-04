import Foundation

/// macOS's Local Network permission, as it affects connecting to a host.
///
/// Since macOS 15 an app needs that permission to reach devices on the
/// network the Mac is on, and the `ssh`, `sftp` and `mosh` that iTERMiNAL
/// starts are held to iTERMiNAL's answer. Without it, connecting to a machine
/// on the same Wi-Fi fails with `No route to host` — the same words as a host
/// that is really off the network — while the same command in Terminal works.
///
/// Foundation only, so it is checked off a Mac. What asks for the permission
/// and opens its settings is `LocalNetworkPermission`.
enum LocalNetwork {
    /// The Local Network list in System Settings → Privacy & Security.
    static let settingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork"

    /// Whether `host` names a machine on the local network: a private or
    /// link-local address, or a `.local` name. Loopback is not — this Mac is
    /// always reachable — and neither is a name that has to be looked up, since
    /// what it points at is not known here.
    static func isLocal(host rawHost: String) -> Bool {
        var host = rawHost.trimmingCharacters(in: .whitespaces)
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        // A scoped IPv6 address, `fe80::1%en0`, is link-local by definition;
        // inet_pton does not read the scope, so it is cut off first.
        if let percent = host.firstIndex(of: "%") { host = String(host[..<percent]) }
        if let address = HostLookup.classify(host) {
            return address.kind == .privateNetwork || address.kind == .linkLocal
        }
        let name = host.lowercased()
        return name.hasSuffix(".local") || name.hasSuffix(".local.")
    }

    /// Whether what a failed connection printed is the answer a missing Local
    /// Network permission gives. It is also what a host that is off the network
    /// gives, which is why this is only ever said alongside `isLocal`.
    static func looksBlocked(output: String) -> Bool {
        output.lowercased().contains("no route to host")
    }

    /// A line for the banner of a terminal tab whose ssh ended that way.
    /// Short: the banner has room for two lines.
    static func endNote(host: String) -> String {
        "No route to \(host). If it works from Terminal, allow iTERMiNAL under Local Network in Privacy & Security."
    }
}
