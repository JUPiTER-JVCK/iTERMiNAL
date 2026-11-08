import SwiftUI
import AppKit
import Foundation

enum SidePanel: String, CaseIterable, Identifiable {
    case browser, files, notes, superfile, btop, http
    var id: String { rawValue }

    /// The bundled program this panel runs, for the two that are one.
    /// Persisted by raw value like the others, so a layout saved with btop
    /// open restores with it — and an older build, which has no such case,
    /// simply drops it.
    var tool: TerminalTool? {
        switch self {
        case .superfile: return .superfile
        case .btop: return .btop
        case .browser, .files, .notes, .http: return nil
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
        case .http: return "HTTP Client"
        }
    }
    var icon: String {
        switch self {
        case .browser: return "globe"
        case .files: return "folder"
        case .notes: return "note.text"
        case .superfile: return TerminalTool.superfile.icon
        case .btop: return TerminalTool.btop.icon
        case .http: return "arrow.up.arrow.down"
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
        case .http: return "⌥⌘R"
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

    /// The least this panel is given as one tile among several, header
    /// included. The heights are a first guess at what each can be used in and
    /// are meant to be tuned by eye; the widths for the tools are the floor
    /// above, so a tool in a column still raises the region to 640.
    ///
    /// The HTTP client has its own history list and builder side by side
    /// inside it, which is why it is asked for a little more width than the
    /// rest.
    var dockMinimum: DockSize {
        switch self {
        case .browser: return DockSize(width: 280, height: 220)
        case .files: return DockSize(width: 280, height: 180)
        case .notes: return DockSize(width: 280, height: 160)
        case .http: return DockSize(width: 360, height: 340)
        case .superfile, .btop: return DockSize(width: minimumWidth ?? 640, height: 360)
        }
    }

    /// What the layout needs to know about every panel, keyed the way the
    /// layout names them.
    static let dockMetrics = DockMetrics(
        minimums: Dictionary(uniqueKeysWithValues: SidePanel.allCases.map { ($0.rawValue, $0.dockMinimum) })
    )
}

/// How one panel sits in the trailing region, as the Move and Fill menu offers
/// it: arranged with the others, filling the region, or filling the window.
enum DockArrangement: Equatable {
    case tiled, fillRegion, fillWindow
}

/// What the detail column is showing: the terminal surface, or one of the
/// placeholder sections mirrored from the sidebar's action rows.
enum DetailMode {
    case terminal, automations, skills, tasks, cheatsheet
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
            if let selectedTabID, let space = workspace(containingTab: selectedTabID) {
                lastWorkspaceID = space.id
            }
            focusSelectedTab()
            scheduleSave()
            if let selectedTabID {
                EventBus.shared.publish(APIEvent("tab.selected", ["tab": selectedTabID.uuidString]))
            }
        }
    }
    /// The Space the person was last in. With no tab selected — on Home — no
    /// tab says which Space is current, and falling back to the first would
    /// make a new tab opened from Home land in Space 1 whichever Space they
    /// came from. Not persisted: restoring the selection sets it again.
    private var lastWorkspaceID: UUID?
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
    /// How the panels in the trailing region are arranged: a tree of splits
    /// whose leaves are panels (see `DockLayout`). Every panel keeps its place
    /// until you close it yourself, so opening Files does not evict the browser.
    ///
    /// Which panels are open is read off this tree (`openPanels`), so the two
    /// cannot disagree. Changes go through `setDockLayout`, which puts the tree
    /// back in normal form and saves.
    ///
    /// A bundled tool whose panel leaves the tree is stopped here, and only
    /// here. Closing, moving a panel out and a snapshot import each take panels
    /// away their own way; putting the stop in the didSet means none of them
    /// can forget to, and a btop nobody can see is never left polling the
    /// machine. Hiding the whole region does not touch the tree, so tools keep
    /// running while it is merely put away.
    @Published private(set) var dockLayout: DockNode? = nil {
        didSet {
            let before = Set(oldValue?.modules ?? [])
            let after = Set(dockLayout?.modules ?? [])
            for id in before.subtracting(after) {
                if let tool = SidePanel(rawValue: id)?.tool { stopToolSession(tool) }
            }
        }
    }

    /// Panels currently in the trailing region, however they are arranged.
    var openPanels: Set<SidePanel> {
        Set(panelsInReadingOrder)
    }

    /// The panel standing alone in the region while the others are set aside
    /// (their models and any running tool stay alive, as when a tab strip
    /// switched between them), or nil while they are all arranged side by
    /// side. Whether it also covers the terminal is `rightPanelExpanded`.
    @Published private(set) var dockFill: SidePanel?

