import SwiftUI
import Foundation

enum SidePanel: String, CaseIterable, Identifiable {
    case browser, files
    var id: String { rawValue }
    var title: String {
        switch self {
        case .browser: return "Browser"
        case .files: return "Files"
        }
    }
    var icon: String {
        switch self {
        case .browser: return "globe"
        case .files: return "folder"
        }
    }
}

/// Single source of truth for workspaces, tabs, pane layout, focus, and the
/// sliding side panels. Layout is snapshotted to Application Support and
/// restored on the next launch.
final class WorkspaceStore: ObservableObject {
    static let shared = WorkspaceStore()

    @Published var workspaces: [Workspace] = []
    @Published var selectedTabID: UUID? {
        didSet {
            guard oldValue != selectedTabID else { return }
            focusSelectedTab()
            scheduleSave()
        }
    }
    @Published var focusedSessionID: UUID?
    @Published var activePanel: SidePanel?

    /// Models backing the sliding side panels (distinct from panes that live
    /// inside a tab's split layout).
    lazy var panelBrowser = BrowserModel()
    lazy var panelFiles = FileBrowserModel()

    private var pendingSave: DispatchWorkItem?

    private let stateURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("iTERMiNAL", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("state.json")
    }()

    private init() {
        if !(AppSettings.shared.restoreSession && restore()) {
            bootstrap()
        }
    }

    private func bootstrap() {
        let workspace = Workspace(name: "Workspace 1")
        workspaces = [workspace]
        newTab(in: workspace)
    }

    // MARK: Lookup

    var selectedTab: WorkspaceTab? {
        guard let selectedTabID else { return nil }
        return workspaces.flatMap(\.tabs).first { $0.id == selectedTabID }
    }

    var currentWorkspace: Workspace? {
        if let selectedTabID,
           let workspace = workspaces.first(where: { $0.tabs.contains { $0.id == selectedTabID } }) {
            return workspace
        }
        return workspaces.first
    }

    func workspace(containingTab tabID: UUID) -> Workspace? {
        workspaces.first { $0.tabs.contains { $0.id == tabID } }
    }

    var focusedSession: TerminalSession? {
        if let focusedSessionID,
           let session = session(withID: focusedSessionID) {
            return session
        }
        return selectedTab?.root.firstTerminal()
    }

    func session(withID id: UUID) -> TerminalSession? {
        for workspace in workspaces {
            for tab in workspace.tabs {
                if let session = tab.root.allSessions().first(where: { $0.id == id }) {
                    return session
                }
            }
        }
        return nil
    }

    func noteFocused(session: TerminalSession) {
        if focusedSessionID != session.id {
            focusedSessionID = session.id
        }
    }

    private func focusSelectedTab() {
        guard let tab = selectedTab else { return }
        let sessions = tab.root.allSessions()
        if let focusedSessionID, sessions.contains(where: { $0.id == focusedSessionID }) {
            return
        }
        focusedSessionID = sessions.first?.id
    }

    // MARK: Workspace / tab lifecycle

    func newWorkspace() {
        let workspace = Workspace(name: "Workspace \(workspaces.count + 1)")
        workspaces.append(workspace)
        newTab(in: workspace)
    }

    @discardableResult
    func newTab(in workspace: Workspace? = nil, directory: String? = nil) -> WorkspaceTab {
        let target: Workspace
        if let workspace {
            target = workspace
        } else if let current = currentWorkspace {
            target = current
        } else {
            let created = Workspace(name: "Workspace 1")
            workspaces = [created]
            target = created
        }

        let session = TerminalSession(initialDirectory: directory)
        session.startIfNeeded()
        let tab = WorkspaceTab(root: PaneNode(content: .terminal(session)))
        target.tabs.append(tab)
        selectedTabID = tab.id
        focusedSessionID = session.id
        scheduleSave()
        return tab
    }

    func closeTab(_ tab: WorkspaceTab) {
        guard let workspace = workspace(containingTab: tab.id) else { return }
        tab.root.allSessions().forEach { $0.terminate() }
        workspace.tabs.removeAll { $0 === tab }
        if selectedTabID == tab.id {
            selectedTabID = workspace.tabs.last?.id ?? workspaces.flatMap(\.tabs).last?.id
        }
        scheduleSave()
    }

