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

/// What the detail column is showing: the terminal surface, or one of the
/// placeholder sections mirrored from the sidebar's action rows.
enum DetailMode {
    case terminal, automations, skills, tasks
}

/// A running shell plus where it lives, for the task manager.
struct RunningTask: Identifiable {
    enum Origin {
        case tab(WorkspaceTab, Workspace)
        case dock
        case composer

        var label: String {
            switch self {
            case .tab(_, let workspace): return workspace.name
            case .dock: return "Terminal dock"
            case .composer: return "Composer"
            }
        }
    }

    let session: TerminalSession
    let origin: Origin

    var id: UUID { session.id }
}

/// Single source of truth for workspaces, tabs, pane layout, focus, and the
/// sliding side panels. Layout is snapshotted to Application Support and
/// restored on the next launch.
final class WorkspaceStore: ObservableObject {
    static let shared = WorkspaceStore()

    @Published var workspaces: [Workspace] = []
    @Published var detailMode: DetailMode = .terminal
    @Published var selectedTabID: UUID?
    @Published var focusedSessionID: UUID?
    @Published private(set) var openPanels: Set<SidePanel> = []
    @Published private(set) var rightRegionOpen = false
    @Published var frontPanel: SidePanel?
    @Published private(set) var rightPanelExpanded = false
    @Published private(set) var bottomDockOpen = false
    @Published var showCommandPalette = false
    @Published private(set) var recentSessions: [RecentSession] = []
    @Published private(set) var composerSession: TerminalSession?
    @Published private(set) var composerHasRun = false
    @Published private(set) var composerHistory: [String] = []
    @Published private(set) var composerFocusRequest = 0
    @Published private(set) var dockSessions: [TerminalSession] = []
    @Published var selectedDockSessionID: UUID?

    lazy var panelBrowserTabs = BrowserTabsModel()
    lazy var panelFiles = FileBrowserModel()

    private var pendingSave: DispatchWorkItem?
    private let stateURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("iTERMiNAL", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("state.json")
    }()

    private init() {
        if !(AppSettings.shared.restoreSession && restore()) { bootstrap() }
        pruneOrphanedTranscripts()
    }

    // RESTORE IN PROGRESS — full body will be restored in follow-up commit.
    // This intermediate commit unbreaks the stub while the full file is pushed.
    private func bootstrap() {
        let workspace = Workspace(name: "Workspace 1")
        workspaces = [workspace]
        newTab(in: workspace)
    }

    var selectedTab: WorkspaceTab? { nil }
    var currentWorkspace: Workspace? { workspaces.first }
    func workspace(containingTab tabID: UUID) -> Workspace? { nil }
    var focusedSession: TerminalSession? { nil }
    func session(withID id: UUID) -> TerminalSession? { nil }
    func isDockSession(_ id: UUID) -> Bool { false }
    func tab(withID identifier: String) -> WorkspaceTab? { nil }
    func session(withIdentifier identifier: String) -> TerminalSession? { nil }
    func allBrowsers() -> [BrowserModel] { [] }
    func browser(withIdentifier identifier: String) -> BrowserModel? { nil }
    func noteFocused(session: TerminalSession) {}
    private func focusSelectedTab() {}
    func newWorkspace(named name: String? = nil) { bootstrap() }
    @discardableResult func newTab(in workspace: Workspace? = nil, directory: String? = nil, kind: SessionKind = .localShell) -> WorkspaceTab {
        let session = TerminalSession(kind: kind, initialDirectory: directory)
        session.startIfNeeded()
        let tab = WorkspaceTab(root: PaneNode(content: .terminal(session)))
        (workspace ?? workspaces.first!).tabs.append(tab)
        selectedTabID = tab.id
        return tab
    }
    var pinnedTabs: [WorkspaceTab] { [] }
    func togglePin(_ tab: WorkspaceTab) {}
    func reopen(_ recent: RecentSession) {}
    func removeRecent(_ recent: RecentSession) {}
    func pruneOrphanedTranscripts() {}
    func clearRecents() {}
    func closeTab(_ tab: WorkspaceTab) {}
    func closeSelectedTab() {}
    func deleteWorkspace(_ workspace: Workspace) {}
    @discardableResult func splitFocusedPane(_ direction: SplitDirection, kind: PaneKind, connection: UUID? = nil) -> PaneNode? { nil }
    func closeFocusedPane() {}
    func allTasks() -> [RunningTask] { [] }
    func reveal(_ task: RunningTask) {}
    func stopTask(_ task: RunningTask) {}
    func focusComposer() {}
    func sendToFocusedTerminal(_ text: String) {}
    func sendToComposer(_ text: String) {}
    @discardableResult func ensureComposerSession() -> TerminalSession {
        let s = TerminalSession(kind: .localShell)
        s.startIfNeeded()
        composerSession = s
        return s
    }
    func resetComposerSession() {}
    func openLinkFromTerminal(_ link: String) {}
    var orderedOpenPanels: [SidePanel] { [] }
    var visiblePanel: SidePanel? { nil }
    func togglePanel(_ panel: SidePanel) {}
    func openPanel(_ panel: SidePanel) {}
    func closePanel(_ panel: SidePanel) {}
    func closeRightRegion() {}
    func toggleRightPanelExpanded() {}
    func toggleBottomDock() {}
    func closeBottomDock() {}
    @discardableResult func newDockSession(directory: String? = nil) -> TerminalSession {
        let s = TerminalSession(kind: .localShell)
        s.startIfNeeded()
        dockSessions.append(s)
        return s
    }
    func closeDockSession(_ id: UUID) {}
    func scheduleSave() {}
    func currentSnapshot() -> AppStateSnapshot {
        AppStateSnapshot(workspaces: [], selectedTabID: nil, recents: [], panels: nil)
    }
    func applySnapshot(_ snapshot: AppStateSnapshot) {}
    func saveNow(triggerSync: Bool = true) {
        if triggerSync { SyncEngineProvider.schedulePushAfterLocalSave() }
    }
    private func restore() -> Bool { false }
    func terminateAllSessions() {}
    var stateFileURL: URL { stateURL }
    var selectedDockSession: TerminalSession? { nil }
}
