import SwiftUI

/// Left rail styled after a conversation list: a search field, a prominent
/// "New terminal" row, then workspaces as sections whose tabs read like
/// conversations — title on top, working directory and git branch below.
struct SidebarView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    @State private var query = ""
    @State private var renamingTab: WorkspaceTab?
    @State private var renamingWorkspace: Workspace?
    @State private var renameText = ""

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        VStack(alignment: .leading, spacing: 6) {
            searchField(theme: theme)
                .padding(.horizontal, 10)
                .padding(.top, 10)

            newTerminalRow(theme: theme)
                .padding(.horizontal, 6)

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
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.surface.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.surfaceBorder))
    }

    private func newTerminalRow(theme: Theme) -> some View {
        Button {
            store.newTab()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 13, weight: .medium))
                Text("New terminal")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text("⌘T")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.textPrimary)
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
                TabRowView(tab: tab, onRename: { onRenameTab(tab) })
                    .tag(tab.id)
            }
        } header: {
            HStack {
                Text(workspace.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
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

private struct TabRowView: View {
    @ObservedObject var tab: WorkspaceTab
    let onRename: () -> Void
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        Group {
            if let session = tab.primarySession {
                SessionRowContent(tab: tab, session: session)
            } else {
                Label(tab.displayName, systemImage: "terminal")
            }
        }
        .contextMenu {
            Button("Rename…") { onRename() }
            Button("Close Tab") { store.closeTab(tab) }
        }
    }
}

private struct SessionRowContent: View {
    @ObservedObject var tab: WorkspaceTab
    @ObservedObject var session: TerminalSession

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 12))
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.secondary.opacity(0.15)))
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.displayName)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(session.abbreviatedDirectory)
                        .lineLimit(1)
                        .truncationMode(.head)
                    if let branch = session.gitBranch {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 8))
                        Text(branch)
                            .lineLimit(1)
                    }
                    if !session.isRunning {
                        Text("exited")
                            .foregroundStyle(.red)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
