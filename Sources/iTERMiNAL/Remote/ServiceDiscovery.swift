import Foundation
import Network
import AppKit

/// Something advertising itself on the local network.
///
/// A Bonjour result names a *service*, not a host: "Studio Mac" of type
/// `_rfb._tcp` in `local.`. The address behind it is not known until something
/// resolves it, which is why `host` and `port` are optional here and filled in
/// on demand — see `ServiceDiscovery.resolve`.
struct DiscoveredService: Identifiable, Hashable {
    /// Name and type together: one machine can advertise several services, and
    /// two machines can advertise the same-named service of different types.
    var id: String { "\(kind.rawValue)|\(name)|\(domain)" }

    let name: String
    let kind: RemoteServiceKind
    let domain: String
    var host: String?
    var port: Int?

    /// The Network endpoint this came from, kept so resolution does not have
    /// to reconstruct it from strings.
    let endpoint: NWEndpoint

    var subtitle: String {
        if let host, let port {
            return port == kind.defaultPort ? host : "\(host):\(port)"
        }
        return "\(kind.shortLabel) on this network"
    }
}

/// Watches the local network for services worth connecting to, so a machine
/// advertising screen sharing can be reached without anyone typing an address.
///
/// Browsing only — this publishes nothing about this Mac and opens no
/// connection until the user picks something. macOS asks for local network
/// permission the first time a browser starts; declining leaves the list empty
/// rather than breaking anything, which is why `permissionLikelyDenied` exists
/// to say so instead of showing an unexplained blank.
///
/// Not actor-annotated: every browser is started on `.main`, so the handlers
/// that touch published state already arrive there, and `resolve` hops back
/// explicitly. Marking the class `@MainActor` would only make every call site
/// in a SwiftUI view argue about isolation under this project's Swift 5
/// settings.
final class ServiceDiscovery: ObservableObject {
    static let shared = ServiceDiscovery()

    @Published private(set) var services: [DiscoveredService] = []
    @Published private(set) var isBrowsing = false
    /// Set when every browser failed, which on macOS most often means the
    /// local network prompt was declined.
    @Published private(set) var permissionLikelyDenied = false

    private var browsers: [NWBrowser] = []
    /// Types actually browsed, derived from the kinds that advertise one.
    private static let browsedKinds: [RemoteServiceKind] =
        RemoteServiceKind.allCases.filter { $0.bonjourType != nil }

    private init() {}

    func start() {
        guard browsers.isEmpty else { return }
        permissionLikelyDenied = false
        isBrowsing = true

        for kind in Self.browsedKinds {
            guard let type = kind.bonjourType else { continue }
            let parameters = NWParameters()
            // Peer-to-peer would also surface AirDrop-style interfaces; this
            // is about machines on the network the user is already on.
            parameters.includePeerToPeer = false
            let browser = NWBrowser(
                for: .bonjour(type: type, domain: nil),
                using: parameters
            )
            // Started on .main below, so both handlers arrive there and can
            // touch published state directly.
            browser.stateUpdateHandler = { [weak self] state in
                self?.handle(state: state)
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.apply(results: results, kind: kind)
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        isBrowsing = false
    }

    /// Restarts browsing, for the refresh button — a browser that failed
    /// because permission had not been granted yet will not recover on its own.
    func restart() {
        stop()
        services.removeAll()
        start()
    }

    private func handle(state: NWBrowser.State) {
        switch state {
        case .failed:
            // One type failing is not a verdict; all of them failing with
            // nothing found is what a declined prompt looks like.
            if services.isEmpty {
                permissionLikelyDenied = true
            }
        case .ready:
            permissionLikelyDenied = false
        default:
            break
        }
    }

    private func apply(results: Set<NWBrowser.Result>, kind: RemoteServiceKind) {
        var found: [DiscoveredService] = []
        for result in results {
            guard case .service(let name, _, let domain, _) = result.endpoint else { continue }
            found.append(DiscoveredService(
                name: name,
                kind: kind,
                domain: domain,
                endpoint: result.endpoint
            ))
        }
        // Replace only this kind's entries; the other browsers own theirs.
        var merged = services.filter { $0.kind != kind }
        merged.append(contentsOf: found)
        services = merged.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Turns a discovered service into a host and port.
    ///
    /// Bonjour hands out a service name, and the address behind it is only
    /// known once something asks. Network framework resolves as part of
    /// connecting, so this opens a TCP connection, reads the address it landed
    /// on, and cancels. That is a real connection to the user's own machine —
    /// which is why it happens when they click Connect, and never while
    /// browsing.
    func resolve(
        _ service: DiscoveredService,
        timeout: TimeInterval = 5,
        completion: @escaping (Result<(host: String, port: Int), Error>) -> Void
    ) {
        let connection = NWConnection(to: service.endpoint, using: .tcp)
        // Guards against delivering twice. Cancelling after success produces
        // another state update, and the timeout below can land at the same
        // moment the connection becomes ready.
        let once = CompletionGate()

        func finish(_ result: Result<(host: String, port: Int), Error>) {
            guard once.claim() else { return }
            connection.cancel()
            DispatchQueue.main.async { completion(result) }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                guard let remote = connection.currentPath?.remoteEndpoint,
                      case .hostPort(let host, let port) = remote else {
                    finish(.failure(ServiceDiscoveryError.unresolved))
                    return
                }
                finish(.success((Self.describe(host), Int(port.rawValue))))
            case .failed(let error):
                finish(.failure(error))
            case .cancelled:
                finish(.failure(ServiceDiscoveryError.unresolved))
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            finish(.failure(ServiceDiscoveryError.timedOut))
        }
    }

    /// An IPv6 literal has to keep its zone but lose it for display in a URL
    /// host field, and `NWEndpoint.Host` prints the zone with a `%`.
    private static func describe(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .name(let name, _):
            return name
        case .ipv4(let address):
            return "\(address)".components(separatedBy: "%").first ?? "\(address)"
        case .ipv6(let address):
            return "\(address)".components(separatedBy: "%").first ?? "\(address)"
        @unknown default:
            return "\(host)"
        }
    }
}

/// Lets exactly one of several racing callbacks proceed.
///
/// A plain `Bool` would be read and written from the connection's queue, the
/// timeout's queue and the cancel that follows either.
private final class CompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// True for the first caller only.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

enum ServiceDiscoveryError: LocalizedError {
    case unresolved
    case timedOut
    case noHandler(String)

    var errorDescription: String? {
        switch self {
        case .unresolved:
            return "That service stopped advertising before it could be reached."
        case .timedOut:
            return "That service did not answer. It may have gone away, or be on a network this Mac cannot reach."
        case .noHandler(let scheme):
            return "No app on this Mac opens \(scheme):// links. Install a client for it, or connect by hand."
        }
    }
}
