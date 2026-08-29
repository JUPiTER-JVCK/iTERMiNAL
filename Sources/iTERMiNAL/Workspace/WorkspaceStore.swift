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
    @Published var selectedTabID: UUID? {
        didSet {
            guard oldValue != selectedTabID else { return }
            if selectedTabID != nil { detailMode = .terminal }
            focusSelectedTab()
            scheduleSave()
            if let selectedTabID {
                EventBus.shared.publish(APIEvent("tab.selected", ["tab": selectedTabID.uuidString]))
            }
        }
    }
    @Published var focusedSessionID: UUID?
    /// Panels currently in the trailing region. A set rather than one
    /// optional, so opening Files no longer evicts the browser — every panel
    /// keeps its place until you close it yourself.
    @Published private(set) var openPanels: Set<SidePanel> = []
    /// Whether the trailing region is showing, tracked separately from what
    /// is in it: the region can be open and empty (offering the picker), and
    /// hiding it keeps its panels so reopening restores them where they were.
    @Published private(set) var rightRegionOpen = false
    /// Which open panel is in front when more than one shares the region.
    @Published var frontPanel: SidePanel?
    /// True while the trailing region is expanded over the main surface.
    @Published private(set) var rightPanelExpanded = false
    @Published private(set) var bottomDockOpen = false
    @Published var showCommandPalette = false
    /// Sessions the user closed, newest first, so they can be reopened.
    @Published private(set) var recentSessions: [RecentSession] = []

    /// The composer's own shell. Commands typed into the composer run here
    /// and nowhere else, so what you type can never land in the pane behind
    /// it. Created on first use — most sessions never touch it.
    @Published private(set) var composerSession: TerminalSession?
    /// True once the composer's shell has been given something to run, which
    /// is when its transcript is worth showing.
    @Published private(set) var composerHasRun = false
    /// Commands sent from the composer, oldest first, for arrow-key recall.
    /// In memory only and never written to the state file: composer input is
    /// as likely to contain a token as a `ls`, and none of it is worth
    /// keeping on disk.
    @Published private(set) var composerHistory: [String] = []
    /// Bumped when something — a menu command, a revealed task — asks the
    /// composer to take keyboard focus. The view watches the number rather
    /// than a Bool, so two requests in a row both land.
    @Published private(set) var composerFocusRequest = 0

    /// Terminals living in the bottom dock. Separate from tab panes — the
    /// dock is a scratch surface that survives switching tabs.
    @Published private(set) var dockSessions: [TerminalSession] = []
    @Published var selectedDockSessionID: UUID?

    /// Models backing the sliding side panels (distinct from panes that live
    /// inside a tab's split layout).
    lazy var panelBrowserTabs = BrowserTabsModel()
    lazy var panelFiles = FileBrowserModel()

    var selectedDockSession: TerminalSession? {
        guard let selectedDockSessionID else { return dockSessions.first }
        return dockSessions.first { $0.id == selectedDockSessionID } ?? dockSessions.first
    }

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
        // The dock's terminals take focus like any other, so they have to be
        // findable here or the composer would type into the wrong shell.
        if let session = dockSessions.first(where: { $0.id == id }) { return session }
        return composerSession?.id == id ? composerSession : nil
    }

    /// True when the id belongs to the bottom dock rather than a tab pane.
    func isDockSession(_ id: UUID) -> Bool {
        dockSessions.contains { $0.id == id }
    }

    // MARK: Lookups used by the scripting API

    /// Resolves a tab by UUID string or by its display name.
    func tab(withID identifier: String) -> WorkspaceTab? {
        let all = workspaces.flatMap(\.tabs)
        if let match = all.first(where: { $0.id.uuidString == identifier }) { return match }
        return all.first { $0.displayName == identifier }
    }

    func session(withIdentifier identifier: String) -> TerminalSession? {
        guard let uuid = UUID(uuidString: identifier) else {
            // Fall back to the primary session of a tab named this.
            return tab(withID: identifier)?.primarySession
        }
        return session(withID: uuid)
    }

    /// Every browser the API can address: panes inside tabs, plus the
    /// right panel's tabs, which carry ids of their own.
    func allBrowsers() -> [BrowserModel] {
        workspaces.flatMap { $0.tabs.flatMap { $0.root.allBrowsers() } } + panelBrowserTabs.tabs
    }

    func browser(withIdentifier identifier: String) -> BrowserModel? {
        allBrowsers().first { $0.id.uuidString == identifier }
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

    func newWorkspace(named name: String? = nil) {
        let resolved = (name?.isEmpty == false) ? name! : "Workspace \(workspaces.count + 1)"
        let workspace = Workspace(name: resolved)
        workspaces.append(workspace)
        EventBus.shared.publish(APIEvent("workspace.created", [
            "workspace": workspace.id.uuidString,
            "name": workspace.name,
        ]))
        newTab(in: workspace)
    }

    @discardableResult
    func newTab(
        in workspace: Workspace? = nil,
        directory: String? = nil,
        kind: SessionKind = .localShell
    ) -> WorkspaceTab {
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

        let session = TerminalSession(kind: kind, initialDirectory: directory)
        session.startIfNeeded()
        let tab = WorkspaceTab(root: PaneNode(content: .terminal(session)))
        target.tabs.append(tab)
        selectedTabID = tab.id
        focusedSessionID = session.id
        scheduleSave()
        EventBus.shared.publish(APIEvent("tab.created", [
            "tab": tab.id.uuidString,
            "workspace": target.id.uuidString,
            "workspaceName": target.name,
            "session": session.id.uuidString,
            "remote": kind.isRemote,
        ]))
        return tab
    }

    /// Pinned tabs across every workspace, newest activity first.
    var pinnedTabs: [WorkspaceTab] {
        workspaces.flatMap(\.tabs).filter(\.isPinned)
    }

    func togglePin(_ tab: WorkspaceTab) {
        tab.isPinned.toggle()
        scheduleSave()
    }

    /// Reopens a closed session in a new tab, restoring what was on it.
    func reopen(_ recent: RecentSession) {
        let kind: SessionKind = recent.connection
            .flatMap { UUID(uuidString: $0) }
            .map { SessionKind.remote($0) } ?? .localShell
        let tab = newTab(directory: recent.isRemote ? nil : recent.directory, kind: kind)
        if let transcript = TranscriptStore.load(for: recent.id),
           let session = tab.root.firstTerminal() {
            // The new shell has to be up before anything is written to the
            // display, or its own first prompt lands on top of the restored
            // text. This is a new process, so what is restored is a record of
            // the old one, not a resumed session.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                session.displayRestored(transcript)
            }
        }
        removeRecent(recent)
    }

    /// Drops a Recents entry and the transcript kept for it.
    func removeRecent(_ recent: RecentSession) {
        recentSessions.removeAll { $0.id == recent.id }
        TranscriptStore.remove(for: recent.id)
        scheduleSave()
    }

    func clearRecents() {
        recentSessions.removeAll()
        TranscriptStore.pruneAll(keeping: [])
        scheduleSave()
    }

    private func rememberClosed(_ tab: WorkspaceTab) {
        for session in tab.root.allSessions() {
            rememberClosed(session, title: tab.displayName)
        }
    }

    private func rememberClosed(_ session: TerminalSession, title: String) {
        let entry = RecentSession(
            id: session.id,
            title: title,
            directory: session.currentDirectory,
            connection: session.kind.connectionID?.uuidString,
            closedAt: Date()
        )
        // Capture before the shell is terminated: once the view is gone so is
        // its buffer.
        TranscriptStore.save(
            session.captureScrollback(maxBytes: TranscriptStore.maxBytes),
            for: session.id
        )
        recentSessions.removeAll { $0.id == entry.id }
        recentSessions.insert(entry, at: 0)
        if recentSessions.count > 20 {
            recentSessions.removeLast(recentSessions.count - 20)
        }
        // An entry pushed off the end takes its transcript with it.
        TranscriptStore.pruneAll(keeping: Set(recentSessions.map(\.id)))
    }

    func closeTab(_ tab: WorkspaceTab) {
        guard let workspace = workspace(containingTab: tab.id) else { return }
        rememberClosed(tab)
        tab.root.allSessions().forEach { $0.terminate() }
        workspace.tabs.removeAll { $0 === tab }
        EventBus.shared.publish(APIEvent("tab.closed", ["tab": tab.id.uuidString]))
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

    /// Splits the focused pane and returns the newly created node, so callers
    /// (notably the scripting API) can address exactly what they just made.
    @discardableResult
    func splitFocusedPane(
        _ direction: SplitDirection,
        kind: PaneKind,
        connection: UUID? = nil
    ) -> PaneNode? {
        // With nothing open, create a tab first and split that, so the caller
        // still gets back a pane of the kind they asked for.
        let tab = selectedTab ?? newTab()

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
            let sessionKind: SessionKind = connection.map { .remote($0) } ?? .localShell
            let session = TerminalSession(
                kind: sessionKind,
                initialDirectory: sessionKind.isRemote ? nil : focusedSession?.currentDirectory
            )
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
        EventBus.shared.publish(APIEvent("pane.split", [
            "tab": tab.id.uuidString,
            "direction": direction.rawValue,
        ]))
        return added
    }

    func closeFocusedPane() {
        // Focus may be in the dock, which owns no pane — closing the tab
        // because the user clicked into the dock would be destructive.
        if let focusedSessionID, isDockSession(focusedSessionID) {
            closeDockSession(focusedSessionID)
            return
        }
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
        EventBus.shared.publish(APIEvent("pane.closed", ["tab": tab.id.uuidString]))
    }

    // MARK: Task manager

    /// Every shell the app owns, wherever it lives — tab panes, the dock, and
    /// the composer. Exited sessions are included: knowing something died is
    /// the point of a task list.
    func allTasks() -> [RunningTask] {
        var tasks: [RunningTask] = []
        for workspace in workspaces {
            for tab in workspace.tabs {
                for session in tab.root.allSessions() {
                    tasks.append(RunningTask(session: session, origin: .tab(tab, workspace)))
                }
            }
        }
        tasks.append(contentsOf: dockSessions.map { RunningTask(session: $0, origin: .dock) })
        if let composerSession {
            tasks.append(RunningTask(session: composerSession, origin: .composer))
        }
        // Live shells first, then most recently active.
        return tasks.sorted {
            if $0.session.isRunning != $1.session.isRunning { return $0.session.isRunning }
            return $0.session.lastActivityAt > $1.session.lastActivityAt
        }
    }

    /// Brings a task's home surface to the front and focuses its shell.
    func reveal(_ task: RunningTask) {
        switch task.origin {
        case .tab(let tab, _):
            detailMode = .terminal
            selectedTabID = tab.id
            focusedSessionID = task.session.id
        case .dock:
            detailMode = .terminal
            if !bottomDockOpen { toggleBottomDock() }
            selectedDockSessionID = task.session.id
        case .composer:
            focusComposer()
        }
    }

    /// Ends a task and takes its surface away with it.
    ///
    /// Stopping used to call `terminate()` alone, which left a dead pane
    /// sitting in the workspace and put nothing in Recents — the shell was
    /// gone but every trace of it stayed exactly where it was. Stopping now
    /// means the same thing closing does: the surface goes, and the session
    /// becomes a Recents entry you can reopen.
    func stopTask(_ task: RunningTask) {
        let session = task.session
        switch task.origin {
        case .tab(let tab, _):
            rememberClosed(session, title: tab.displayName)
            removePane(hosting: session, in: tab)
        case .dock:
            rememberClosed(session, title: session.displayTitle)
            closeDockSession(session.id)
        case .composer:
            rememberClosed(session, title: session.displayTitle)
            resetComposerSession()
        }
        scheduleSave()
    }

    /// Drops the leaf holding `session`, collapsing the split around it — and
    /// closing the whole tab when that leaf was all the tab had.
    private func removePane(hosting session: TerminalSession, in tab: WorkspaceTab) {
        guard let leaf = tab.root.leaf(containingSessionID: session.id) else {
            session.terminate()
            return
        }
        if leaf === tab.root {
            // rememberClosed already ran for this session; closeTab would add
            // it a second time, so terminate and drop the tab directly.
            guard let workspace = workspace(containingTab: tab.id) else { return }
            session.terminate()
            workspace.tabs.removeAll { $0 === tab }
            EventBus.shared.publish(APIEvent("tab.closed", ["tab": tab.id.uuidString]))
            if selectedTabID == tab.id {
                selectedTabID = workspace.tabs.last?.id ?? workspaces.flatMap(\.tabs).last?.id
            }
            return
        }
        guard let parent = tab.root.parent(of: leaf),
              case .split(let direction, var children) = parent.content else {
            session.terminate()
            return
        }
        session.terminate()
        children.removeAll { $0 === leaf }
        if children.count == 1 {
            parent.content = children[0].content
        } else {
            parent.content = .split(direction, children)
        }
        if focusedSessionID == session.id {
            focusedSessionID = tab.root.firstTerminal()?.id
        }
        EventBus.shared.publish(APIEvent("pane.closed", ["tab": tab.id.uuidString]))
    }

    /// Brings the composer forward and puts the caret in it — un-hiding and
    /// un-collapsing first, since either would otherwise make this silently
    /// do nothing.
    func focusComposer() {
        detailMode = .terminal
        AppSettings.shared.composerEnabled = true
        AppSettings.shared.composerCollapsed = false
        composerFocusRequest += 1
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

    /// Runs a command in the composer's own shell, starting it if this is the
    /// first one. Deliberately does not touch `focusedSession`.
    func sendToComposer(_ text: String) {
        let session = ensureComposerSession()
        session.send(text: text)
        if !composerHasRun { composerHasRun = true }
        recordComposerCommand(text)
    }

    /// Keeps the recall list free of adjacent duplicates and bounded, so a
    /// command run in a loop doesn't crowd out everything before it.
    private func recordComposerCommand(_ text: String) {
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, composerHistory.last != command else { return }
        composerHistory.append(command)
        if composerHistory.count > 100 {
            composerHistory.removeFirst(composerHistory.count - 100)
        }
    }

    @discardableResult
    func ensureComposerSession() -> TerminalSession {
        if let composerSession { return composerSession }
        let shell = AppSettings.shared.composerShell
        let session = TerminalSession(
            kind: .localShell,
            initialDirectory: focusedSession?.currentDirectory,
            shellOverride: shell.isEmpty ? nil : shell
        )
        session.startIfNeeded()
        composerSession = session
        EventBus.shared.publish(APIEvent("composer.session.created", ["session": session.id.uuidString]))
        return session
    }

    /// Ends the composer's shell and clears its transcript.
    func resetComposerSession() {
        composerSession?.terminate()
        composerSession = nil
        composerHasRun = false
    }

    /// Opens a link clicked in a terminal inside the app's browser — an
    /// existing browser pane in this tab if there is one, otherwise the
    /// sliding panel.
    func openLinkFromTerminal(_ link: String) {
        if let browser = selectedTab?.root.allBrowsers().first {
            browser.navigate(to: link) { _ in }
            return
        }
        openPanel(.browser)
        // A tabbed browser should open a link beside the current page, not
        // navigate away from it.
        panelBrowserTabs.newTab(url: link)
    }

    // MARK: Side panels

    /// Open panels in a stable order, so the tab strip doesn't reshuffle.
    var orderedOpenPanels: [SidePanel] {
        SidePanel.allCases.filter { openPanels.contains($0) }
    }

    /// The panel the trailing region is currently showing.
    var visiblePanel: SidePanel? {
        if let frontPanel, openPanels.contains(frontPanel) { return frontPanel }
        return orderedOpenPanels.first
    }

    /// Shortcut and top-strip semantics: turning a panel off that was the
    /// only one also puts the region away, so the toggle stays predictable.
    func togglePanel(_ panel: SidePanel) {
        if rightRegionOpen, openPanels.contains(panel) {
            withAnimation(Motion.panel) {
                _ = openPanels.remove(panel)
                if frontPanel == panel { frontPanel = orderedOpenPanels.first }
                if openPanels.isEmpty {
                    rightRegionOpen = false
                    rightPanelExpanded = false
                }
            }
        } else {
            openPanel(panel)
        }
        scheduleSave()
    }

    func openPanel(_ panel: SidePanel) {
        withAnimation(Motion.panel) {
            _ = openPanels.insert(panel)
            frontPanel = panel
            rightRegionOpen = true
        }
        if panel == .browser, panelBrowserTabs.tabs.isEmpty {
            panelBrowserTabs.newTab()
        }
        if panel == .files,
           AppSettings.shared.followTerminalDirectory,
           !panelFiles.isRemote,
           let directory = focusedSession?.currentDirectory {
            panelFiles.navigate(to: directory)
        }
        scheduleSave()
    }

    /// Closing a panel from its own tab leaves the region up, so emptying it
    /// lands on the picker rather than collapsing the layout out from under
    /// the pointer that just clicked.
    func closePanel(_ panel: SidePanel) {
        withAnimation(Motion.panel) {
            _ = openPanels.remove(panel)
            if frontPanel == panel { frontPanel = orderedOpenPanels.first }
            // Nothing left to expand over the main surface.
            if openPanels.isEmpty { rightPanelExpanded = false }
        }
        scheduleSave()
    }

    /// Puts the whole region away, keeping its panels for next time.
    func closeRightRegion() {
        withAnimation(Motion.panel) {
            rightRegionOpen = false
            rightPanelExpanded = false
        }
        scheduleSave()
    }

    func toggleRightPanelExpanded() {
        withAnimation(Motion.panel) { rightPanelExpanded.toggle() }
    }

    // MARK: Bottom terminal dock

    func toggleBottomDock() {
        withAnimation(Motion.panel) { bottomDockOpen.toggle() }
        // Opening an empty dock with nothing in it would just show a blank
        // strip, so give it a shell.
        if bottomDockOpen, dockSessions.isEmpty {
            _ = newDockSession()
        }
        scheduleSave()
    }

    func closeBottomDock() {
        withAnimation(Motion.panel) { bottomDockOpen = false }
    }

    @discardableResult
    func newDockSession(directory: String? = nil) -> TerminalSession {
        let session = TerminalSession(
            kind: .localShell,
            initialDirectory: directory ?? focusedSession?.currentDirectory
        )
        session.startIfNeeded()
        dockSessions.append(session)
        selectedDockSessionID = session.id
        EventBus.shared.publish(APIEvent("dock.session.created", ["session": session.id.uuidString]))
        scheduleSave()
        return session
    }

    func closeDockSession(_ id: UUID) {
        guard let index = dockSessions.firstIndex(where: { $0.id == id }) else { return }
        let session = dockSessions.remove(at: index)
        session.terminate()
        if selectedDockSessionID == id {
            selectedDockSessionID = dockSessions.first?.id
        }
        EventBus.shared.publish(APIEvent("dock.session.closed", ["session": id.uuidString]))
        // An empty dock is just a blank strip; fold it away.
        if dockSessions.isEmpty {
            withAnimation(Motion.panel) { bottomDockOpen = false }
        }
        scheduleSave()
    }

    // MARK: Persistence

    func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    /// The current layout as a persistable value — used both for autosave and
    /// for exporting a portable snapshot.
    func currentSnapshot() -> AppStateSnapshot {
        AppStateSnapshot(
            workspaces: workspaces.map { $0.snapshot() },
            selectedTabID: selectedTabID,
            recents: recentSessions,
            panels: panelSnapshot()
        )
    }

    private func panelSnapshot() -> PanelStateSnapshot {
        let settings = AppSettings.shared
        return PanelStateSnapshot(
            openPanels: orderedOpenPanels.map(\.rawValue),
            frontPanel: frontPanel?.rawValue,
            rightRegionOpen: rightRegionOpen,
            bottomDockOpen: bottomDockOpen,
            dockDirectories: dockSessions.map(\.currentDirectory),
            rightPanelWidth: settings.rightPanelWidth,
            bottomDockHeight: settings.bottomDockHeight
        )
    }

    /// Puts the surrounding layout back. Dock terminals are relaunched in the
    /// directories the old ones were sitting in — the processes themselves
    /// died with the app.
    private func applyPanelSnapshot(_ snapshot: PanelStateSnapshot?) {
        guard let snapshot else { return }
        openPanels = Set(snapshot.openPanels.compactMap(SidePanel.init(rawValue:)))
        frontPanel = snapshot.frontPanel.flatMap(SidePanel.init(rawValue:))
        rightRegionOpen = snapshot.rightRegionOpen && !openPanels.isEmpty
        if openPanels.contains(.browser), panelBrowserTabs.tabs.isEmpty {
            panelBrowserTabs.newTab()
        }

        let settings = AppSettings.shared
        if let width = snapshot.rightPanelWidth { settings.rightPanelWidth = width }
        if let height = snapshot.bottomDockHeight { settings.bottomDockHeight = height }

        // Importing a snapshot runs terminateAllSessions() first, which kills
        // the dock's shells but leaves them in the array. Clear it here or the
        // relaunched sessions stack on top of dead ones and the selection
        // lands on a terminated terminal.
        dockSessions.forEach { $0.terminate() }
        dockSessions.removeAll()
        selectedDockSessionID = nil

        for directory in snapshot.dockDirectories {
            _ = newDockSession(directory: directory)
        }
        bottomDockOpen = snapshot.bottomDockOpen && !dockSessions.isEmpty
        selectedDockSessionID = dockSessions.first?.id
    }

    /// Replaces every workspace with the contents of a snapshot, shutting down
    /// the processes that belonged to the outgoing layout.
    func applySnapshot(_ snapshot: AppStateSnapshot) {
        terminateAllSessions()
        workspaces = snapshot.workspaces.map { Workspace(snapshot: $0) }
        recentSessions = snapshot.recents ?? []
        if workspaces.isEmpty {
            bootstrap()
            return
        }
        applyPanelSnapshot(snapshot.panels)
        let allTabs = workspaces.flatMap(\.tabs)
        selectedTabID = snapshot.selectedTabID.flatMap { id in
            allTabs.first { $0.id == id }?.id
        } ?? allTabs.first?.id
        focusedSessionID = selectedTab?.root.firstTerminal()?.id
        saveNow()
    }

    func saveNow() {
        let snapshot = currentSnapshot()
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
        recentSessions = snapshot.recents ?? []
        let allTabs = workspaces.flatMap(\.tabs)
        guard !allTabs.isEmpty else { return false }

        let restoredSelection = snapshot.selectedTabID.flatMap { id in
            allTabs.first { $0.id == id }?.id
        }
        selectedTabID = restoredSelection ?? allTabs.first?.id
        focusedSessionID = selectedTab?.root.firstTerminal()?.id
        applyPanelSnapshot(snapshot.panels)
        return true
    }

    func terminateAllSessions() {
        for workspace in workspaces {
            for tab in workspace.tabs {
                tab.root.allSessions().forEach { $0.terminate() }
            }
        }
        dockSessions.forEach { $0.terminate() }
        composerSession?.terminate()
    }

    var stateFileURL: URL { stateURL }
}
