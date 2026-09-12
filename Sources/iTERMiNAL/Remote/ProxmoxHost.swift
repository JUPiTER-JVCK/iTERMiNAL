import Foundation

/// A saved Proxmox VE endpoint.
///
/// Like `SSHConnection`, this holds no secret. The API token has two halves:
/// the identifier (`user@realm!tokenid`) names the token and is not sensitive,
/// so it lives here; the secret half goes to the Keychain under
/// `keychainAccount` and is read only when a request is actually being signed.
///
/// The certificate fingerprint is deliberately *also* stored here rather than
/// in the Keychain. A fingerprint is public information — it is printed in the
/// Proxmox UI and returned by the API's own `vncproxy` endpoint — and treating
/// it as a secret would only make it harder to show the user what they pinned.
struct ProxmoxHost: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    /// `user@realm!tokenid`. The token's name, not its value.
    var tokenID: String
    /// SHA-256 of the DER-encoded leaf certificate, lowercase hex, no
    /// separators. `nil` until the user has confirmed one, which is how
    /// "never connected yet" is distinguished from "trusts a specific cert".
    var pinnedFingerprint: String?

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 8006,
        tokenID: String = "",
        pinnedFingerprint: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.tokenID = tokenID
        self.pinnedFingerprint = pinnedFingerprint
    }

    /// Tolerant decoding, matching `SSHConnection`: a host list saved by an
    /// older build must still load rather than being silently dropped.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 8006
        tokenID = try container.decodeIfPresent(String.self, forKey: .tokenID) ?? ""
        pinnedFingerprint = try container.decodeIfPresent(String.self, forKey: .pinnedFingerprint)
    }

    /// Keychain account for the token's secret half.
    var keychainAccount: String { "proxmox.\(id.uuidString)" }

    var baseURL: URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = port
        return components.url
    }

    var subtitle: String {
        let endpoint = port == 8006 ? host : "\(host):\(port)"
        guard !tokenID.isEmpty else { return endpoint }
        return "\(endpoint) · \(tokenID)"
    }

    /// Whether a certificate has been confirmed for this host.
    var isPinned: Bool {
        !(pinnedFingerprint ?? "").isEmpty
    }

    /// The noVNC console for a guest, as served by the Proxmox web UI.
    ///
    /// Opening this in the app's browser pane is what makes a console reachable
    /// without implementing VNC: Proxmox already ships a web console, and it
    /// handles the ticket exchange itself. The exact parameters have varied
    /// between Proxmox releases, so treat a blank console as a URL-shape
    /// problem to confirm against the running version rather than an auth one.
    func consoleURL(for guest: ProxmoxGuest) -> URL? {
        guard let base = baseURL,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "console", value: guest.kind.consoleValue),
            URLQueryItem(name: "novnc", value: "1"),
            URLQueryItem(name: "vmid", value: String(guest.vmid)),
            URLQueryItem(name: "node", value: guest.node),
            URLQueryItem(
                name: "path",
                value: "/api2/json/nodes/\(guest.node)/\(guest.kind.rawValue)/\(guest.vmid)/vncwebsocket"
            ),
            URLQueryItem(name: "resize", value: "off"),
        ]
        return components.url
    }
}

// MARK: - Fingerprints

enum CertificateFingerprint {
    /// Proxmox prints fingerprints colon-separated and uppercase; users paste
    /// them in every imaginable shape. Compare on a canonical form so a
    /// legitimate match is never rejected over punctuation.
    static func normalized(_ value: String) -> String {
        value.lowercased().filter { $0.isHexDigit }
    }

    /// Grouped into colon-separated byte pairs, which is how Proxmox displays
    /// them — so what the user is asked to compare looks like what they see.
    static func display(_ value: String) -> String {
        let hex = normalized(value)
        return stride(from: 0, to: hex.count, by: 2).map { offset -> String in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            return String(hex[start..<end]).uppercased()
        }.joined(separator: ":")
    }
}
