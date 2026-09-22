import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, terminal, composer, panels, connections, security, ai, backup, shortcuts, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .composer: return "Composer"
        case .terminal: return "Terminal"
        case .panels: return "Panels"
        case .connections: return "Connections"
        case .security: return "Security"
        case .ai: return "AI"
        case .backup: return "Backup"
        case .shortcuts: return "Shortcuts"
        case .advanced: return "Advanced"
        }
    }

    /// One line under the page title saying what this section is for.
    var subtitle: String {
        switch self {
        case .general: return "How iTERMiNAL starts up and which shell it runs."
        case .appearance: return "Theme, accent, and the chrome around your terminals."
        case .composer: return "The floating command box: size, fill, and which shell it runs."
        case .terminal: return "Colors, font, cursor, scrollback, and rendering."
        case .panels: return "The composer, the browser panel, and the file browser."
        case .connections: return "Saved SSH hosts used for remote sessions and SFTP."
        case .security: return "The local scripting API and what this app does with your data."
        case .ai: return "OpenAI-compatible assistant behind the @ai composer prefix."
        case .backup: return "Where your setup is stored, and snapshots that move it."
        case .shortcuts: return "Every keyboard shortcut in the app."
        case .advanced: return "Session state, resetting preferences, and version info."
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .composer: return "text.cursor"
        case .terminal: return "terminal"
        case .panels: return "sidebar.right"
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
        case surfaces = "Surfaces"
        case system = "System"

        var id: String { rawValue }

        var sections: [SettingsSection] {
            switch self {
            case .workspace: return [.general, .appearance, .terminal, .composer]
            case .surfaces: return [.panels, .connections]
            case .system: return [.security, .ai, .backup, .shortcuts, .advanced]
            }
        }
    }
}
