import SwiftUI

/// Left rail modelled on the reference app: a titled header with search and
/// compose actions, quick-action rows, three collapsible sections (Pinned,
/// Projects, Recents), and a pinned status row at the bottom.
struct SidebarView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    @State private var query = ""
    @State private var searchVisible = false
    @State private var expandedWorkspaces: Set<UUID> = []
    @State private var renamingTab: WorkspaceTab?
    @State private var renamingWorkspace: Workspace?
    @State private var renameText = ""

    /// How many tabs a project shows before "Show more".
    private let collapsedTabLimit = 6

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        VStack(alignment: .leading, spacing: 0) {
            header(theme: theme)

            if searchVisible {
                searchField(theme: theme)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    SidebarActionRow(icon: "square.and.pencil", title: "New terminal", shortcutHint: "⌘T") {
                        store.newTab()
                    }
                    SidebarConnectionRow()
                    SidebarActionRow(
                        icon: "clock",
                        title: "Automations",
                        isActive: store.detailMode == .automations
                    ) {
                        store.detailMode = .automations
                    }
                    SidebarActionRow(
                        icon: "book",
                        title: "Skills",
                        isActive: store.detailMode == .skills
                    ) {
                        store.detailMode = .skills
                    }

                    pinnedSection(theme: theme)
                    projectsSection(theme: theme)
                    recentsSection(theme: theme)
                }
                .padding(.top, 4)
                .padding(.bottom, 8)
            }

            Spacer(minLength: 0)
            SidebarStatusRow()
        }
        .background {
            // The reference app draws a flat sidebar; vibrancy is opt-in.
            if settings.sidebarTranslucent {
                VisualEffectView(material: .sidebar).ignoresSafeArea()
            } else {
                theme.sidebar.ignoresSafeArea()
            }
        }
        .alert("Rename Tab", isPresented: isRenamingTab, presenting: renamingTab) { tab in
            TextField("Name", text: $renameText)
            Button("Rename") {
                tab.customName = renameText.isEmpty ? nil : renameText
                store.scheduleSave()
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Workspace", isPresented: isRenamingWorkspace, presenting: renamingWorkspace) { workspace in
            TextField("Name", text: $renameText)
            Button("Rename") {
                if !renameText.isEmpty {
                    workspace.name = renameText
                    store.scheduleSave()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Header

    private func header(theme: Theme) -> some View {
        HStack(spacing: 6) {
            Menu {
                Button("New Workspace") { store.newWorkspace() }
                Button("New Terminal") { store.newTab() }
                Divider()
                SettingsLink { Text("Settings…") }
            } label: {
                HStack(spacing: 5) {
                    Text("iTERMiNAL")
                        .font(.system(size: 19, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(theme.textPrimary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Spacer()

            Button {
                withAnimation(Motion.disclosure) {
                    searchVisible.toggle()
                    if !searchVisible { query = "" }
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("Search")

            Button {
                store.newTab()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .help("New terminal")
        }
        .foregroundStyle(theme.textSecondary)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private func searchField(theme: Theme) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.surface.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.surfaceBorder))
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: Sections

    @ViewBuilder
    private func pinnedSection(theme: Theme) -> some View {
        let tabs = matching(store.pinnedTabs)
        if !tabs.isEmpty {
            SidebarSectionHeader(
                title: "Pinned",
                isExpanded: $settings.pinnedExpanded,
                showsDot: false
            )
            if settings.pinnedExpanded {
                ForEach(tabs) { tab in
                    tabRow(tab, indented: false)
                }
            }
        }
    }

    @ViewBuilder
    private func projectsSection(theme: Theme) -> some View {
        SidebarSectionHeader(
            title: "Projects",
            isExpanded: $settings.projectsExpanded,
            showsDot: store.workspaces.contains { workspace in
                workspace.tabs.contains { $0.id != store.selectedTabID && ($0.primarySession?.isRunning ?? false) }
            }
        ) {
            Button {
                store.newWorkspace()
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .help("New workspace")
        }

        if settings.projectsExpanded {
            ForEach(store.workspaces) { workspace in
                workspaceGroup(workspace, theme: theme)
            }
        }
    }

    @ViewBuilder
    private func workspaceGroup(_ workspace: Workspace, theme: Theme) -> some View {
        let tabs = matching(workspace.tabs)
        let isExpanded = expandedWorkspaces.contains(workspace.id) || !query.isEmpty
        let visible = isExpanded ? tabs : Array(tabs.prefix(collapsedTabLimit))

        WorkspaceFolderRow(
            workspace: workspace,
            isExpanded: isExpanded,
            onToggle: {
                withAnimation(Motion.disclosure) {
                    if expandedWorkspaces.contains(workspace.id) {
                        _ = expandedWorkspaces.remove(workspace.id)
                    } else {
                        _ = expandedWorkspaces.insert(workspace.id)
                    }
                }
            },
            onNewTab: { store.newTab(in: workspace) },
            onRename: {
                renameText = workspace.name
                renamingWorkspace = workspace
            },
            onDelete: { store.deleteWorkspace(workspace) }
        )

        ForEach(visible) { tab in
            tabRow(tab, indented: true)
        }

        if tabs.count > visible.count {
            Button {
                withAnimation(Motion.disclosure) {
                    _ = expandedWorkspaces.insert(workspace.id)
                }
            } label: {
                Text("Show more")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.leading, 30)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func recentsSection(theme: Theme) -> some View {
        let recents = store.recentSessions.filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
        }
        if !recents.isEmpty {
            SidebarSectionHeader(
                title: "Recents",
                isExpanded: $settings.recentsExpanded,
                showsDot: false
            ) {
                Button {
                    store.clearRecents()
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("Clear recents")
            }

            if settings.recentsExpanded {
                ForEach(recents) { recent in
                    SidebarRecentRow(recent: recent) {
                        store.reopen(recent)
                    }
                }
            }
        }
    }

    private func tabRow(_ tab: WorkspaceTab, indented: Bool) -> some View {
        SidebarTabRow(
            tab: tab,
            indented: indented,
            isSelected: store.selectedTabID == tab.id,
            onSelect: {
                store.selectedTabID = tab.id
                store.detailMode = .terminal
            },
            onRename: {
                renameText = tab.displayName
                renamingTab = tab
            }
        )
    }

    private func matching(_ tabs: [WorkspaceTab]) -> [WorkspaceTab] {
        guard !query.isEmpty else { return tabs }
        return tabs.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    private var isRenamingTab: Binding<Bool> {
        Binding(get: { renamingTab != nil }, set: { if !$0 { renamingTab = nil } })
    }

    private var isRenamingWorkspace: Binding<Bool> {
        Binding(get: { renamingWorkspace != nil }, set: { if !$0 { renamingWorkspace = nil } })
    }
}

// MARK: - Section header

/// Collapsible section header with a disclosure chevron, an optional unread
/// dot, and room for one trailing action.
private struct SidebarSectionHeader<Accessory: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    let showsDot: Bool
    let accessory: Accessory

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    init(
        title: String,
        isExpanded: Binding<Bool>,
        showsDot: Bool = false,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self._isExpanded = isExpanded
        self.showsDot = showsDot
        self.accessory = accessory()
    }

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        HStack(spacing: 4) {
            Button {
                withAnimation(Motion.disclosure) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    if showsDot && !isExpanded {
                        Circle()
                            .fill(Color(hex: 0x3B82F6))
                            .frame(width: 5, height: 5)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if hovering {
                accessory
            }
        }
        .foregroundStyle(theme.textSecondary)
        .padding(.horizontal, 14)
        .padding(.top, 18)
        .padding(.bottom, 6)
        .onHover { hovering = $0 }
    }
}

extension SidebarSectionHeader where Accessory == EmptyView {
    init(title: String, isExpanded: Binding<Bool>, showsDot: Bool = false) {
        self.init(title: title, isExpanded: isExpanded, showsDot: showsDot) { EmptyView() }
    }
}

// MARK: - Rows

/// The visual body every top-level sidebar row shares.
///
/// Connect renders inside a `Menu` rather than a `Button`, so it used to be a
/// separate copy of this layout — and drifted out of alignment with its
/// neighbours the moment the metrics were retuned. One view, no drift.
struct SidebarRowContent: View {
    let icon: String
    let title: String
    var shortcutHint: String? = nil
    var badge: Int? = nil
    var isActive = false
    var isHovering = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .frame(width: 18)
            Text(title)
                .font(.system(size: 13))
            Spacer()
            if let badge, badge > 0 {
                Text("\(badge)")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(theme.surfaceHover))
            } else if let shortcutHint {
                Text(shortcutHint)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .foregroundStyle(theme.textPrimary)
        .padding(.horizontal, 9)
        // Fixed height rather than padding arithmetic: the reference app
        // sits on a 34pt rhythm and text metrics vary by label.
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isActive ? theme.surface : (isHovering ? theme.surface.opacity(0.6) : Color.clear))
        )
        .contentShape(Rectangle())
    }
}

struct SidebarActionRow: View {
    let icon: String
    let title: String
    var shortcutHint: String? = nil
    var badge: Int? = nil
    var isActive = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            SidebarRowContent(
                icon: icon,
                title: title,
                shortcutHint: shortcutHint,
                badge: badge,
                isActive: isActive,
                isHovering: hovering
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, 8)
    }
}

/// "Connect" row: opens a saved SSH/mosh host in a new tab.
struct SidebarConnectionRow: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @State private var hovering = false

    var body: some View {
        Menu {
            if settings.sshConnections.isEmpty {
                Text("No saved hosts — add one in Settings → Connections")
            } else {
                ForEach(settings.sshConnections) { connection in
                    Button("\(connection.name) — \(connection.subtitle)") {
                        store.newTab(kind: .remote(connection.id))
                    }
                }
            }
        } label: {
            SidebarRowContent(icon: "network", title: "Connect", isHovering: hovering)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .onHover { hovering = $0 }
        .padding(.horizontal, 8)
    }
}

/// Workspace folder row that expands to its tabs.
private struct WorkspaceFolderRow: View {
    @ObservedObject var workspace: Workspace
    let isExpanded: Bool
    let onToggle: () -> Void
    let onNewTab: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        HStack(spacing: 6) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "folder" : "folder.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(IdentityPalette.color(for: workspace.id))
                    Text(workspace.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if hovering {
                Menu {
                    Button("New Tab Here", action: onNewTab)
                    Button("Rename Workspace…", action: onRename)
                    Divider()
                    Button("Delete Workspace", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 10))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .foregroundStyle(theme.textPrimary)
        .padding(.horizontal, 17)
        .frame(height: 30)
        .onHover { hovering = $0 }
    }
}

/// One tab: activity dot, title, relative timestamp.
private struct SidebarTabRow: View {
    @ObservedObject var tab: WorkspaceTab
    let indented: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onRename: () -> Void

    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        // A real Button for the row — it keeps keyboard activation and the
        // VoiceOver button role — with the pin and close controls overlaid
        // as siblings rather than nested inside its label.
        ZStack(alignment: .trailing) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    if let session = tab.primarySession {
                        SessionRowContent(
                            tab: tab,
                            session: session,
                            isSelected: isSelected,
                            isHovering: hovering
                        )
                    } else {
                        Text(tab.displayName)
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                .padding(.leading, indented ? 22 : 9)
                .padding(.trailing, 9)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? theme.surfaceHover : (hovering ? theme.surface.opacity(0.5) : Color.clear))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if hovering {
                HStack(spacing: 2) {
                    RowIconButton(
                        icon: tab.isPinned ? "pin.slash" : "pin",
                        help: tab.isPinned ? "Unpin" : "Pin",
                        theme: theme
                    ) {
                        store.togglePin(tab)
                    }
                    RowIconButton(icon: "xmark", help: "Close tab", theme: theme) {
                        store.closeTab(tab)
                    }
                }
                .padding(.trailing, 7)
            }
        }
        .foregroundStyle(theme.textPrimary)
        .onHover { hovering = $0 }
        .padding(.horizontal, 8)
        .contextMenu {
            Button(tab.isPinned ? "Unpin" : "Pin") { store.togglePin(tab) }
            Button("Rename…", action: onRename)
            Divider()
            Button("Close Tab") { store.closeTab(tab) }
        }
    }
}

private struct SessionRowContent: View {
    @ObservedObject var tab: WorkspaceTab
    @ObservedObject var session: TerminalSession
    let isSelected: Bool
    /// Hover lives on the parent row, which owns the whole hit area.
    var isHovering = false

    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        HStack(spacing: 6) {
            ZStack {
                if showsActivityDot {
                    Circle()
                        .fill(Color(hex: 0x3B82F6))
                        .frame(width: 6, height: 6)
                }
            }
            .frame(width: 8)

            Image(systemName: session.isRemote ? "network" : "terminal")
                .font(.system(size: 10))
                .foregroundStyle(theme.textSecondary)

            Text(tab.displayName)
                .font(.system(size: 13))
                .lineLimit(1)

            if tab.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(theme.textSecondary)
            }

            Spacer(minLength: 6)

            // Hovering hands this space to the pin and close buttons, which
            // the parent overlays as siblings — they cannot live here without
            // nesting a Button inside the row's own Button.
            if !isHovering {
                if let note = session.statusNote {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    Text(RelativeTime.short(since: session.lastActivityAt))
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textSecondary)
                        .monospacedDigit()
                }
            }
        }
        .help(tooltip)
    }

    /// Blue dot = a live process in a tab you're not currently looking at.
    private var showsActivityDot: Bool {
        session.isRunning && store.selectedTabID != tab.id
    }

    private var tooltip: String {
        var parts = [session.abbreviatedDirectory]
        if let branch = session.gitBranch { parts.append("⎇ " + branch) }
        return parts.joined(separator: "  ")
    }
}

/// A compact trailing action inside a sidebar row.
private struct RowIconButton: View {
    let icon: String
    let help: String
    let theme: Theme
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(hovering ? theme.textPrimary : theme.textSecondary)
                .frame(width: 18, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovering ? theme.surfaceHover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// A closed session, click to reopen.
private struct SidebarRecentRow: View {
    let recent: RecentSession
    let onReopen: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        Button(action: onReopen) {
            HStack(spacing: 6) {
                Image(systemName: recent.isRemote ? "network" : "arrow.uturn.left")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 14)
                Text(recent.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(RelativeTime.short(since: recent.closedAt))
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textSecondary)
                    .monospacedDigit()
            }
            .padding(.leading, 22)
            .padding(.trailing, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? theme.surface.opacity(0.5) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.textPrimary)
        .onHover { hovering = $0 }
        .padding(.horizontal, 8)
        .help("Reopen \(recent.directory)")
    }
}

/// Bottom-left status: what the app is doing right now, and a way into
/// Settings and the shortcut list.
private struct SidebarStatusRow: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var metrics = ProcessMetrics.shared
    @State private var showShortcuts = false

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        VStack(spacing: 0) {
            FadedDivider()
            HStack(spacing: 8) {
                SettingsLink {
                    HStack(spacing: 8) {
                        // The API's on/off state keeps a home in this dot
                        // rather than a line of text, leaving the row for
                        // numbers that actually change.
                        Circle()
                            .fill(settings.localAPIEnabled ? settings.accentColor : theme.textSecondary.opacity(0.35))
                            .frame(width: 7, height: 7)
                            .help(settings.localAPIEnabled
                                  ? "Local scripting API is listening"
                                  : "Local scripting API is off")

                        MetricReadout(label: "CPU", value: metrics.cpuText, theme: theme)
                        MetricReadout(label: "RAM", value: metrics.memoryText, theme: theme)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open Settings")

                Spacer()

                Button {
                    showShortcuts = true
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Keyboard shortcuts")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .popover(isPresented: $showShortcuts, arrowEdge: .top) {
            ShortcutsPopover()
        }
        .onAppear { metrics.start() }
        .onDisappear { metrics.stop() }
    }
}

/// One footer statistic: a muted label and a monospaced-digit value, so the
/// row doesn't jitter as the numbers change width.
private struct MetricReadout: View {
    let label: String
    let value: String
    let theme: Theme

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.textSecondary)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(theme.textPrimary)
        }
    }
}

private struct ShortcutsPopover: View {
    private let shortcuts: [(String, String)] = [
        ("Command palette", "⌘K"),
        ("New terminal tab", "⌘T"),
        ("New workspace", "⇧⌘N"),
        ("Split right / down", "⌘D / ⇧⌘D"),
        ("Split with browser", "⇧⌘B"),
        ("Close pane / tab", "⇧⌘W / ⌥⌘W"),
        ("Browser / Files panel", "⌥⌘B / ⌥⌘F"),
        ("Settings", "⌘,"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Shortcuts")
                .font(.system(size: 12, weight: .semibold))
            ForEach(shortcuts, id: \.0) { shortcut in
                HStack {
                    Text(shortcut.0)
                        .font(.system(size: 11))
                    Spacer(minLength: 16)
                    Text(shortcut.1)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(width: 260)
    }
}
