import SwiftUI

// Section enum: SettingsSection.swift · AI pane: AISettingsView.swift

struct SettingsRootView: View {
    @State private var selection: SettingsSection
    @State private var query = ""
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID

    /// Opens on `initialSection`. The Settings scene never passes one; it is
    /// here so the README screenshots can show a section without clicking.
    init(initialSection: SettingsSection = .general) {
        _selection = State(initialValue: initialSection)
    }

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        // One surface from edge to edge: the rail, the heading and the page are
        // all `theme.background`, with no divider between them, so nothing in
        // the window reads as a seam. What separates a row from the next is its
        // own highlight, not a change of ground.
        HStack(spacing: 0) {
            navigationRail(theme: theme)
            contentColumn(theme: theme)
        }
        .frame(width: 940, height: 640)
        .background(theme.background)
        // The window's own background, so the bands above and below the content
        // are the same colour as it rather than the system's grey.
        .background(WindowBackgroundPainter(color: theme.background))
        // No title bar above the rail: the search field and the section icons
        // start at the top edge, with the traffic lights floating over the
        // band the rail clears for them.
        .framelessWindow()
        // Something elsewhere in the app pointed here: a file browser that
        // could not sign in, sending the person to the host's settings.
        .onAppear { applyRequestedSection() }
        .onReceive(NotificationCenter.default.publisher(for: SettingsNavigator.didRequest)) { _ in
            applyRequestedSection()
        }
    }

    private func applyRequestedSection() {
        if let section = SettingsNavigator.take() {
            query = ""
            selection = section
        }
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
            // Clears the traffic lights, which now float over the top of the
            // rail rather than sitting in a title bar above it.
            .padding(.top, WindowChrome.titleBarHeight + 10)
            .padding(.bottom, 10)
            .background(WindowDragArea())

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
        .background(theme.background)
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
            // Sits level with the rail's search field now that neither has a
            // title bar above it.
            .padding(.top, WindowChrome.titleBarHeight + 16)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WindowDragArea())

            Group {
                switch selection {
                case .general: GeneralSettingsView()
                case .appearance: AppearanceSettingsView()
                case .composer: ComposerSettingsView()
                case .terminal: TerminalSettingsView()
                case .panels: PanelsSettingsView()
                case .connections: ConnectionsSettingsView()
                case .security: SecuritySettingsView()
                case .ai: AISettingsView()
                case .http: HTTPClientSettingsView()
                case .backup: BackupSettingsView()
                case .shortcuts: ShortcutsSettingsView()
                case .advanced: AdvancedSettingsView()
                }
            }
            // The grouped forms paint a ground of their own, a shade off the
            // heading above them. Hidden, the page shows the window's surface.
            .scrollContentBackground(.hidden)
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
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
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
                    // The section you are in, washed in the accent like the
                    // open tab in the main window's list.
                    .fill(isSelected
                          ? settings.accentColor.opacity(colorScheme == .dark ? 0.2 : 0.14)
                          : theme.surface.opacity(hovering ? 0.55 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Motion.hover, value: hovering)
        .animation(Motion.hover, value: isSelected)
        .onHover { hovering = $0 }
        .padding(.horizontal, 12)
    }
}
