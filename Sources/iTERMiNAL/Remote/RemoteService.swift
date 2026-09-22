import Foundation

/// A protocol this app can hand a remote host to.
///
/// The app embeds none of these. A terminal session runs the system's own
/// `ssh`; a screen-sharing session opens the system's registered handler for
/// the scheme, which on a stock Mac is Screen Sharing.app for `vnc://`. That
/// keeps the rule the rest of the app already follows: no credential ever
/// passes through here, because this app is never the thing authenticating.
enum RemoteServiceKind: String, Codable, CaseIterable, Identifiable {
    case vnc
    case rdp
    case ssh
    case sftp
    case web

    var id: String { rawValue }

    var label: String {
        switch self {
        case .vnc: return "Screen Sharing (VNC)"
        case .rdp: return "Remote Desktop (RDP)"
        case .ssh: return "SSH"
        case .sftp: return "SFTP"
        case .web: return "Web"
        }
    }

    /// Shown in a list where the full label is too long.
    var shortLabel: String {
        switch self {
        case .vnc: return "VNC"
        case .rdp: return "RDP"
        case .ssh: return "SSH"
        case .sftp: return "SFTP"
        case .web: return "Web"
        }
    }

    var defaultPort: Int {
        switch self {
        case .vnc: return 5900
        case .rdp: return 3389
        case .ssh, .sftp: return 22
        case .web: return 443
        }
    }

    var icon: String {
        switch self {
        case .vnc: return "display"
        case .rdp: return "macwindow.on.rectangle"
        case .ssh: return "terminal"
        case .sftp: return "folder"
        case .web: return "globe"
        }
    }

    /// The Bonjour type this service advertises itself as, when it does.
    ///
    /// `_rfb._tcp` is what macOS Screen Sharing and most VNC servers publish —
    /// RFB being the protocol VNC speaks. There is no registered type for RDP
    /// that Windows advertises by default, so `rdp` has none here: it is a
    /// service you add by hand, not one that turns up.
    var bonjourType: String? {
        switch self {
        case .vnc: return "_rfb._tcp"
        case .rdp: return nil
        case .ssh: return "_ssh._tcp"
        case .sftp: return "_sftp-ssh._tcp"
        case .web: return "_http._tcp"
        }
    }

    /// Which of these the app opens itself rather than handing to the system.
    /// SSH becomes a terminal session, SFTP the file panel, web the browser
    /// panel — all of which this app already has.
    var isHandledInApp: Bool {
        switch self {
        case .ssh, .sftp, .web: return true
        case .vnc, .rdp: return false
        }
    }

    /// URL for the system's registered handler, for the kinds this app does
    /// not open itself.
    ///
    /// `vnc://` reaches Screen Sharing on a stock Mac. `rdp://` reaches
    /// whichever client has claimed it — Microsoft Remote Desktop does — and
    /// if nothing has, the open fails and the caller says so rather than
    /// silently doing nothing.
    func externalURL(host: String, port: Int, username: String) -> URL? {
        let scheme: String
        switch self {
        case .vnc: scheme = "vnc"
        case .rdp: scheme = "rdp"
        case .ssh, .sftp, .web: return nil
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if port != defaultPort { components.port = port }
        if !username.isEmpty { components.user = username }
        return components.url
    }
}

/// A saved remote endpoint that is not a shell.
///
/// Deliberately separate from `SSHConnection`, which carries transport
/// settings, identity files and extra `ssh` arguments that mean nothing to a
/// screen-sharing session. Like that type it holds no secret: VNC and RDP
/// authentication happens in the client the system opens, which this app never
/// sees.
struct RemoteService: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var kind: RemoteServiceKind
    var host: String
    var port: Int
    /// Optional; passed to the handler so the client can pre-fill it. Never a
    /// password — there is nowhere here to put one.
    var username: String

    init(
        id: UUID = UUID(),
        name: String,
        kind: RemoteServiceKind,
        host: String,
        port: Int? = nil,
        username: String = ""
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port ?? kind.defaultPort
        self.username = username
    }

    /// Tolerant decoding, matching `SSHConnection`: a record written by a
    /// build that knew fewer fields still loads instead of wiping the list.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decodeIfPresent(RemoteServiceKind.self, forKey: .kind) ?? .vnc
        host = try container.decode(String.self, forKey: .host)
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? kind.defaultPort
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
    }

    var subtitle: String {
        let base = port == kind.defaultPort ? host : "\(host):\(port)"
        let target = username.isEmpty ? base : "\(username)@\(base)"
        return "\(kind.shortLabel) · \(target)"
    }
}
