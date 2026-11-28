import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, terminal, composer
    case browser, files, http
    case connections, security, ai, backup, shortcuts, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .composer: return "Composer"
        case .terminal: return "Terminal"
        // A panel's page goes by the panel's own name and icon, so the two
        // cannot drift apart.
        case .browser: return RailItem.browser.title
        case .files: return RailItem.files.title
        case .http: return RailItem.http.title
        case .connections: return "Connections"
        case .security: return "Security"
        case .ai: return "AI"
        case .backup: return "Backup"
        case .shortcuts: return "Shortcuts"
        case .advanced: return "Advanced"
        }
    }

    /// One line under the page title saying what this section is for. The
    /// rail's search matches it as well as the title, so it names what the
    /// page holds.
    var subtitle: String {
        switch self {
        case .general: return "How iTERMiNAL starts up, which shell it runs, profiles, and your editor."
        case .appearance: return "Theme, accent, and the chrome around your terminals."
        case .composer: return "The floating command box: size, fill, and which shell it runs."
        case .terminal: return "Colors, font, cursor, scrollback, and rendering."
        case .browser: return "The browser panel's homepage."
        case .files: return "What the file browser shows, and the folder it opens on."
        case .http: return "Requests, IP lookup, the site explorer, and downloads for the HTTP client panel."
        case .connections: return "Saved SSH hosts, SSH keys, tunnels, and the machines on your network."
        case .security: return "The local scripting API, Secure Keyboard Entry, and what this app does with your data."
        case .ai: return "The OpenAI-compatible assistant behind @ai, Explain / Fix it, and Ask."
        case .backup: return "Where your setup is stored, and snapshots that move it."
        case .shortcuts: return "Every keyboard shortcut in the app."
        case .advanced: return "Resetting preferences, version info, and the tools bundled with the app."
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .composer: return "text.cursor"
        case .terminal: return "terminal"
        case .browser: return RailItem.browser.icon
        case .files: return RailItem.files.icon
        case .http: return RailItem.http.icon
        case .connections: return "network"
        case .security: return "lock.shield"
        case .ai: return "sparkles"
        case .backup: return "externaldrive"
        case .shortcuts: return "keyboard"
        case .advanced: return "wrench.and.screwdriver"
        }
    }

    /// Nav-rail grouping, mirroring how the reference app clusters its own
    /// settings rather than presenting one flat list.
    enum Group: String, CaseIterable, Identifiable {
        case workspace = "Workspace"
        /// One page per panel that has settings of its own. A panel with
        /// none (Notes, Bytes, Tasks and the rest) has no page, rather than
        /// an empty one.
        case panels = "Panels"
        case system = "System"

        var id: String { rawValue }

        var sections: [SettingsSection] {
            switch self {
            case .workspace: return [.general, .appearance, .terminal, .composer]
            case .panels: return [.browser, .files, .http]
            case .system: return [.connections, .security, .ai, .backup, .shortcuts, .advanced]
            }
        }
    }
}
