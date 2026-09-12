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
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let decodedName = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        let decodedHost = try container.decodeIfPresent(String.self, forKey: .host) ?? ""
        host = decodedHost.isEmpty ? decodedName : decodedHost
        name = decodedName.isEmpty ? (host.isEmpty ? "Proxmox" : host) : decodedName
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 8006
        tokenID = try container.decodeIfPresent(String.self, forKey: .tokenID) ?? ""
        pinnedFingerprint = try container.decodeIfPresent(String.self, forKey: .pinnedFingerprint)
    }

    /// Keychain account for the token's secret half.
    var keychainAccount: String { "proxmox.\(id.uuidString)" }

    private var normalizedEndpoint: (host: String, port: Int, path: String)? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate: String
        if trimmed.contains("://") {
            candidate = trimmed
        } else if let slash = trimmed.firstIndex(of: "/") {
            candidate = "https://\(trimmed[..<slash])\(trimmed[slash...])"
        } else {
            candidate = "https://\(trimmed)"
        }
        guard let components = URLComponents(string: candidate),
              let parsedHost = components.host, !parsedHost.isEmpty else { return nil }
        let parsedPath = components.path == "/" ? "" : components.path
        return (parsedHost, components.port ?? port, parsedPath)
    }

    var baseURL: URL? {
        guard let normalizedEndpoint else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = normalizedEndpoint.host
        components.port = normalizedEndpoint.port
        components.path = normalizedEndpoint.path
        return components.url
    }

    var subtitle: String {
        let endpoint: String
        if let normalizedEndpoint {
            let displayHost = normalizedEndpoint.host.contains(":")
                ? "[\(normalizedEndpoint.host)]"
                : normalizedEndpoint.host
            let authority = normalizedEndpoint.port == 8006
                ? displayHost
                : "\(displayHost):\(normalizedEndpoint.port)"
            endpoint = authority + normalizedEndpoint.path
        } else {
            endpoint = port == 8006 ? host : "\(host):\(port)"
        }
        guard !tokenID.isEmpty else { return endpoint }
        return "\(endpoint) · \(tokenID)"
    }

    /// Whether a certificate has been confirmed for this host.
    var isPinned: Bool {
        !(pinnedFingerprint ?? "").isEmpty
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
