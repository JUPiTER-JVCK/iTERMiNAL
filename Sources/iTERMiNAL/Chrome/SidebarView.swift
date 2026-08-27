import SwiftUI

/// Left rail matching the reference layout: a small icon strip up top,
/// action rows (New terminal / Automations / Skills), then a Workspaces
/// section with folder headers and single-line tab rows. Background sessions
/// that are still running get a blue activity dot.
struct SidebarView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    @State private var query = ""
    @State private var searchVisible = false
    @State private var renamingTab: WorkspaceTab?
    @State private var renamingWorkspace: Workspace?
    @State private var renameText = ""

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Spacer()
                Button {
                    searchVisible.toggle()
                    if !searchVisible { query = "" }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Search tabs")
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)

            if searchVisible {
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
            }

            SidebarActionRow(icon: "square.and.pencil", title: "New terminal", shortcutHint: "⌘T", isActive: false) {
                store.newTab()
            }
            SidebarConnectionRow()

            SidebarActionRow(icon: "clock", title: "Automations", isActive: store.detailMode == .automations) {
                store.detailMode = .automations
            }
            SidebarActionRow(icon: "book", title: "Skills", isActive: store.detailMode == .skills) {
                store.detailMode = .skills
            }

            Text("Workspaces")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 2)

            List(selection: $store.selectedTabID) {
                ForEach(store.workspaces) { workspace in
                    WorkspaceSectionView(
                        workspace: workspace,
                        query: query,
                        onRenameTab: { tab in
                            renameText = tab.displayName
                            renamingTab = tab
                        },
                        onRenameWorkspace: { workspace in
                            renameText = workspace.name
                            renamingWorkspace = workspace
                        }
                    )
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(VisualEffectView(material: .sidebar).ignoresSafeArea())
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

    private var isRenamingTab: Binding<Bool> {
        Binding(get: { renamingTab != nil }, set: { if !$0 { renamingTab = nil } })
    }

    private var isRenamingWorkspace: Binding<Bool> {
        Binding(get: { renamingWorkspace != nil }, set: { if !$0 { renamingWorkspace = nil } })
    }
}

/// "Connect" row: opens a saved SSH/mosh host in a new tab.
private struct SidebarConnectionRow: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        Menu {
            if settings.sshConnections.isEmpty {
                Text("No saved hosts — add one in Settings → Connections")
            } else {
                ForEach(settings.sshConnections) { connection in
                    Button {
                        store.newTab(kind: .remote(connection.id))
                    } label: {
                        Text("\(connection.name) — \(connection.subtitle)")
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "network")
                    .font(.system(size: 13))
                    .frame(width: 18)
                Text("Connect")
                    .font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? theme.surface.opacity(0.6) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .foregroundStyle(theme.textPrimary)
        .onHover { hovering = $0 }
        .padding(.horizontal, 8)
    }
}

private struct SidebarActionRow: View {
    let icon: String
    let title: String
    var shortcutHint: String? = nil
    var isActive = false
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13))
                Spacer()
                if let shortcutHint {
                    Text(shortcutHint)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isActive ? theme.surface : (hovering ? theme.surface.opacity(0.6) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.textPrimary)
        .onHover { hovering = $0 }
        .padding(.horizontal, 8)
    }
}

private struct WorkspaceSectionView: View {
    @ObservedObject var workspace: Workspace
    let query: String
    let onRenameTab: (WorkspaceTab) -> Void
    let onRenameWorkspace: (Workspace) -> Void
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        Section {
            ForEach(filteredTabs) { tab in
                CodexTabRow(tab: tab, onRename: { onRenameTab(tab) })
                    .tag(tab.id)
            }
        } header: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                Text(workspace.name)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Menu {
                    Button("New Tab Here") { store.newTab(in: workspace) }
                    Button("Rename Workspace…") { onRenameWorkspace(workspace) }
                    Divider()
                    Button("Delete Workspace", role: .destructive) {
                        store.deleteWorkspace(workspace)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }

    private var filteredTabs: [WorkspaceTab] {
        guard !query.isEmpty else { return workspace.tabs }
        return workspace.tabs.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
        }
    }
}

private struct CodexTabRow: View {
    @ObservedObject var tab: WorkspaceTab
    let onRename: () -> Void
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        Group {
            if let session = tab.primarySession {
                CodexTabRowContent(tab: tab, session: session)
            } else {
                Text(tab.displayName)
                    .font(.system(size: 13))
            }
        }
        // Clicking any tab row returns the detail column to the terminal,
        // even when the row was already selected.
        .simultaneousGesture(TapGesture().onEnded { store.detailMode = .terminal })
        .contextMenu {
            Button("Rename…") { onRename() }
            Button("Close Tab") { store.closeTab(tab) }
        }
    }
}

private struct CodexTabRowContent: View {
    @ObservedObject var tab: WorkspaceTab
    @ObservedObject var session: TerminalSession
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                if showsActivityDot {
                    Circle()
                        .fill(Color(hex: 0x3B82F6))
                        .frame(width: 6, height: 6)
                }
            }
            .frame(width: 8)
            Text(tab.displayName)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer()
            if let note = session.statusNote {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .help(rowTooltip)
    }

    /// Blue dot = a live process in a tab you're not currently looking at.
    private var showsActivityDot: Bool {
        session.isRunning && store.selectedTabID != tab.id
    }

    private var rowIcon: String {
        session.isRemote ? "network" : "terminal"
    }

    private var rowTooltip: String {
        var parts = [session.abbreviatedDirectory]
        if let branch = session.gitBranch {
            parts.append("⎇ " + branch)
        }
        return parts.joined(separator: "  ")
    }
}