    func closeSelectedTab() {
        guard let tab = selectedTab else { return }
        closeTab(tab)
    }

    func deleteWorkspace(_ workspace: Workspace) {
        workspace.tabs.forEach { $0.root.allSessions().forEach { $0.terminate() } }
        workspaces.removeAll { $0 === workspace }
        if workspaces.isEmpty {
            bootstrap()
        } else if selectedTab == nil {
            selectedTabID = workspaces.flatMap(\.tabs).last?.id
        }
        scheduleSave()
    }

    // MARK: Splits

    func splitFocusedPane(_ direction: SplitDirection, kind: PaneKind) {
        guard let tab = selectedTab else {
            newTab()
            return
        }

        let target: PaneNode
        if let focusedSessionID,
           let leaf = tab.root.leaf(containingSessionID: focusedSessionID) {
            target = leaf
        } else {
            target = tab.root
        }

        let newContent: PaneContent
        switch kind {
        case .terminal:
            let session = TerminalSession(initialDirectory: focusedSession?.currentDirectory)
            session.startIfNeeded()
            newContent = .terminal(session)
            focusedSessionID = session.id
        case .browser:
            newContent = .browser(BrowserModel())
        case .files:
            newContent = .files(FileBrowserModel(path: focusedSession?.currentDirectory))
        }

        let existing = PaneNode(content: target.content)
        let added = PaneNode(content: newContent)
        target.content = .split(direction, [existing, added])
        scheduleSave()
    }

    func closeFocusedPane() {
        guard let tab = selectedTab else { return }
        guard let focusedSessionID,
              let leaf = tab.root.leaf(containingSessionID: focusedSessionID) else {
            closeTab(tab)
            return
        }
        if leaf === tab.root {
            closeTab(tab)
            return
        }
        guard let parent = tab.root.parent(of: leaf),
              case .split(let direction, var children) = parent.content else { return }

        leaf.allSessions().forEach { $0.terminate() }
        children.removeAll { $0 === leaf }
        if children.count == 1 {
            parent.content = children[0].content
        } else {
            parent.content = .split(direction, children)
        }
        self.focusedSessionID = tab.root.firstTerminal()?.id
        scheduleSave()
    }

    // MARK: Composer routing

    func sendToFocusedTerminal(_ text: String) {
        if let session = focusedSession {
            session.send(text: text)
            return
        }
        let tab = newTab()
        tab.primarySession?.send(text: text)
    }

    // MARK: Side panels

    func togglePanel(_ panel: SidePanel) {
        if activePanel == panel {
            activePanel = nil
            return
        }
        activePanel = panel
        if panel == .files,
           AppSettings.shared.followTerminalDirectory,
           let directory = focusedSession?.currentDirectory {
            panelFiles.navigate(to: URL(fileURLWithPath: directory))
        }
    }

    // MARK: Persistence

    func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func saveNow() {
        let snapshot = AppStateSnapshot(
            workspaces: workspaces.map { $0.snapshot() },
            selectedTabID: selectedTabID
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            NSLog("Failed to save workspace state: \(error.localizedDescription)")
        }
    }

    private func restore() -> Bool {
        guard let data = try? Data(contentsOf: stateURL),
              let snapshot = try? JSONDecoder().decode(AppStateSnapshot.self, from: data),
              !snapshot.workspaces.isEmpty else { return false }

        workspaces = snapshot.workspaces.map { Workspace(snapshot: $0) }
        let allTabs = workspaces.flatMap(\.tabs)
        guard !allTabs.isEmpty else { return false }

        let restoredSelection = snapshot.selectedTabID.flatMap { id in
            allTabs.first { $0.id == id }?.id
        }
        selectedTabID = restoredSelection ?? allTabs.first?.id
        focusedSessionID = selectedTab?.root.firstTerminal()?.id
        return true
    }

    func terminateAllSessions() {
        for workspace in workspaces {
            for tab in workspace.tabs {
                tab.root.allSessions().forEach { $0.terminate() }
            }
        }
    }

    var stateFileURL: URL { stateURL }
}