    /// How big the region was last laid out. Written by the region as it
    /// resizes and only read when a panel is opened, to choose which side of
    /// the focused one it goes on; not published, so a drag does not repaint
    /// everything that watches the store.
    var dockRegionSize = DockSize(width: 0, height: 0)
    /// Whether the trailing region is showing, tracked separately from what
    /// is in it: the region can be open and empty (offering the picker), and
    /// hiding it keeps its panels so reopening restores them where they were.
    @Published private(set) var rightRegionOpen = false
    /// The panel the person is working in — the one a new panel opens beside,
    /// and the one that stands alone while the region is filled. Saved, which
    /// the property did not use to be: a click on a panel's tab only reached
    /// disk with the next unrelated save.
    @Published var frontPanel: SidePanel? {
        didSet {
            if oldValue != frontPanel { scheduleSave() }
        }
    }
    /// True while the trailing region is expanded over the main surface.
    @Published private(set) var rightPanelExpanded = false
    @Published private(set) var bottomDockOpen = false
    @Published var showCommandPalette = false
    /// The Keyboard Shortcuts window. Opened with `showShortcuts()`, which
    /// copes with a sheet that is still on its way out; set directly only to
    /// close it.
    @Published var showKeyboardShortcuts = false
    /// A log file being analyzed, in a sheet of its own (see `LogAnalysis`).
    @Published var logAnalysisTarget: LogAnalysisTarget?
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
    /// The last focus request the composer's editor acted on.
    ///
    /// Kept here, not in the editor, because `focusComposer()` un-hides and
    /// un-collapses the composer before it asks for focus, so the editor is
    /// built *after* the request: one that only compared against the value it
    /// was created with would treat the request as already handled. Plain, not
    /// published — acknowledging a request must not redraw anything.
    var composerFocusHandled = 0
    var composerFocusPending: Bool { composerFocusRequest != composerFocusHandled }

    /// A skill's text on its way into the composer's input. Handled the way
    /// focus and help are: the composer may not exist yet when it is made, so it
    /// is kept until the view takes it.
    struct ComposerInsertRequest: Equatable {
        let id: Int
        let text: String
    }
    @Published private(set) var composerInsertRequest: ComposerInsertRequest?
    var composerInsertHandled = 0
    private var composerInsertCounter = 0
    var composerInsertPending: ComposerInsertRequest? {
        guard let request = composerInsertRequest, request.id != composerInsertHandled else { return nil }
        return request
    }

    /// A request, from a menu or the composer's "+" menu, for the assistant to
    /// look at what the composer's terminal last printed. Handled the way focus
    /// is: the composer may not exist yet when it is made, so it is kept until
    /// the view acknowledges it.
    struct ComposerHelpRequest: Equatable {
        let id: Int
        let kind: ErrorHelpKind
        /// Text selected in a terminal, when the request is about that and not
        /// about what the composer's terminal last printed.
        var selection: String? = nil
    }
    @Published private(set) var composerHelpRequest: ComposerHelpRequest?
    var composerHelpHandled = 0
    private var composerHelpCounter = 0
    var composerHelpPending: ComposerHelpRequest? {
        guard let request = composerHelpRequest, request.id != composerHelpHandled else { return nil }
        return request
    }

    /// Terminals living in the bottom dock. Separate from tab panes — the
    /// dock is a scratch surface that survives switching tabs.
    @Published private(set) var dockSessions: [TerminalSession] = []
    @Published var selectedDockSessionID: UUID?

    /// Models backing the sliding side panels (distinct from panes that live
    /// inside a tab's split layout).
    lazy var panelBrowserTabs = BrowserTabsModel()
    lazy var panelFiles = FileBrowserModel()
    lazy var panelHTTPClient = HTTPClientModel(id: HTTPClientModel.sidePanelHistoryID)

    /// The notes, kept together and not tied to a space.
    let panelNotes = NotesModel()

    private static let fallbackNotesID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private var chatModels: [UUID: ComposerChatModel] = [:]

    /// The composer's chat for the space being looked at; each space has its own.
    var composerChat: ComposerChatModel {
        let id = currentWorkspace?.id ?? Self.fallbackNotesID
        if let model = chatModels[id] { return model }
        let model = ComposerChatModel(workspaceID: id)
        chatModels[id] = model
        return model
    }

    /// Writes any chat message still inside its debounce window.
    func flushChats() {
        chatModels.values.forEach { $0.saveNow() }
    }

    /// Writes any note still inside its debounce window.
    func flushNotes() {
        panelNotes.saveNow()
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
        pruneOrphanedHTTPHistory()
    }

