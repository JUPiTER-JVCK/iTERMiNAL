import Foundation
import AppKit

/// Opens a remote service the way this app opens things.
///
/// Three of the kinds it knows are already features here — a shell, a file
/// browser, a web view — so those stay inside the app. Screen sharing and
/// remote desktop are not, and embedding a VNC client to avoid handing off
/// would mean this app authenticating, storing a password, and owning a
/// protocol implementation. The system already has a client for both; it gets
/// the URL.
enum RemoteServiceLauncher {
    /// Opens `service`, reporting anything the user needs to know about.
    ///
    /// The completion carries an error only when there is something to say:
    /// no installed handler for the scheme, or a saved host that no longer
    /// resolves. Success is silent.
    static func open(
        _ service: RemoteService,
        store: WorkspaceStore,
        settings: AppSettings,
        completion: ((Error?) -> Void)? = nil
    ) {
        switch service.kind {
        case .ssh, .sftp:
            openThroughSavedConnection(service, store: store, settings: settings)
            completion?(nil)

        case .web:
            // Only 443 implies TLS. Treating "not 80" as https sent a service
            // discovered on 8080 — which `_http._tcp` routinely is — to a
            // scheme it does not speak.
            var components = URLComponents()
            components.scheme = service.port == 443 ? "https" : "http"
            components.host = service.host
            if service.port != 80 && service.port != 443 {
                components.port = service.port
            }
            if let url = components.url {
                store.openLinkFromTerminal(url.absoluteString)
            }
            completion?(nil)

        case .vnc, .rdp:
            guard let url = service.kind.externalURL(
                host: service.host,
                port: service.port,
                username: service.username
            ) else {
                completion?(ServiceDiscoveryError.unresolved)
                return
            }
            openExternally(url, kind: service.kind, completion: completion)
        }
    }

    /// Hands a URL to whatever app has registered its scheme.
    ///
    /// `NSWorkspace.open` returns false when nothing has, which is a real
    /// outcome worth reporting: a Mac with no RDP client installed would
    /// otherwise look like a button that does nothing.
    private static func openExternally(
        _ url: URL,
        kind: RemoteServiceKind,
        completion: ((Error?) -> Void)?
    ) {
        guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
            completion?(ServiceDiscoveryError.noHandler(url.scheme ?? kind.shortLabel))
            return
        }
        NSWorkspace.shared.open(url)
        EventBus.shared.publish(APIEvent("remote.service.opened", [
            "kind": kind.rawValue,
            "host": url.host ?? "",
        ]))
        completion?(nil)
    }

    /// SSH and SFTP run through the app's own saved-host machinery, so a
    /// service of either kind is matched to an existing `SSHConnection` by
    /// host and port, and one is created if there is no match. Without that a
    /// discovered shell would have nowhere to launch from —
    /// `SessionKind.remote` addresses a saved connection, not an address.
    private static func openThroughSavedConnection(
        _ service: RemoteService,
        store: WorkspaceStore,
        settings: AppSettings
    ) {
        let connection = savedConnection(for: service, settings: settings)
        switch service.kind {
        case .sftp:
            store.openPanel(.files)
            store.panelFiles.switchTo(connectionID: connection.id.uuidString)
        default:
            store.newTab(kind: .remote(connection.id))
        }
    }

    /// An existing saved host for this address, or a new one added to the
    /// list. Matching on host and port keeps repeated connects from filling
    /// Settings → Connections with duplicates of the same machine.
    static func savedConnection(
        for service: RemoteService,
        settings: AppSettings
    ) -> SSHConnection {
        if let existing = settings.sshConnections.first(where: {
            $0.host.caseInsensitiveCompare(service.host) == .orderedSame && $0.port == service.port
        }) {
            return existing
        }
        let connection = SSHConnection(
            name: service.name.isEmpty ? service.host : service.name,
            host: service.host,
            port: service.port,
            username: service.username.isEmpty ? NSUserName() : service.username
        )
        settings.sshConnections.append(connection)
        return connection
    }
}
