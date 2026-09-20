import SwiftUI
import AppKit

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, terminal, composer, panels, connections, security, sync, shortcuts, advanced

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
        case .sync: return "Sync"
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
        case .sync: return "Keep workspaces on this Mac or sync them through iCloud."
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
        case .sync: return "arrow.triangle.2.circlepath"
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
            case .system: return [.security, .sync, .shortcuts, .advanced]
            }
        }
    }
}

/// Settings window: a grouped navigation rail on the left, and a content
/// column headed by the section's title and a line of explanation.
struct SettingsRootView: View {
    @State private var selection: SettingsSection = .general
    @State private var query = ""
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        HStack(spacing: 0) {
            navigationRail(theme: theme)
            FadedDivider(axis: .vertical)
            contentColumn(theme: theme)
        }
        .frame(width: 940, height: 640)
    }

    // MARK: Navigation

    private func navigationRail(theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                TextField("Search settings", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.surface)
            )
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsSection.Group.allCases) { group in
                        let sections = matching(group.sections)
                        if !sections.isEmpty {
                            Text(group.rawValue)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(theme.textSecondary)
                                .padding(.horizontal, 20)
                                .padding(.top, 14)
                                .padding(.bottom, 4)

                            ForEach(sections) { section in
                                SettingsNavRow(
                                    section: section,
                                    isSelected: selection == section
                                ) {
                                    selection = section
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .frame(width: 232)
        .background(theme.sidebar)
    }

    /// Filters the rail as you type, matching a section's title or subtitle.
    private func matching(_ sections: [SettingsSection]) -> [SettingsSection] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return sections }
        return sections.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || $0.subtitle.localizedCaseInsensitiveContains(trimmed)
        }
    }

    // MARK: Content

    private func contentColumn(theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(selection.title)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text(selection.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 26)
            .padding(.top, 22)
            .padding(.bottom, 4)

            Group {
                switch selection {
                case .general: GeneralSettingsView()
                case .appearance: AppearanceSettingsView()
                case .composer: ComposerSettingsView()
                case .terminal: TerminalSettingsView()
                case .panels: PanelsSettingsView()
                case .connections: ConnectionsSettingsView()
                case .security: SecuritySettingsView()
                case .sync: SyncSettingsView()
                case .shortcuts: ShortcutsSettingsView()
                case .advanced: AdvancedSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.background)
    }
}

/// One row in the settings navigation rail.
private struct SettingsNavRow: View {
    let section: SettingsSection
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                Text(section.title)
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? theme.surface : (hovering ? theme.surface.opacity(0.55) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, 12)
    }
}