    private func bootstrap() {
        let workspace = Workspace(name: "Space 1")
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
        if let lastWorkspaceID,
           let workspace = workspaces.first(where: { $0.id == lastWorkspaceID }) {
            return workspace
        }
        return workspaces.first
    }

    /// True when the detail column is showing the landing page.
    var isHome: Bool { detailMode == .terminal && selectedTab == nil }

    /// Shows the landing page. Tabs stay open and their shells keep running;
    /// none of them is selected.
    func goHome() {
        detailMode = .terminal
        selectedTabID = nil
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

    /// Every HTTP client the API can address: panes inside tabs, plus the
    /// right panel's one instance.
    func allHTTPClients() -> [HTTPClientModel] {
        workspaces.flatMap { $0.tabs.flatMap { $0.root.allHTTPClients() } } + [panelHTTPClient]
    }

    func httpClient(withIdentifier identifier: String) -> HTTPClientModel? {
        allHTTPClients().first { $0.id.uuidString == identifier }
    }

    func noteFocused(session: TerminalSession) {
        if focusedSessionID != session.id {
            focusedSessionID = session.id   // didSet dismisses the mark
        } else {
            // Already focused, so the didSet will not fire — but clicking back
            // into a pane still dismisses its mark.
            session.clearAttention()
        }
        // A tool's terminal taking focus makes its panel the focused one, which
        // is what a panel opened next goes beside. Only a tool can say so: a
        // click inside the browser's web view never reaches here, so the
        // browser becomes the focused panel through its header, or by being
        // opened.
        if let tool = session.kind.tool,
           let panel = SidePanel.allCases.first(where: { $0.tool == tool }),
           openPanels.contains(panel),
           frontPanel != panel {
            frontPanel = panel
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

    /// A new tab on this Mac with `text` typed at its prompt and not run. The
    /// person reads it, and Return is what runs it — nothing is sent after the
    /// text, and a line break or any other control character in it becomes a
    /// space, so what is typed can only ever sit on the line.
    func newTab(typing text: String) {
        let line = String(text.map { character -> Character in
            character.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F } ? character : " "
        })
        let tab = newTab()
        guard let session = tab.root.firstTerminal() else { return }
        // The shell has to be up and reading. Typed any earlier, the line is
        // held by the terminal and arrives anyway, but a shell that clears its
        // input as it starts would lose it, so give it a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak session] in
            session?.send(text: line)
        }
    }

    /// A new tab in `directory` that runs `line` as soon as its shell is up.
    ///
    /// Only for a line this app built itself, with what goes into it checked —
    /// see `EditorCommand`. Text that came from anywhere else belongs in
    /// `newTab(typing:)`, which leaves Return to the person.
    func newTab(directory: String?, running line: String) {
        let tab = newTab(directory: directory)
        guard let session = tab.root.firstTerminal() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak session] in
            session?.send(text: line)
        }
    }

    /// Opens the file at `path` in the editor chosen under Settings → General,
    /// in a new tab beside where it lives. Returns what to tell the person when
    /// that cannot be done, and nil when the tab is open.
    @discardableResult
    func editFile(at path: String) -> String? {
        let settings = AppSettings.shared
        switch EditorCommand.line(
            choice: settings.editorChoice,
            custom: settings.editorCustomCommand,
            path: path,
            locate: SessionLaunch.resolveExecutable
        ) {
        case .success(let line):
            newTab(directory: (path as NSString).deletingLastPathComponent, running: line)
            return nil
        case .failure(let problem):
            return problem.message
        }
    }

    /// A tab signed in to `connection` whose sign-in the file browser can use,
    /// for a host that wants a password. The tab is the same ssh a connection
    /// opens anywhere else, told to keep its connection open to others; the
    /// password is typed to it, as ever. Returns what to tell the person when
    /// it could not be set up to share. A tab opens either way, except when one
    /// is signed in and open already: a second would only ask for the password
    /// again.
    @discardableResult
    func newSharedSignIn(for connection: SSHConnection) -> String? {
        switch SSHControlSocket.prepare(for: connection, base: NSTemporaryDirectory()) {
        case .master(let path):
            newTab(kind: .remote(connection.id), controlPath: path)
            return nil
        case .open:
            return "\(connection.name.isEmpty ? connection.host : connection.name) is already signed in through another tab. Press Try Again."
        case .unavailable(let reason):
            newTab(kind: .remote(connection.id))
            return "This sign-in can't be shared with the file browser: \(reason). The tab works as usual."
        }
    }

    func newWorkspace(named name: String? = nil) {
        let resolved = (name?.isEmpty == false) ? name! : "Space \(workspaces.count + 1)"
        let workspace = Workspace(name: resolved)
        workspaces.append(workspace)
        scheduleSave()
        EventBus.shared.publish(APIEvent("workspace.created", [
            "workspace": workspace.id.uuidString,
            "name": workspace.name,
        ]))
        newTab(in: workspace)
    }

    /// A terminal tab the person asked for — ⌘T, the New Tab button, the palette,
    /// a context menu — with `profile`, or the default profile if one is chosen
    /// in Settings, or neither.
    ///
    /// This is the one place a profile's startup command is typed. A tab made
    /// any other way — restored at launch, reopened from Recents, made for a
    /// file, a host or the scripting API, or a split — gets the profile's shell,
    /// environment and folder but not the command, so nothing runs that the
    /// person did not just ask for.
    @discardableResult
    func openTab(profile: TerminalProfile? = nil) -> WorkspaceTab {
        let chosen = profile ?? AppSettings.shared.defaultProfile
        let tab = newTab(profileID: chosen?.id)
        if let line = chosen?.startupLine, let session = tab.root.firstTerminal() {
            // Held by the terminal and arrives anyway, but a shell that clears
            // its input as it starts would lose it, so give it a moment, as
            // `newTab(directory:running:)` does.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak session] in
                session?.send(text: line)
            }
        }
        return tab
    }

    @discardableResult
    func newTab(
        in workspace: Workspace? = nil,
        directory: String? = nil,
        kind: SessionKind = .localShell,
        controlPath: String? = nil,
        profileID: UUID? = nil
    ) -> WorkspaceTab {
        let target: Workspace
        if let workspace {
            target = workspace
        } else if let current = currentWorkspace {
            target = current
        } else {
            let created = Workspace(name: "Space 1")
            workspaces = [created]
            target = created
        }

        // A local shell opens with the profile asked for, else the default one.
        // Without a profile, or for a host, nothing changes from before.
        let profileForShell: UUID? = kind == .localShell
            ? (profileID ?? AppSettings.shared.defaultProfile?.id)
            : nil
        let session = TerminalSession(
            kind: kind,
            initialDirectory: directory,
            controlPath: controlPath,
            profileID: profileForShell
        )
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

    /// Moves a tab to sit just before `target` in `destination`, or last in it
    /// when `target` is nil — within its own workspace or into another. Which
    /// tab is selected does not change: it is the same tab, somewhere else.
    func moveTab(_ id: UUID, before target: WorkspaceTab?, in destination: Workspace) {
        guard target?.id != id,
              let source = workspace(containingTab: id),
              let tab = source.tabs.first(where: { $0.id == id }) else { return }
        let pool = source === destination ? destination.tabs : destination.tabs + [tab]
        let byID = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let order = TabOrder.placing(id, before: target?.id, in: destination.tabs.map(\.id))
        let arranged = order.compactMap { byID[$0] }
        // Nothing is touched until the new order is known to hold every tab.
        guard arranged.count == pool.count else { return }
        if source !== destination {
            source.tabs.removeAll { $0 === tab }
        }
        if arranged.map(\.id) != destination.tabs.map(\.id) {
            destination.tabs = arranged
            scheduleSave()
        }
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
        guard !unreadableStateIsKept else { return }
        TranscriptStore.pruneAll(keeping: Set(recentSessions.map(\.id)))
    }

    /// HTTP history is keyed by pane, and a pane that no longer exists can't
    /// be reached to read or clear it. Sweeps on launch and after an import —
    /// the two points where the set of panes changes wholesale. Built from
    /// the panes in the layout rather than `allHTTPClients()`, which would
    /// instantiate the side panel's lazy model just to read its ID.
    func pruneOrphanedHTTPHistory() {
        guard !unreadableStateIsKept else { return }
        var live = Set(workspaces.flatMap { $0.tabs.flatMap { $0.root.allHTTPClients() } }.map(\.id))
        live.insert(HTTPClientModel.sidePanelHistoryID)
        HTTPHistoryStore.pruneAll(keeping: live)
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
        chatModels[workspace.id]?.cancel()
        chatModels[workspace.id] = nil
        ComposerChatModel.deleteFile(for: workspace.id)
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
            // A split of a shell opened from a profile uses the same profile —
            // its shell, environment and folder rules, not its startup command.
            let session = TerminalSession(
                kind: sessionKind,
                initialDirectory: sessionKind.isRemote ? nil : focusedSession?.currentDirectory,
                profileID: sessionKind.isRemote ? nil : focusedSession?.profileID
            )
            session.startIfNeeded()
            newContent = .terminal(session)
            focusedSessionID = session.id
        case .browser:
            newContent = .browser(BrowserModel())
        case .files:
            newContent = .files(FileBrowserModel(path: focusedSession?.currentDirectory))
        case .http:
            newContent = .http(HTTPClientModel())
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
            // the arrangement's didSet ends the process. Not filed under Recents —
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

    /// Opens the Keyboard Shortcuts window.
    ///
    /// Two sheets cannot be on one window at once, and a second asked for while
    /// the first is closing is dropped. So when the command palette is up, or
    /// something — the palette, a popover — has only just been dismissed to run
    /// the action that called this (`afterPresentation`), the palette is closed
    /// and the window follows once that has finished.
    func showShortcuts(afterPresentation: Bool = false) {
        let wait = afterPresentation || showCommandPalette
        showCommandPalette = false
        guard wait else {
            showKeyboardShortcuts = true
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.showKeyboardShortcuts = true
        }
    }

    /// Opens the sheet that reads the log at `path` and asks the assistant about
    /// it. Nothing is read or sent until the sheet is up, and nothing is sent
    /// until the person has seen where it goes and pressed Analyze.
    func analyzeLog(at path: String) {
        logAnalysisTarget = LogAnalysisTarget(path: path)
    }

    /// Asks which file, then analyzes it.
    func chooseLogToAnalyze() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Analyze"
        panel.message = "Choose a log file. Nothing is sent until you have seen where it goes."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        analyzeLog(at: url.path)
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

    /// Puts `text` in the composer's input and the caret there. It is added to
    /// what is already in the input, never sent: only Return sends.
    func insertIntoComposer(_ text: String) {
        focusComposer()
        composerInsertCounter += 1
        composerInsertRequest = ComposerInsertRequest(id: composerInsertCounter, text: text)
    }

    /// Asks the composer's assistant to explain, or suggest a fix for, what the
    /// composer's terminal last printed — un-hiding the composer first, since
    /// the answer appears there.
    func requestComposerHelp(_ kind: ErrorHelpKind, selection: String? = nil) {
        detailMode = .terminal
        AppSettings.shared.composerEnabled = true
        AppSettings.shared.composerCollapsed = false
        composerHelpCounter += 1
        composerHelpRequest = ComposerHelpRequest(id: composerHelpCounter, kind: kind, selection: selection)
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
        /// No terminal: what is typed is a message to the AI model.
        case assistant
    }

    var composerDestination: ComposerDestination {
        if AppSettings.shared.composerTarget == .assistant { return .assistant }
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

    /// The terminal a composer command would run in, if there is one yet: the
    /// focused terminal, or the composer's own shell once it has started.
    var composerDestinationSession: TerminalSession? {
        switch composerDestination {
        case .terminal(let session): return session
        case .ownShell: return composerSession
        case .assistant: return nil
        }
    }

    /// Runs a command typed in the composer, in whatever it is pointed at.
    func sendFromComposer(_ text: String) {
        let session: TerminalSession
        switch composerDestination {
        case .assistant:
            // Not a terminal. The composer sends a chat message itself.
            return
        case .terminal(let target):
            target.send(text: text)
            session = target
        case .ownShell:
            session = ensureComposerSession()
            session.send(text: text)
            // Gates the inline transcript, so it only appears when there is a
            // composer shell whose output has nowhere else to go.
            if !composerHasRun { composerHasRun = true }
        }
        lastComposerSend = (session.id, text.trimmingCharacters(in: .whitespacesAndNewlines))
        recordComposerCommand(text)
    }

    /// The last command sent from the composer, and the terminal it went to.
    /// What Explain and Fix it can say about "the command" without guessing: the
    /// terminal's own record of its last command is a two-word label for the
    /// sidebar, and its line buffer can hold anything typed at a prompt — a
    /// password included. Plain, not published: nothing draws from it.
    private(set) var lastComposerSend: (sessionID: UUID, command: String)?

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

    /// Where the composer's own shell begins, and so where its commands and file
    /// completions are read from before it has started: the focused terminal's
    /// directory when that is a place on this Mac, otherwise the configured
    /// default, as for any new local terminal. A remote session's directory is
    /// a path on another machine, and means nothing here.
    ///
    /// One answer for both, so what Tab completes is what the shell will see.
    var composerShellDirectory: String {
        if let session = focusedSession, !session.isRemote { return session.currentDirectory }
        return AppSettings.shared.resolvedInitialDirectory
    }

    @discardableResult
    func ensureComposerSession() -> TerminalSession {
        if let composerSession { return composerSession }
        let shell = AppSettings.shared.composerShell
        let session = TerminalSession(
            kind: .localShell,
            initialDirectory: composerShellDirectory,
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

    /// Open panels in a stable order — the order they are declared in — so a
    /// strip of them doesn't reshuffle when the arrangement changes.
    var orderedOpenPanels: [SidePanel] {
        SidePanel.allCases.filter { openPanels.contains($0) }
    }

    /// Open panels as they read in the arrangement: left to right, top to
    /// bottom.
    var panelsInReadingOrder: [SidePanel] {
        (dockLayout?.modules ?? []).compactMap(SidePanel.init(rawValue:))
    }

    /// The panel the person is working in: the one in front, or the first in
    /// the arrangement when none is.
    var visiblePanel: SidePanel? {
        if let frontPanel, openPanels.contains(frontPanel) { return frontPanel }
        return panelsInReadingOrder.first
    }

    /// What the region draws right now: the whole arrangement, or only the
    /// panel filling it.
    var effectiveDockLayout: DockNode? {
        if let dockFill, dockLayout?.contains(dockFill.rawValue) == true {
            return .leaf(dockFill.rawValue)
        }
        return dockLayout
    }

    /// Where `panel` stands in the Move and Fill menu.
    func arrangement(of panel: SidePanel) -> DockArrangement {
        guard dockFill == panel else { return .tiled }
        return rightPanelExpanded ? .fillWindow : .fillRegion
    }

    /// Shortcut and top-strip semantics: turning a panel off that was the
    /// only one also puts the region away, so the toggle stays predictable.
    func togglePanel(_ panel: SidePanel) {
        if rightRegionOpen, openPanels.contains(panel) {
            // While one panel fills the region the others are set aside, not on
            // screen. Closing one the person cannot see would be a surprise, so
            // the shortcut brings it forward instead.
            if let fill = dockFill, fill != panel {
                focusPanel(panel)
                return
            }
            closePanel(panel)
            if openPanels.isEmpty {
                withAnimation(Motion.panel) {
                    rightRegionOpen = false
                    rightPanelExpanded = false
                }
            }
        } else {
            openPanel(panel)
        }
        scheduleSave()
    }

    /// Brings `panel` into the region and makes it the one in front.
    ///
    /// A panel that is not open yet is placed beside the one in front, on the
    /// side `DockLayout.smartEdge` picks for the region's current size; one that
    /// is open keeps its place in the arrangement.
    func openPanel(_ panel: SidePanel) {
        let wasFilling = dockFill != nil
        withAnimation(Motion.panel) {
            if !openPanels.contains(panel) {
                setDockLayout(DockLayout.smartInserting(
                    panel.rawValue,
                    near: visiblePanel?.rawValue,
                    regionSize: smartPlacementSize,
                    into: dockLayout,
                    metrics: SidePanel.dockMetrics
                ))
            }
            frontPanel = panel
            // The panels set aside by a fill are not on screen, so one opened
            // over a fill takes its place rather than arriving out of sight.
            if wasFilling { dockFill = panel }
            rightRegionOpen = true
        }
        releaseFocusFromHiddenTool()
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
        // No bootstrap for .http: unlike Files following the focused
        // terminal's directory, there is no "current thing" to seed a
        // request from, and seeding anything would mean firing a network
        // request the instant the panel opens.
        scheduleSave()
    }

    /// Closing a panel from its own tab leaves the region up, so emptying it
    /// lands on the picker rather than collapsing the layout out from under
    /// the pointer that just clicked.
    ///
    /// Closing the panel that is in front, or the one filling the region, hands
    /// that role to the next panel in the arrangement (the previous one, for the
    /// last), and closing a panel that is not open does nothing.
    func closePanel(_ panel: SidePanel) {
        let order = panelsInReadingOrder
        var successor: SidePanel?
        if let index = order.firstIndex(of: panel) {
            if index + 1 < order.count {
                successor = order[index + 1]
            } else if index > 0 {
                successor = order[index - 1]
            }
        }
        withAnimation(Motion.panel) {
            if dockFill == panel { dockFill = successor }
            if frontPanel == panel { frontPanel = successor }
            setDockLayout(DockLayout.removing(panel.rawValue, from: dockLayout))
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

    /// The `<` / `>` button beside the panels menu: puts the whole region away
    /// or brings it back with the panels it had (the picker if it had none).
    func toggleRightRegion() {
        if rightRegionOpen {
            closeRightRegion()
        } else {
            withAnimation(Motion.panel) { rightRegionOpen = true }
            scheduleSave()
        }
    }

    func toggleRightPanelExpanded() {
        withAnimation(Motion.panel) { rightPanelExpanded.toggle() }
    }

    /// Opens `panel` and lets the trailing region fill the whole content
    /// area — the "full view" of the panels menu.
    func openPanelExpanded(_ panel: SidePanel) {
        openPanel(panel)
        withAnimation(Motion.panel) {
            dockFill = panel
            rightPanelExpanded = true
        }
        scheduleSave()
    }

    // MARK: Arranging the panels

    /// Makes `panel` the one in front. While one panel fills the region this is
    /// also what swaps which one is on screen, so the strip of panels at the top
    /// still works like tabs. A click anywhere in a panel calls it
    /// (`DockClickFocus`), as does a tap on its header.
    func focusPanel(_ panel: SidePanel) {
        guard openPanels.contains(panel) else { return }
        // Only when it changes: a click in the panel that is already in front
        // would otherwise tell everything that watches the store.
        if frontPanel != panel { frontPanel = panel }
        guard let fill = dockFill, fill != panel else { return }
        holdTerminalSizes()
        withAnimation(Motion.panel) { dockFill = panel }
        releaseFocusFromHiddenTool()
        scheduleSave()
    }

    /// The Fill and arrange row of a panel's menu.
    func setArrangement(_ arrangement: DockArrangement, for panel: SidePanel) {
        guard openPanels.contains(panel) else { return }
        holdTerminalSizes()
        withAnimation(Motion.panel) {
            frontPanel = panel
            switch arrangement {
            case .tiled:
                // Already arranged side by side: nothing to undo, and the
                // expand toggle is what undoes an expanded region.
                if dockFill != nil {
                    dockFill = nil
                    rightPanelExpanded = false
                }
            case .fillRegion:
                dockFill = panel
                rightPanelExpanded = false
            case .fillWindow:
                dockFill = panel
                rightPanelExpanded = true
            }
        }
        releaseFocusFromHiddenTool()
        scheduleSave()
    }

    /// The Move row of a panel's menu: the panel goes along one side of the
    /// region, full height or full width. Moving means arranging, so a fill is
    /// undone.
    func movePanel(_ panel: SidePanel, toRegionEdge edge: DockEdge) {
        guard openPanels.contains(panel) else { return }
        withAnimation(Motion.panel) {
            dockFill = nil
            setDockLayout(DockLayout.moving(panel.rawValue, toRegionEdge: edge, in: dockLayout))
            frontPanel = panel
        }
        scheduleSave()
    }

    /// A panel whose header was dragged and let go over a place it can go. The
    /// same moves and swaps as the Move menu (`DockLayout.dropping`), so a drag
    /// and a menu choice end in the same arrangement. Only panels sharing the
    /// region can be dragged, so there is no fill to undo.
    func dropPanel(_ panel: SidePanel, onto target: DockDropTarget) {
        guard openPanels.contains(panel) else { return }
        withAnimation(Motion.panel) {
            setDockLayout(DockLayout.dropping(panel.rawValue, onto: target, in: dockLayout))
            frontPanel = panel
        }
        scheduleSave()
    }

    /// Stores an arrangement the region has finished editing — a divider that
    /// was dragged. Ignored when the panels in it are no longer the open ones,
    /// which is what a drag that outlived a closing panel would otherwise
    /// resurrect.
    func commitDockLayout(_ layout: DockNode?) {
        guard Set(layout?.modules ?? []) == Set(dockLayout?.modules ?? []) else { return }
        setDockLayout(layout)
    }

    /// Back to every open panel in a single column, sharing the height equally.
    func resetDockLayout() {
        withAnimation(Motion.panel) {
            dockFill = nil
            setDockLayout(DockLayout.stacked(panelsInReadingOrder.map { $0.rawValue }))
        }
        scheduleSave()
    }

    /// The one place the arrangement is replaced after launch: puts it in normal
    /// form, and keeps the fill and the panel in front pointing at panels that
    /// are still in it.
    private func setDockLayout(_ proposed: DockNode?) {
        let layout = DockLayout.normalized(proposed)
        guard layout != dockLayout else { return }
        holdTerminalSizes()
        dockLayout = layout
        let open = panelsInReadingOrder
        if let fill = dockFill, !open.contains(fill) { dockFill = nil }
        if let front = frontPanel, !open.contains(front) { frontPanel = open.first }
        scheduleSave()
    }

    /// Which side of the focused panel a newcomer goes on depends on how much
    /// room there is. The region's own measurement is used while it is on
    /// screen at its tiled size; otherwise the width it opens at.
    private var smartPlacementSize: DockSize {
        let measured = dockRegionSize
        if rightRegionOpen, !rightPanelExpanded, measured.width > 0, measured.height > 0 {
            return measured
        }
        return DockSize(
            width: AppSettings.shared.rightPanelWidth,
            height: measured.height > 0 ? measured.height : 700
        )
    }

    /// A rearrangement animates panels from one size to another, and every
    /// frame of that is a new column count for a terminal — a SIGWINCH for
    /// btop to redraw its whole screen on. Terminals keep the size they had
    /// until the animation is over, as they do during a divider drag, and catch
    /// up once.
    ///
    /// Nothing is held when a seam drag already holds them, so this cannot cut
    /// a real drag short.
    private func holdTerminalSizes() {
        guard !SeamDrag.isActive else { return }
        SeamDrag.begin()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { SeamDrag.end() }
    }

    /// A fill puts the other panels out of sight, and focus must not stay
    /// inside one: ⇧⌘W would close a tool the person cannot see, and when
    /// focus is in no pane of the tab at all it closes the whole tab.
    private func releaseFocusFromHiddenTool() {
        guard let focused = focusedSessionID,
              let tool = toolSessions.first(where: { $0.value.id == focused })?.key,
              let panel = SidePanel.allCases.first(where: { $0.tool == tool }) else { return }
        let showing = rightRegionOpen && effectiveDockLayout?.contains(panel.rawValue) == true
        if !showing {
            focusedSessionID = selectedTab?.root.firstTerminal()?.id
        }
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
            bottomDockHeight: settings.bottomDockHeight,
            dockLayout: DockLayoutField(root: dockLayout),
            dockFill: dockFill?.rawValue
        )
    }

    /// Puts the surrounding layout back. Dock terminals are relaunched in the
    /// directories the old ones were sitting in — the processes themselves
    /// died with the app.
    private func applyPanelSnapshot(_ snapshot: PanelStateSnapshot?) {
        guard let snapshot else { return }
        restoreDockLayout(from: snapshot)
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

    /// Sets the arrangement of the trailing region, and the panel in front,
    /// from a saved state. `DockLayout.restoring` decides what the arrangement
    /// is, including for a file written before panels could be tiled.
    private func restoreDockLayout(from snapshot: PanelStateSnapshot) {
        let restored = DockLayout.restoring(
            saved: snapshot.dockLayout?.root,
            savedFill: snapshot.dockFill,
            open: snapshot.openPanels,
            front: snapshot.frontPanel,
            known: Set(SidePanel.allCases.map { $0.rawValue })
        )
        dockLayout = restored.root
        dockFill = restored.fill.flatMap(SidePanel.init(rawValue:))
        frontPanel = snapshot.frontPanel.flatMap(SidePanel.init(rawValue:))
        if let front = frontPanel, !openPanels.contains(front) {
            frontPanel = panelsInReadingOrder.first
        }
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
        // Notes are not in a snapshot and not tied to a space, so an import
        // leaves them alone.
        flushNotes()
        flushChats()
        chatModels.values.forEach { $0.cancel() }
        chatModels.removeAll()
        workspaces = snapshot.workspaces.map { Workspace(snapshot: $0) }
        recentSessions = snapshot.recents ?? []
        pruneOrphanedTranscripts()
        pruneOrphanedHTTPHistory()
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
        // No file is a first launch. One that is there but cannot be read, or
        // will not decode — a newer build's, say — is kept rather than saved
        // over by the new layout that follows: see `UnreadableState`.
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return false }
        guard let data = try? Data(contentsOf: stateURL),
              let snapshot = try? JSONDecoder().decode(AppStateSnapshot.self, from: data) else {
            keepUnreadableState()
            return false
        }
        guard !snapshot.workspaces.isEmpty else { return false }

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

    /// Moves a state file this build cannot read out of the way of the save
    /// that follows a fresh start, keeping it beside where it was.
    private func keepUnreadableState() {
        if let kept = UnreadableState.keep(stateURL) {
            NSLog("Workspace state could not be read by this build; kept it as \(kept.lastPathComponent) and started a new layout.")
        } else {
            NSLog("Workspace state could not be read by this build, and could not be moved aside; the new layout will replace it.")
        }
    }

    /// Whether a layout this build could not read is kept beside the state
    /// file. While one is, transcripts and HTTP history are not pruned: they
    /// may be that layout's.
    private var unreadableStateIsKept: Bool {
        UnreadableState.isKept(in: stateURL.deletingLastPathComponent())
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
