import SwiftUI
import Foundation

enum SidePanel: String, CaseIterable, Identifiable {
    case browser, files, notes, superfile, btop
    var id: String { rawValue }

    /// The bundled program this panel runs, for the two that are one.
    /// Persisted by raw value like the others, so a layout saved with btop
    /// open restores with it — and an older build, which has no such case,
    /// simply drops it.
    var tool: TerminalTool? {
        switch self {
        case .superfile: return .superfile
        case .btop: return .btop
        case .browser, .files, .notes: return nil
        }
    }

    var isTool: Bool { tool != nil }

    var title: String {
        switch self {
        case .browser: return "Browser"
        case .files: return "Files"
        case .notes: return "Notes"
        case .superfile: return TerminalTool.superfile.title
        case .btop: return TerminalTool.btop.title
        }
    }
    var icon: String {
        switch self {
        case .browser: return "globe"
        case .files: return "folder"
        case .notes: return "note.text"
        case .superfile: return TerminalTool.superfile.icon
        case .btop: return TerminalTool.btop.icon
        }
    }

    /// Kept beside the case rather than worked out at the call site. The panel
    /// picker used a two-way ternary, which silently labelled any third panel
    /// with the Files shortcut.
    var shortcutHint: String {
        switch self {
        case .browser: return "⌥⌘B"
        case .files: return "⌥⌘F"
        case .notes: return "⌥⌘N"
        case .superfile: return "⌥⌘S"
        case .btop: return "⌥⌘P"
        }
    }

