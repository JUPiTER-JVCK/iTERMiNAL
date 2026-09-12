import CryptoKit
import Foundation

// MARK: - Wire types

/// Every Proxmox API response wraps its payload in `data`.
private struct PVEEnvelope<T: Decodable>: Decodable {
    let data: T
}

struct ProxmoxNode: Decodable, Identifiable, Hashable {
    let node: String
    let status: String?

    var id: String { node }
}

enum ProxmoxGuestKind: String, Codable, Hashable {
    case qemu
    case lxc

    var label: String {
        switch self {
        case .qemu: return "VM"
        case .lxc: return "Container"
        }
    }
}

/// One VM or container as the node listing reports it.
struct ProxmoxGuest: Identifiable, Hashable {
    let vmid: Int
    let name: String
    let status: String
    let node: String
    let kind: ProxmoxGuestKind
    /// Populated separately from the guest agent, which is often not installed.
    var addresses: [String] = []

    var id: String { "\(node)/\(kind.rawValue)/\(vmid)" }

    var isRunning: Bool { status == "running" }

    var displayName: String { name.isEmpty ? "\(vmid)" : name }

    /// The first IPv4 address the agent reported, which is the one worth
    /// offering an SSH action for.
    var primaryAddress: String? { addresses.first }
}

/// The node listing's shape. `name` is absent on a guest that has never been
/// given one, so it decodes optionally and is defaulted at the call site.
private struct GuestListEntry: Decodable {
    let vmid: Int
    let name: String?
    let status: String?
}

// MARK: - Errors

enum ProxmoxError: LocalizedError {
    case notConfigured
    case missingToken
    case http(status: Int, body: String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "This Proxmox host has no address yet."
        case .missingToken:
            return "No API token is saved for this host. Add one in Settings → Connections → Proxmox."
        case .http(let status, let body):
            if status == 401 {
                return "Proxmox rejected the API token (401). Check the token ID and secret, and that the token has permission on this node."
            }
            return "Proxmox returned HTTP \(status). \(body)"
        case .malformedResponse:
            return "Proxmox returned a response this app could not read."
        }
    }
}

// MARK: - Certificate pinning

/// Accepts a server certificate only if the system already trusts it, or if it
/// is exactly the one the user pinned for this host.
///
/// A default Proxmox install serves a self-signed certificate, so without this
/// nothing here would connect at all. The tempting fix — disabling validation,
/// or widening the app's App Transport Security exemption beyond web content —
/// would weaken every connection the app makes. Trust-on-first-use against a
/// fingerprint the user confirmed is narrower than either: exactly one
/// certificate is accepted, and only for this host.
/// The pinning decision itself, with no opinion about who is asking.
///
/// Both the API's URLSession and the browser panel's WKWebView have to reach
/// the same verdict about the same host. WKWebView performs its own trust
/// evaluation and does not consult URLSession's delegate, so without this
/// shared here a Proxmox host could be discovered over a pinned API connection
/// and still fail to open its console — the pin has to be applied in both
/// places or it only half exists.
enum PinnedTrust {
    enum Verdict {
        /// The system already trusts it; nothing to override.
        case systemTrusted
        /// Not system-trusted, but exactly the certificate the user pinned.
        case pinned
        /// Refused. Carries what was actually presented, so the caller can
        /// show the user a fingerprint to compare rather than a bare failure.
        case refused(seen: String?)
    }

    /// SHA-256 of a certificate's DER encoding, lowercase hex — the same value
    /// `openssl x509 -fingerprint -sha256` prints, and what Proxmox displays.
    static func fingerprint(of certificate: SecCertificate) -> String {
        let der = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    static func leafCertificate(of trust: SecTrust) -> SecCertificate? {
        // SecTrustCopyCertificateChain replaces the per-index accessor
        // deprecated in macOS 12; this app targets 14.
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else {
            return nil
        }
        return chain.first
    }

    static func evaluate(_ trust: SecTrust, against pinnedFingerprint: String?) -> Verdict {
        // A properly signed certificate needs no pin. Let the system decide
        // first so a host with a real certificate behaves normally, and the
        // pin only ever *adds* an accepted certificate.
        if SecTrustEvaluateWithError(trust, nil) {
            return .systemTrusted
        }
        guard let leaf = leafCertificate(of: trust) else {
            return .refused(seen: nil)
        }
        let seen = fingerprint(of: leaf)
        guard let pinned = pinnedFingerprint.map(CertificateFingerprint.normalized),
              !pinned.isEmpty, seen == pinned else {
            return .refused(seen: seen)
        }
        return .pinned
    }
}

/// Accepts a server certificate only if the system already trusts it, or if it
/// is exactly the one the user pinned for this host.
///
/// A default Proxmox install serves a self-signed certificate, so without this
/// nothing here would connect at all. The tempting fix — disabling validation,
/// or widening the app's App Transport Security exemption beyond web content —
/// would weaken every connection the app makes. Trust-on-first-use against a
/// fingerprint the user confirmed is narrower than either: exactly one
/// certificate is accepted, and only for this host.
final class ProxmoxTrustDelegate: NSObject, URLSessionDelegate {
    private let pinnedFingerprint: String?
    private(set) var lastSeenFingerprint: String?
    /// Set when a challenge is refused, so the caller can tell a certificate
    /// problem from an address typo, a missing token, or a dead network —
    /// which look nothing alike to a user but identically like "failed" here.
    private(set) var lastRefusedFingerprint: String?