    /// Width the panel is given at least while it is in front.
    ///
    /// btop and superfile draw a full-screen interface and fall back to a
    /// "too small" message rather than a cramped one — and neither project
    /// publishes the size it needs, so this is a floor chosen to give them
    /// room at the default font, not a column count. The stored panel width is
    /// left alone: bring Notes back to the front and it returns to whatever
    /// the user dragged it to.
    var minimumWidth: Double? {
        isTool ? 640 : nil
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
        /// A bundled tool running in its side panel.
        case panel(SidePanel)

        var label: String {
            switch self {
            case .tab(_, let workspace): return workspace.name
            case .dock: return "Terminal dock"
            case .composer: return "Composer"
            case .panel(let panel): return "\(panel.title) panel"
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
    /// Looking at a pane dismisses its attention mark, however focus got
    /// there. Doing it here rather than at each call site covers the paths
    /// that assign this directly — closing a pane, closing a session,
    /// revealing a task — which an observer of this property used to catch and
    /// nothing else did.
    @Published var focusedSessionID: UUID? {
        didSet {
            guard oldValue != focusedSessionID else { return }
            if let focusedSessionID, let session = session(withID: focusedSessionID) {
                session.clearAttention()
            }
        }
    }
    /// Panels currently in the trailing region. A set rather than one
    /// optional, so opening Files no longer evicts the browser — every panel
    /// keeps its place until you close it yourself.
    ///
    /// A bundled tool whose panel leaves this set is stopped here, and only
    /// here. `togglePanel`, `closePanel` and a snapshot import each take panels
    /// out their own way; putting the stop in the didSet means none of them
    /// can forget to, and a btop nobody can see is never left polling the
    /// machine. Hiding the whole region does not touch this set, so tools keep
    /// running while it is merely put away.
    @Published private(set) var openPanels: Set<SidePanel> = [] {
        didSet {
            for panel in oldValue.subtracting(openPanels) {
                if let tool = panel.tool { stopToolSession(tool) }
            }
        }
    }
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
    /// How many closed sessions the Recents list keeps. An entry pushed off
    /// the end takes its transcript with it, so anything that rebuilds this
    /// list has to respect the same cap.
    static let maxRecentSessions = 20
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

    /// Built on first use like the panels above, but through an explicit
    /// backing store rather than `lazy` so quitting can flush a pending write
    /// without *creating* the model — reading a `lazy var` to ask whether it
    /// exists is what would create it.
    private var notesModel: NotesModel?
    var panelNotes: NotesModel {
        if let notesModel { return notesModel }
        let model = NotesModel()
        notesModel = model
        return model
    }

    /// Writes any note still inside its debounce window. No-op when the panel
    /// was never opened.
    func flushNotes() {
        notesModel?.saveNow()
    }

    // MARK: Bundled tools

    /// The running copy of each bundled tool, one per panel.
    @Published private(set) var toolSessions: [TerminalTool: TerminalSession] = [:]

    /// Starts `tool` if it is not already running, and returns its session.
    ///
    /// Idempotent, and called from two places on purpose: `openPanel`, for the
    /// click, and the panel's own `.onAppear`, for a panel restored at launch.
    /// Starting restored tools there rather than during restore is what keeps
    /// a btop from launching behind a region the user left hidden.
    ///
    /// A session that has exited is returned as is, not replaced: the panel
    /// shows why it stopped and offers Restart, which is more useful than a
    /// fresh copy appearing as though nothing happened.
    @discardableResult
    func ensureToolSession(_ tool: TerminalTool) -> TerminalSession {
        if let existing = toolSessions[tool] { return existing }
        // superfile opens where the user is working — but only a local
        // directory means anything to it, not a remote session's path.
        let directory: String?
        if tool == .superfile, let focused = focusedSession, !focused.isRemote, !focused.kind.isTool {
            directory = focused.currentDirectory
        } else {
            directory = nil
        }
        let session = TerminalSession(kind: .tool(tool), initialDirectory: directory)
        session.startIfNeeded()
        toolSessions[tool] = session
        EventBus.shared.publish(APIEvent("tool.started", [
            "tool": tool.rawValue,
            "session": session.id.uuidString,
        ]))
        return session
    }

    private func stopToolSession(_ tool: TerminalTool) {
        guard let session = toolSessions.removeValue(forKey: tool) else { return }
        session.terminate()
        if focusedSessionID == session.id {
            focusedSessionID = selectedTab?.root.firstTerminal()?.id
        }
        EventBus.shared.publish(APIEvent("tool.stopped", ["tool": tool.rawValue]))
    }

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
        // Covers the launch that skipped restore entirely: Recents is empty,
        // so every transcript on disk is orphaned.
        pruneOrphanedTranscripts()
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
        // Findable so focus and attention work in a tool's panel like
        // anywhere else. What must not follow focus there is the composer —
        // see `composerDestination`.
        if let session = toolSessions.values.first(where: { $0.id == id }) { return session }
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
            focusedSessionID = session.id   // didSet dismisses the mark
        } else {
            // Already focused, so the didSet will not fire — but clicking back
            // into a pane still dismisses its mark.
            session.clearAttention()
        }
    }

    private func focusSelectedTab() {
        guard let tab = selectedTab else { return }
        let sessions = tab.root.allSessions()
        if let focusedSessionID, let session = sessions.first(where: { $0.id == focusedSessionID }) {
            session.clearAttention()   // id unchanged, so the didSet stays quiet
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
            // Written before the shell starts, not after a delay. A timer was
            // a race in both directions: a local shell has already drawn its
            // prompt within a few hundred milliseconds, so the restore landed
            // on top of it, and a slow one reversed the order again. Sessions
            // start lazily when their view appears, so writing here puts the
            // record in the buffer first and the new prompt necessarily
            // follows it.
            session.displayRestored(transcript)
        }
        removeRecent(recent)
    }

    /// Drops a Recents entry and the transcript kept for it.
    func removeRecent(_ recent: RecentSession) {
        recentSessions.removeAll { $0.id == recent.id }
        TranscriptStore.remove(for: recent.id)
        scheduleSave()
    }

    /// Drops transcripts with no Recents entry left to belong to.
    ///
    /// Closing a session prunes as it goes, but that is not the only way the
    /// list changes: importing an archive replaces it wholesale, and a launch
    /// that skips restore starts from an empty one. Without a sweep on those
    /// paths, transcripts for entries the user can no longer see would sit on
    /// disk indefinitely — which for terminal output is the one outcome worth
    /// designing against.
    func pruneOrphanedTranscripts() {
        TranscriptStore.pruneAll(keeping: Set(recentSessions.map(\.id)))
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
        if recentSessions.count > Self.maxRecentSessions {
            recentSessions.removeLast(recentSessions.count - Self.maxRecentSessions)
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
        // The same trap for a bundled tool: its session lives in a side panel,
        // not the tab, so the fallback below would read "focus is nowhere in
        // this tab" and close the whole tab — ⇧⌘W in btop killing the shell
        // beside it. Close the thing that has focus instead.
        if let focusedSessionID,
           let tool = toolSessions.first(where: { $0.value.id == focusedSessionID })?.key,
           let panel = SidePanel.allCases.first(where: { $0.tool == tool }) {
            closePanel(panel)
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
        // In SidePanel order, so the list does not reshuffle between reads of
        // a dictionary.
        for panel in SidePanel.allCases {
            if let tool = panel.tool, let session = toolSessions[tool] {
                tasks.append(RunningTask(session: session, origin: .panel(panel)))
            }
        }
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
        case .panel(let panel):
            detailMode = .terminal
            openPanel(panel)
            focusedSessionID = task.session.id
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
        case .panel(let panel):
            // Stopping means what closing means here too: the panel goes, and
            // openPanels' didSet ends the process. Not filed under Recents —
            // that list is shells to reopen, and a tool reopens from its icon.
            closePanel(panel)
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

    /// Where a composer command will run right now.
    ///
    /// Read by the composer's chip row as well as by `sendFromComposer`, so
    /// what the composer says and what it does cannot disagree — which is
    /// exactly how they used to.
    enum ComposerDestination {
        /// A terminal that already exists: a tab pane or a dock tab.
        case terminal(TerminalSession)
        /// The composer's private shell, started on first use.
        case ownShell
    }

    var composerDestination: ComposerDestination {
        guard AppSettings.shared.composerTarget == .activeTerminal else { return .ownShell }
        // `focusedSession` falls back to the selected tab's first terminal, so
        // this still resolves when nothing has been clicked into yet — the
        // visible terminal is the one the user means. It also resolves dock
        // tabs, which take focus like any other terminal.
        guard let session = focusedSession else { return .ownShell }
        // Never into btop or superfile. They are findable for focus, but a
        // command typed into the composer is meant for a shell: sent to a
        // full-screen tool it becomes keystrokes — `ls⏎` selects and opens
        // things. With one of them focused, the composer types into the tab
        // behind it instead, and its chip says so.
        if session.kind.isTool {
            if let pane = selectedTab?.root.firstTerminal() { return .terminal(pane) }
            return .ownShell
        }
        return .terminal(session)
    }

    /// Runs a command typed in the composer, in whatever it is pointed at.
    func sendFromComposer(_ text: String) {
        switch composerDestination {
        case .terminal(let session):
            session.send(text: text)
        case .ownShell:
            ensureComposerSession().send(text: text)
            // Gates the inline transcript, so it only appears when there is a
            // composer shell whose output has nowhere else to go.
            if !composerHasRun { composerHasRun = true }
        }
        recordComposerCommand(text)
    }

    /// Keeps the recall list free of adjacent duplicates and bounded, so a
    /// command run in a loop doesn't crowd out everything before it.
    ///
    /// Internal rather than private because `@ai …` lines belong in recall too
    /// and never reach `sendFromComposer` — they go to the assistant, not the
    /// shell. One extra caller here is what that needs; a second copy of this
    /// list in the view was not.
    func recordComposerCommand(_ text: String) {
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
        // Selecting a tool's panel is what starts it.
        if let tool = panel.tool {
            ensureToolSession(tool)
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

    /// Opens a dock terminal.
    ///
    /// The kind is a parameter rather than always `.localShell`: a dock tab is
    /// a terminal like any other and there is no reason it cannot be a remote
    /// host. Inheriting the focused session's directory only makes sense for a
    /// local shell — a remote one starts wherever the connection says.
    @discardableResult
    func newDockSession(
        kind: SessionKind = .localShell,
        directory: String? = nil
    ) -> TerminalSession {
        let inherited = kind.isRemote ? nil : focusedSession?.currentDirectory
        let session = TerminalSession(
            kind: kind,
            initialDirectory: directory ?? inherited
        )
        session.startIfNeeded()
        dockSessions.append(session)
        selectedDockSessionID = session.id
        var payload = ["session": session.id.uuidString]
        if let connectionID = kind.connectionID {
            payload["connection"] = connectionID.uuidString
        }
        EventBus.shared.publish(APIEvent("dock.session.created", payload))
        scheduleSave()
        return session
    }

    /// Shells running in a tab pane, which could be moved into the dock.
    ///
    /// Exited ones are left out: the point of moving a session down here is to
    /// keep watching something that is still going.
    func paneSessionsMovableToDock() -> [TerminalSession] {
        workspaces
            .flatMap(\.tabs)
            .flatMap { $0.root.allSessions() }
            .filter(\.isRunning)
    }

    /// Takes a running shell out of its pane and puts it in the dock, so it
    /// stays visible while the tab above it gets used for something else.
    ///
    /// The session moves rather than being mirrored: its terminal is a live
    /// AppKit view and cannot be in two places at once. Nothing is terminated
    /// — that is the entire point — so this deliberately does not go through
    /// `closeTab`, which would kill the shell and file it under recents.
    func moveSessionToDock(_ sessionID: UUID) {
        guard !isDockSession(sessionID), composerSession?.id != sessionID else { return }
        guard let location = paneLocation(ofSessionID: sessionID),
              case .terminal(let session) = location.leaf.content else { return }
        let workspace = location.workspace
        let tab = location.tab
        let leaf = location.leaf

        if leaf === tab.root {
            // The shell was the whole tab, so the tab goes with it. Same
            // outcome as closing that pane, except the shell lives on.
            workspace.tabs.removeAll { $0 === tab }
            EventBus.shared.publish(APIEvent("tab.closed", ["tab": tab.id.uuidString]))
            if selectedTabID == tab.id {
                selectedTabID = workspace.tabs.last?.id ?? workspaces.flatMap(\.tabs).last?.id
            }
        } else if let parent = tab.root.parent(of: leaf),
                  case .split(let direction, var children) = parent.content {
            children.removeAll { $0 === leaf }
            if children.count == 1 {
                parent.content = children[0].content
            } else {
                parent.content = .split(direction, children)
            }
        } else {
            // A leaf that is neither the root nor a child of a split is not a
            // shape the tree can produce; bailing out beats detaching a
            // session with nowhere to put it back.
            return
        }

        dockSessions.append(session)
        selectedDockSessionID = session.id
        // Set directly rather than through toggleBottomDock(), which opens an
        // empty dock by making a new shell — there is already one here.
        if !bottomDockOpen {
            withAnimation(Motion.panel) { bottomDockOpen = true }
        }
        EventBus.shared.publish(APIEvent("dock.session.moved", ["session": session.id.uuidString]))
        scheduleSave()
    }

    /// Which workspace, tab and leaf hold a session, if a tab pane does.
    private func paneLocation(
        ofSessionID id: UUID
    ) -> (workspace: Workspace, tab: WorkspaceTab, leaf: PaneNode)? {
        for workspace in workspaces {
            for tab in workspace.tabs {
                if let leaf = tab.root.leaf(containingSessionID: id) {
                    return (workspace, tab, leaf)
                }
            }
        }
        return nil
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
            dockTabs: dockSessions.map {
                DockTabSnapshot(
                    directory: $0.currentDirectory,
                    connectionID: $0.kind.connectionID
                )
            },
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

        // `dockTabs` carries the connection each tab reopens; `dockDirectories`
        // is the older shape and is all a state file written before dock tabs
        // could be remote has.
        if let tabs = snapshot.dockTabs {
            let known = Set(AppSettings.shared.sshConnections.map(\.id))
            for tab in tabs {
                // A connection deleted since the snapshot cannot be reopened.
                // Falling back to a local shell beats a tab whose only
                // behaviour is to fail to start.
                let kind: SessionKind
                if let connectionID = tab.connectionID, known.contains(connectionID) {
                    kind = .remote(connectionID)
                } else {
                    kind = .localShell
                }
                _ = newDockSession(kind: kind, directory: tab.directory)
            }
        } else {
            for directory in snapshot.dockDirectories {
                _ = newDockSession(directory: directory)
            }
        }
        bottomDockOpen = snapshot.bottomDockOpen && !dockSessions.isEmpty
        selectedDockSessionID = dockSessions.first?.id
    }

    /// Replaces every workspace with the contents of a snapshot, shutting down
    /// the processes that belonged to the outgoing layout.
    ///
    /// This is the Import path and it is destructive by design — the user
    /// clicked a button and the sheet says so. Nothing else in the app calls
    /// it, and nothing should: the sibling that existed for a background sync
    /// to apply a remote layout went away with CloudKit, along with the
    /// live-session guard it needed to avoid killing shells mid-build.
    func applySnapshot(_ snapshot: AppStateSnapshot) {
        terminateAllSessions()
        workspaces = snapshot.workspaces.map { Workspace(snapshot: $0) }
        recentSessions = snapshot.recents ?? []
        pruneOrphanedTranscripts()
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
        // A queued debounced save is redundant once we save here, and letting
        // it fire later is worse than redundant during an import: adopting a
        // snapshot rebuilds the dock, each dock session calls scheduleSave,
        // and that work item lands a second later on top of what was just
        // written.
        pendingSave?.cancel()
        pendingSave = nil
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
        pruneOrphanedTranscripts()
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
        // Cleared as well as stopped: this also runs before an import, and a
        // tool panel that survives the import should start a fresh copy when
        // it next appears, not show the one the import just killed.
        toolSessions.values.forEach { $0.terminate() }
        toolSessions.removeAll()
    }

    var stateFileURL: URL { stateURL }
}