    init(pinnedFingerprint: String?) {
        self.pinnedFingerprint = pinnedFingerprint
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        lastSeenFingerprint = PinnedTrust.leafCertificate(of: trust).map(PinnedTrust.fingerprint)

        switch PinnedTrust.evaluate(trust, against: pinnedFingerprint) {
        case .systemTrusted:
            completionHandler(.performDefaultHandling, nil)
        case .pinned:
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .refused(let seen):
            lastRefusedFingerprint = seen
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

// MARK: - Client

/// Reads a Proxmox VE cluster over its REST API.
///
/// Discovery is deliberately API-driven rather than a port scan. Proxmox does
/// not leave a VNC port listening per VM — a console is created on demand by
/// `vncproxy` behind a one-time ticket — and it never exposes a guest's RDP at
/// all, since that is a service inside the guest on the guest's own address. A
/// scan would therefore find almost nothing and miss every VM worth listing,
/// while the API returns names, status and agent-reported addresses directly.
///
/// A class, not a struct: a URLSession holds a strong reference to its
/// delegate until it is invalidated, so the session has to be torn down when
/// the client goes away or every refresh leaks one.
final class ProxmoxClient {
    let host: ProxmoxHost
    private let session: URLSession
    private let delegate: ProxmoxTrustDelegate
    private static let pathSegmentAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return allowed
    }()

    init(host: ProxmoxHost) {
        self.host = host
        let delegate = ProxmoxTrustDelegate(pinnedFingerprint: host.pinnedFingerprint)
        self.delegate = delegate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        self.session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
    }

    /// The certificate this client actually refused, if any. Non-nil means the
    /// failure really was a trust problem — as opposed to a missing token, a
    /// mistyped address, or an unreachable host, which must not be reported as
    /// certificate trouble.
    var lastRefusedFingerprint: String? { delegate.lastRefusedFingerprint }
    var lastSeenFingerprint: String? { delegate.lastSeenFingerprint }
    private(set) var lastPartialFailureDescription: String?

    deinit {
        session.invalidateAndCancel()
    }

    // MARK: Requests

    private func request(path: String) throws -> URLRequest {
        guard let base = host.baseURL,
              let url = URL(string: "/api2/json\(path)", relativeTo: base) else {
            throw ProxmoxError.notConfigured
        }
        guard let secret = KeychainStore.get(host.keychainAccount), !secret.isEmpty else {
            throw ProxmoxError.missingToken
        }
        var request = URLRequest(url: url)
        // Token auth rather than a password: it is revocable on the server and
        // sidesteps two-factor, and the app never sees a user password.
        request.setValue(
            "PVEAPIToken=\(host.tokenID)=\(secret)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func fetch<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let urlRequest = try request(path: path)
        return try await fetch(urlRequest, as: PVEEnvelope<T>.self).data
    }

    private func fetchRaw<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let urlRequest = try request(path: path)
        return try await fetch(urlRequest, as: type)
    }

    private func fetch<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ProxmoxError.malformedResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ProxmoxError.http(status: http.statusCode, body: body.prefix(200).description)
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ProxmoxError.malformedResponse
        }
    }

    // MARK: API

    private func encodedPathSegment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed) ?? value
    }

    func nodes() async throws -> [ProxmoxNode] {
        try await fetch("/nodes", as: [ProxmoxNode].self)
    }

    func guests(on node: String, kind: ProxmoxGuestKind) async throws -> [ProxmoxGuest] {
        let nodePath = encodedPathSegment(node)
        let entries = try await fetch("/nodes/\(nodePath)/\(kind.rawValue)", as: [GuestListEntry].self)
        return entries.map { entry in
            ProxmoxGuest(
                vmid: entry.vmid,
                name: entry.name ?? "",
                status: entry.status ?? "unknown",
                node: node,
                kind: kind
            )
        }
    }

    /// IPv4 addresses the guest agent reports, or an empty array.
    ///
    /// A stopped guest never answers, and VMs often lack qemu-guest-agent, so
    /// a failure here is ordinary rather than exceptional — it degrades to
    /// "no address known" instead of failing the whole refresh.
    func addresses(for guest: ProxmoxGuest) async -> [String] {
        guard guest.isRunning else { return [] }
        let nodePath = encodedPathSegment(guest.node)
        switch guest.kind {
        case .qemu:
            let path = "/nodes/\(nodePath)/qemu/\(guest.vmid)/agent/network-get-interfaces"
            guard let payload = try? await fetchRaw(path, as: AgentInterfaces.self) else { return [] }
            return payload.data.result
                .flatMap { $0.addresses ?? [] }
                .filter { $0.type == "ipv4" && $0.address != "127.0.0.1" }
                .map { $0.address }
        case .lxc:
            let path = "/nodes/\(nodePath)/lxc/\(guest.vmid)/interfaces"
            guard let payload = try? await fetch(path, as: [LXCInterface].self) else { return [] }
            let explicit = payload
                .flatMap { $0.addresses ?? [] }
                .filter { $0.type == "ipv4" && $0.address != "127.0.0.1" }
                .map { $0.address }
            if !explicit.isEmpty { return explicit }
            return payload
                .compactMap(\.inet)
                .compactMap { $0.split(separator: "/").first.map(String.init) }
                .filter { $0 != "127.0.0.1" }
        }
    }

    /// The whole cluster: every node, its VMs and containers, with addresses
    /// filled in where the agent answers.
    func discover() async throws -> [ProxmoxGuest] {
        lastPartialFailureDescription = nil
        var all: [ProxmoxGuest] = []
        var succeeded = 0
        var lastFailure: Error?

        for node in try await nodes() {
            for kind in [ProxmoxGuestKind.qemu, .lxc] {
                // One kind failing — an unconfigured container store, say —
                // should not hide the other.
                do {
                    all.append(contentsOf: try await guests(on: node.node, kind: kind))
                    succeeded += 1
                } catch {
                    lastFailure = error
                }
            }
        }

        // Swallowing every listing error would turn a token without the right
        // permission into a cheerful "no VMs or containers", which reads as an
        // empty cluster rather than as the access problem it is. Partial
        // results are still worth keeping; a clean sweep of failures is not.
        if succeeded == 0, let failure = lastFailure {
            throw failure
        }
        if let lastFailure {
            lastPartialFailureDescription = lastFailure.localizedDescription
        }

        await resolveAddresses(for: &all)
        return all.sorted {
            ($0.node, $0.kind.rawValue, $0.vmid) < ($1.node, $1.kind.rawValue, $1.vmid)
        }
    }

    /// Fills in agent-reported addresses, several at a time.
    ///
    /// Serially, one stalled guest agent costs the whole refresh its 15-second
    /// timeout, and a cluster of N running VMs takes N of them end to end — so
    /// a large cluster could hang for minutes. Bounded rather than unbounded so
    /// a big cluster does not open a connection per VM at once.
    private func resolveAddresses(for guests: inout [ProxmoxGuest]) async {
        let targets = guests.indices.filter { guests[$0].isRunning }
        guard !targets.isEmpty else { return }

        let snapshot = guests
        let resolved = await withTaskGroup(
            of: (Int, [String]).self,
            returning: [Int: [String]].self
        ) { group in
            var pending = targets.makeIterator()
            var results: [Int: [String]] = [:]
            let limit = 6

            for _ in 0..<limit {
                guard let index = pending.next() else { break }
                group.addTask { (index, await self.addresses(for: snapshot[index])) }
            }
            while let (index, addresses) = await group.next() {
                results[index] = addresses
                if let next = pending.next() {
                    group.addTask { (next, await self.addresses(for: snapshot[next])) }
                }
            }
            return results
        }

        for (index, addresses) in resolved {
            guests[index].addresses = addresses
        }
    }

    /// Fetches the certificate the host presents, so the user can confirm it
    /// before anything is pinned. Returns the fingerprint it saw.
    ///
    /// Deliberately its own session with no pin: this runs precisely when
    /// nothing is trusted yet, and its only job is to report what is there.
    static func probeFingerprint(for host: ProxmoxHost) async -> String? {
        guard let base = host.baseURL,
              let probeURL = URL(string: "/api2/json/version", relativeTo: base) else { return nil }
        let probe = ProxmoxTrustDelegate(pinnedFingerprint: nil)
        let session = URLSession(
            configuration: .ephemeral,
            delegate: probe,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        // Whether the certificate is already trusted or not, the delegate sees
        // the leaf certificate during trust evaluation and records it.
        _ = try? await session.data(from: probeURL)
        return probe.lastSeenFingerprint
    }
}

// MARK: - Guest agent shapes

/// `network-get-interfaces` uses hyphenated keys, which need mapping by hand.
private struct AgentInterfaces: Decodable {
    struct Payload: Decodable {
        let result: [Interface]
    }

    struct Interface: Decodable {
        let name: String?
        let addresses: [Address]?

        enum CodingKeys: String, CodingKey {
            case name
            case addresses = "ip-addresses"
        }
    }

    struct Address: Decodable {
        let address: String
        let type: String

        enum CodingKeys: String, CodingKey {
            case address = "ip-address"
            case type = "ip-address-type"
        }
    }

    let data: Payload
}

private struct LXCInterface: Decodable {
    let inet: String?
    let addresses: [AgentInterfaces.Address]?

    enum CodingKeys: String, CodingKey {
        case inet
        case addresses = "ip-addresses"
    }
}
