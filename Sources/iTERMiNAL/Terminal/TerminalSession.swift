import AppKit
import Combine
import SwiftTerm

/// One live session: a local shell or a remote host, owning the engine (and
/// therefore the PTY child process) and publishing the metadata the sidebar
/// shows — title, working directory, git branch. The session object outlives
/// view attachment, which is what keeps processes alive while the user
/// switches tabs or workspaces.
final class TerminalSession: ObservableObject, Identifiable {
    let id: UUID
    let kind: SessionKind

    @Published private(set) var title: String = ""
    @Published private(set) var currentDirectory: String
    @Published private(set) var gitBranch: String?
    @Published private(set) var isRunning = false
    @Published private(set) var lastExitCode: Int32?
    /// Set when the session could not be launched at all (missing binary,
    /// deleted connection) — distinct from a process that ran and exited.
    @Published private(set) var launchError: String?
    /// Set when ssh ended with `No route to host` for a host on the local
    /// network, which is what a missing Local Network permission looks like
    /// (see `LocalNetwork`). The banner offers that setting. A launch clears it.
    @Published private(set) var localNetworkBlocked = false
    /// What ssh's last words said went wrong, when that is more than "the
    /// session ended" (see `TabConnectionProblem`). The banner names it and
    /// offers its buttons. A launch clears it.
    @Published private(set) var endProblem: RemoteProblem?
    /// Whether SwiftTerm's Metal renderer ended up active for this session —
    /// requesting GPU rendering can silently fall back to the CPU path.
    @Published private(set) var isGPUAccelerated = false
    /// Drives the sidebar's relative timestamps.
    @Published private(set) var lastActivityAt = Date()
    /// When the shell was launched, for the task manager's uptime column.
    /// Nil until it actually starts, so a session that never launched reads
    /// as "not started" rather than claiming zero seconds of uptime.
    @Published private(set) var startedAt: Date?
    /// The most recent command this shell was given, so a tab can be
    /// identified by what it is doing rather than by its directory — which is
    /// the same for every tab opened in one project.
    @Published private(set) var lastCommand: String?
    /// True after a bell / OSC attention while this pane was not in front of
    /// the user. Cleared when the session (or its tab) becomes focused.
    @Published private(set) var needsAttention = false
    /// What the last command did, when this shell reports it (Settings →
    /// Terminal → Shell integration). Cleared when the next command starts.
    @Published private(set) var lastCommandResult: CommandResult?

    struct CommandResult: Equatable {
        let exitCode: Int?
        /// How long it ran, when its start was seen.
        let seconds: Double?
        let finishedAt: Date
    }

    let engine: SwiftTermEngine
    /// Coalesces rapid bells / identical OSC text to about one event per
    /// second. Private because nothing outside `noteAttention` has any business
    /// moving the debounce window.
    private var lastAttentionAt = Date.distantPast
    private var lastAttentionFingerprint: String?
    private var hasStarted = false
    /// Whether this shell was started with the integration hooks. Marks are
    /// believed only if so: anything a program prints can look like one.
    private var shellIntegrationActive = false
    private var commandTracker = ShellIntegration.CommandTracker()
    /// Set while the question about forwarding the agent is on screen, so a
    /// second start cannot put a second copy of it up.
    private var awaitingAgentAnswer = false
    /// The same, for the question a host from an imported snapshot asks before
    /// its first connection — which may also be waiting its turn.
    private var awaitingImportAnswer = false

    /// Everything `applyStyling` reads. Held so the work can be skipped when
    /// none of it has changed — see the guard there for why that matters.
    private struct StylingInputs: Equatable {
        var themeID: String
        /// What "auto" (Match app) resolves through.
        var appThemeID: String
        var darkMode: Bool
        var fontName: String
        var fontSize: Double
        var backgroundOpacity: Double
        var gpuRequested: Bool
        var cursorStyleTag: String
        var cursorAnimationTag: String
        var cursorColorHex: String
        var cursorTextColorHex: String
        var selectionColorHex: String
        var boldAsBright: Bool
        var optionAsMeta: Bool
        var lineSpacing: Double
    }
    private var appliedStyling: StylingInputs?

    /// When the running process was launched. `startedAt` is the first
    /// launch only; Restart launches again.
    private var launchedAt: Date?

    // MARK: Automatic reconnect (see `AutoReconnect`)

    /// A reconnect that is waiting for its turn: which try it is, out of how
    /// many, and when it starts. Nil when none is.
    struct ReconnectPlan: Equatable {
        let attempt: Int
        let total: Int
        let at: Date
        /// Held because there is no network: it starts a few seconds after one
        /// comes back (see `NetworkWatch`), and `at` means nothing until then.
        var waitingForNetwork = false
    }
    @Published private(set) var reconnectPlan: ReconnectPlan?
    /// Why automatic reconnecting stopped, when the person would want to know.
    /// Cleared by the next launch.
    @Published private(set) var reconnectNote: String?
    /// Tries made in the current run of them; 0 for a session the person started.
    private var reconnectAttempts = 0
    private var reconnectWork: DispatchWorkItem?
    /// `NetworkWatch.mayReconnect`, taken the first time a reconnect waits.
    /// Ends with the session.
    private var networkSubscription: AnyCancellable?
    /// Set when the person ended the session — closed it, or stopped it — so
    /// the end that follows is not a drop to retry. A launch clears it.
    private var endedByUser = false

    /// A shell for this session alone, overriding the global setting. The
    /// composer uses it so switching to bash there leaves every other terminal
    /// on whatever the user configured.
    private let shellOverride: String?

    /// Where this session's `ssh` listens, when it is the sign-in the file
    /// browser shares. Held so a reconnect makes the same offer.
    private let controlPath: String?

    /// The profile this session was opened with, by id. It is looked up when
    /// the shell starts, so a profile edited in Settings applies to the next
    /// shell and one that has been deleted is simply not applied.
    let profileID: UUID?

    init(
        id: UUID = UUID(),
        kind: SessionKind = .localShell,
        initialDirectory: String? = nil,
        shellOverride: String? = nil,
        controlPath: String? = nil,
        profileID: UUID? = nil
    ) {
        let settings = AppSettings.shared
        self.id = id
        self.kind = kind
        self.shellOverride = shellOverride
        self.controlPath = controlPath
        self.profileID = profileID
        // Where a folder was asked for, else the profile's, else the default. A
        // restored shell is given the folder it was in, so it keeps that.
        self.currentDirectory = initialDirectory
            ?? settings.profile(withID: profileID)?.resolvedStartDirectory(exists: { SessionLaunch.isFolder($0) })
            ?? settings.resolvedInitialDirectory

        let options = TerminalOptions(
            cursorStyle: CursorStyle(tagName: settings.cursorStyleTag) ?? .steadyBlock,
            scrollback: max(100, settings.scrollbackLines)
        )
        engine = SwiftTermEngine(options: options)
        engine.delegate = self
        // A path on this Mac means nothing to a remote shell, and a bundled
        // tool draws its own screen: neither is typed into by a drop.
        engine.dropPolicy = kind.isTool ? .nothing : (kind.isRemote ? .textOnly : .filesAndText)
        engine.onFocusGained = { [weak self] in
            guard let self else { return }
            WorkspaceStore.shared.noteFocused(session: self)
        }
        engine.onActivity = { [weak self] in
            // SwiftTerm makes no promise about which queue this arrives on —
            // the engine says so where it coalesces these — and everything
            // below either publishes observable state or reads an AppKit
            // view, so the hop has to happen before any of it. The event bus
            // hops on its own, which is why this was survivable before, but
            // `lastActivityAt` was already being published off-thread.
            DispatchQueue.main.async {
                guard let self else { return }
                // Already debounced by the engine, so this is cheap.
                self.lastActivityAt = Date()
                // A prompt redraw after `cd` is activity, so this is where a
                // directory change becomes visible in a shell with no OSC 7
                // hook.
                self.refreshDirectoryFromProcess()
                EventBus.shared.publish(APIEvent("session.activity", ["session": self.id.uuidString]))
            }
        }
        engine.onAttention = { [weak self] attention in
            DispatchQueue.main.async {
                self?.noteAttention(attention)
            }
        }
        engine.onCommand = { [weak self] command in
            // Same queue caveat as the activity callback above.
            DispatchQueue.main.async {
                self?.noteCommand(command)
            }
        }
        engine.onShellMark = { [weak self] mark in
            // Same queue caveat as the callbacks above.
            DispatchQueue.main.async {
                self?.noteShellMark(mark)
            }
        }
        engine.onLinkActivated = { [weak self] link in
            guard let self else { return }
            EventBus.shared.publish(APIEvent("session.link", [
                "session": self.id.uuidString,
                "url": link,
            ]))
            WorkspaceStore.shared.openLinkFromTerminal(link)
        }
        engine.contextMenuActions = { [weak self] in
            self?.contextMenuActions() ?? []
        }
        engine.selectionActions = { [weak self] text in
            self?.selectionActions(for: text) ?? []
        }
    }

    /// What a right-click on selected text offers: for an address, to open or
    /// copy it; for a file or folder that exists on this Mac, to reveal it,
    /// open a tab there, or copy it ready to paste into a command; and, for any
    /// of it, to ask the assistant what it means. A bundled tool draws its own
    /// screen, so nothing is offered there.
    private func selectionActions(for text: String) -> [TerminalMenuAction] {
        guard !kind.isTool else { return [] }
        var items: [TerminalMenuAction] = []
        // A remote session's paths are on another machine, so none are looked
        // for here.
        let folder: String? = kind.isRemote ? nil : currentDirectory
        switch TerminalSelection.classify(text, directory: folder, exists: { FileManager.default.fileExists(atPath: $0) }) {
        case .url(let address):
            if let page = TerminalLinks.webURL(address) {
                items.append(TerminalMenuAction(title: "Open Link", modifiers: []) {
                    WorkspaceStore.shared.openLinkFromTerminal(page.absoluteString)
                })
                items.append(TerminalMenuAction(title: "Open in Default Browser", modifiers: []) {
                    NSWorkspace.shared.open(page)
                })
            }
            items.append(TerminalMenuAction(title: "Copy Link", modifiers: []) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(address, forType: .string)
            })
        case .path(let path):
            var isFolder: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: path, isDirectory: &isFolder)
            items.append(TerminalMenuAction(title: "Reveal in Finder", modifiers: []) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            })
            // A file opens its folder, as in the file browser: there is no `cd`
            // to a file, and the folder is where you wanted to be.
            let tabFolder = isFolder.boolValue ? path : (path as NSString).deletingLastPathComponent
            items.append(TerminalMenuAction(title: "Open in New Tab", modifiers: []) {
                WorkspaceStore.shared.newTab(directory: tabFolder)
            })
            items.append(TerminalMenuAction(title: "Copy as Quoted Path", modifiers: []) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(EditorCommand.quote(path), forType: .string)
            })
        case .text:
            break
        }
        items.append(TerminalMenuAction(title: "Explain Selection", modifiers: []) {
            WorkspaceStore.shared.requestComposerHelp(.explainSelection, selection: text)
        })
        return items
    }

    /// What a right-click here offers beyond copy and paste. Splitting acts on
    /// the focused pane of the selected tab, which a right-click has just made
    /// this one (as does closing it) — so it only belongs to a terminal that is a pane. A bundled
    /// tool sits in a side panel and a dock terminal in the dock; "split" there
    /// would divide something the person was not pointing at.
    private func contextMenuActions() -> [TerminalMenuAction] {
        let store = WorkspaceStore.shared
        guard !kind.isTool, !store.isDockSession(id) else { return [] }
        return [
            TerminalMenuAction(title: "Split Right", key: "d") {
                store.splitFocusedPane(.horizontal, kind: .terminal)
            },
            TerminalMenuAction(title: "Split Down", key: "d", modifiers: [.command, .shift]) {
                store.splitFocusedPane(.vertical, kind: .terminal)
            },
            TerminalMenuAction(title: "New Tab", key: "t") {
                store.openTab()
            },
            TerminalMenuAction(title: "Close Pane", key: "w", modifiers: [.command, .shift]) {
                store.closeFocusedPane()
            },
        ]
    }

    var isRemote: Bool { kind.isRemote }

    var connection: SSHConnection? {
        guard let id = kind.connectionID else { return nil }
        return AppSettings.shared.sshConnections.first { $0.id == id }
    }

    /// Records a command line and shortens it for display.
    ///
    /// Only the program and its first argument are kept: a full command line
    /// with paths and flags is far wider than a sidebar row, and the head of
    /// it is what distinguishes one tab from another.
    private func noteCommand(_ command: String) {
        // The line buffer behind this assumes a shell prompt. Inside btop or
        // superfile, Enter confirms a selection, and what was "typed" before
        // it is navigation keys — recorded, it would retitle the panel "jjk".
        guard !kind.isTool else { return }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let words = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        let label = words.prefix(2).joined(separator: " ")
        lastCommand = label.isEmpty ? nil : label
    }

    var displayTitle: String {
        // A title the shell set itself wins: it is the most deliberate signal
        // available, and a program that sets one is saying what it is.
        if !title.isEmpty { return title }
        if let tool = kind.tool { return tool.title }
        if let lastCommand { return lastCommand }
        if let connection { return connection.name.isEmpty ? connection.destination : connection.name }
        let component = (currentDirectory as NSString).lastPathComponent
        return component.isEmpty ? "Terminal" : component
    }

    var abbreviatedDirectory: String {
        if isRemote { return connection?.subtitle ?? currentDirectory }
        let home = NSHomeDirectory()
        if currentDirectory == home { return "~" }
        if currentDirectory.hasPrefix(home + "/") {
            return "~" + currentDirectory.dropFirst(home.count)
        }
        return currentDirectory
    }

    /// "exit 1" after a command that failed, for the sidebar. Nil after one that
    /// succeeded, while one is running, and for a shell that does not report.
    var failedCommandNote: String? {
        guard let code = lastCommandResult?.exitCode, code != 0 else { return nil }
        return "exit \(code)"
    }

    /// A mark from the shell's own hooks.
    private func noteShellMark(_ mark: ShellIntegration.Mark) {
        guard shellIntegrationActive else { return }
        // A command is starting: whatever the last one did is no longer the news.
        if case .commandStart = mark { lastCommandResult = nil }
        let now = Date()
        guard let finished = commandTracker.handle(mark, at: now) else { return }
        lastCommandResult = CommandResult(exitCode: finished.exitCode, seconds: finished.seconds, finishedAt: now)
        announceIfLong(finished)
    }

    /// Says so when a command that ran for a long time ends where nobody is
    /// looking — by the same route as a bell, so it follows Settings → Terminal →
    /// Notifications (off, in-app marks, or system banners as well).
    private func announceIfLong(_ finished: ShellIntegration.Finished) {
        let settings = AppSettings.shared
        guard settings.notifyLongCommands,
              let seconds = finished.seconds,
              seconds >= Double(settings.longCommandSeconds) else { return }
        // A command finishing in the pane you are watching needs no announcing.
        guard !(WorkspaceStore.shared.focusedSessionID == id && NSApp.isActive) else { return }
        noteAttention(.osc777(
            title: "\(lastCommand ?? "Command") finished",
            body: ShellIntegration.summary(exitCode: finished.exitCode, seconds: seconds)
        ))
    }

    /// Short status for the sidebar: nil while healthy.
    var statusNote: String? {
        if launchError != nil { return "failed" }
        if hasStarted && !isRunning { return isRemote ? "disconnected" : "exited" }
        return nil
    }

    func startIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        startedAt = Date()
        launch()
    }

    /// Re-runs the session in place — the natural action after a remote
    /// connection drops or a launch failed.
    func reconnect() {
        guard !isRunning else { return }
        cancelAutoReconnect()
        reconnectAttempts = 0
        endedByUser = false
        launch()
    }

    /// Stops a reconnect that is counting down, from its banner.
    func stopAutoReconnect() {
        guard reconnectPlan != nil else { return }
        cancelAutoReconnect()
        reconnectAttempts = 0
        reconnectNote = "Automatic reconnecting was stopped."
    }

    /// `agentApproved` is nil on the first call. A connection set to ask whether
    /// to forward the agent puts the question and comes back here with the
    /// answer; anything else carries straight on.
    private func launch(agentApproved: Bool? = nil, unattended: Bool = false) {
        let settings = AppSettings.shared
        reconnectNote = nil
        localNetworkBlocked = false
        endProblem = nil
        // Watching from the first remote launch, so that when one drops it is
        // already known whether there is a network to reconnect over.
        if isRemote { NetworkWatch.shared.start() }
        // A host from an imported snapshot asks before anything else about the
        // connection, the agent included: whether to make it at all.
        if let connection = connectionAwaitingConfirmation(settings) {
            guard !awaitingImportAnswer else { return }
            awaitingImportAnswer = true
            ImportedHostPrompt.ask(about: connection.id) { [weak self] confirmed in
                guard let self else { return }
                self.awaitingImportAnswer = false
                // Closed while its question waited its turn: nothing to start.
                guard !self.endedByUser else { return }
                if confirmed {
                    self.launch(agentApproved: agentApproved, unattended: unattended)
                } else {
                    self.launchError = ImportedHostPrompt.declinedNote
                }
            }
            return
        }
        if agentApproved == nil, let connection = connectionThatAsksAboutAgent(settings) {
            guard !awaitingAgentAnswer else { return }
            awaitingAgentAnswer = true
            AgentForwardingPrompt.ask(for: connection) { [weak self] approved in
                guard let self else { return }
                self.awaitingAgentAnswer = false
                self.launch(agentApproved: approved)
            }
            return
        }
        switch SessionLaunch.configuration(
            for: kind,
            settings: settings,
            directory: isRemote ? nil : currentDirectory,
            shellOverride: shellOverride,
            controlPath: controlPath ?? sharedPathForSharing(settings),
            agentApproved: agentApproved ?? false,
            unattended: unattended,
            profile: settings.profile(withID: profileID)
        ) {
        case .success(let configuration):
            launchError = nil
            shellIntegrationActive = configuration.shellIntegration
            commandTracker = ShellIntegration.CommandTracker()
            lastCommandResult = nil
            // Before ssh connects, so macOS has its question up — if it still
            // has one to ask — rather than refusing the connection unasked.
            if let connection, LocalNetwork.isLocal(host: connection.host) {
                LocalNetworkPermission.ask()
            }
            engine.start(configuration)
            launchedAt = Date()
            isRunning = true
            lastExitCode = nil
            lastActivityAt = Date()
            EventBus.shared.publish(APIEvent("session.started", [
                "session": id.uuidString,
                "remote": isRemote,
                "directory": currentDirectory,
            ]))
            if !isRemote { refreshGitBranch() }
        case .failure(let error):
            launchError = error.localizedDescription
            isRunning = false
        }
    }

    /// Where this tab's ssh should listen so the file browser, the port scan and
    /// the forwards can use its sign-in, when sharing is on (Settings →
    /// Connections) or Remote Ports is, and nothing else decided it.
    ///
    /// Only for an ssh connection, and only when the socket can be made
    /// privately (`SSHControlSocket.prepare` says so); otherwise the tab is
    /// exactly what it was. The file browser, the scan and the forwards sign in
    /// with a key or the agent without it, so this only matters for a host that
    /// wants a password: signed in to once in a tab, the rest ride on it.
    private func sharedPathForSharing(_ settings: AppSettings) -> String? {
        guard settings.shareSignInWithFiles || settings.showRemotePorts,
              case .remote(let id) = kind,
              let connection = settings.sshConnections.first(where: { $0.id == id }),
              connection.transport == .ssh,
              case .master(let path) = SSHControlSocket.prepare(for: connection, base: NSTemporaryDirectory())
        else { return nil }
        return path
    }

    /// The saved connection this session is for, when it came in an imported
    /// snapshot and nobody on this Mac has chosen to connect to it yet. Not one
    /// that would be refused anyway — no address, or one that cannot go on a
    /// command line — where the refusal says what to fix, and the question
    /// waits for a connection that can be made.
    private func connectionAwaitingConfirmation(_ settings: AppSettings) -> SSHConnection? {
        guard case .remote(let id) = kind,
              let connection = settings.sshConnections.first(where: { $0.id == id }),
              connection.confirmBeforeConnecting,
              connection.hasHost,
              connection.connectionRefusal == nil else { return nil }
        return connection
    }

    /// The saved connection this session is for, when it is an ssh one set to
    /// ask before the agent is forwarded. mosh and a custom command do not take
    /// ssh's `-A`, so there is nothing to ask about for them.
    private func connectionThatAsksAboutAgent(_ settings: AppSettings) -> SSHConnection? {
        guard case .remote(let id) = kind,
              let connection = settings.sshConnections.first(where: { $0.id == id }),
              connection.transport == .ssh,
              connection.agentForwarding.needsAnswer else { return nil }
        return connection
    }

    func send(text: String) {
        engine.send(text: text)
    }

    /// Visible screen contents, used by the local API's capture command.
    func captureVisibleText() -> String {
        engine.captureVisibleText()
    }

    /// Scrollback plus screen, saved when a session closes so Recents can
    /// show it again.
    func captureScrollback(maxBytes: Int) -> String {
        engine.captureScrollback(maxBytes: maxBytes)
    }

    /// Paints a previous session's contents into this one, above its own
    /// prompt. Nothing is sent to the shell — this is a record, not a replay.
    func displayRestored(_ transcript: String) {
        guard !transcript.isEmpty else { return }
        engine.display(text: transcript)
        engine.display(text: "\r\n\u{1B}[2m— end of restored session —\u{1B}[0m\r\n")
    }

    /// How see-through this terminal's background is. A bundled tool is always
    /// solid: it sits in a side panel that paints an opaque surface of its own,
    /// so a translucent terminal there would only tint that surface — and
    /// btop and superfile are drawn for a background of a known colour.
    private func effectiveBackgroundOpacity(_ settings: AppSettings) -> Double {
        kind.isTool ? 1 : BackgroundOpacity.clamped(settings.backgroundOpacity)
    }

    /// The profile whose theme and font this terminal is drawn with: the one a
    /// local shell was opened with, or the one a saved host is set to use. Nil
    /// when there is none, it has been deleted, or this is a bundled tool.
    private func appearanceProfile(_ settings: AppSettings) -> TerminalProfile? {
        if kind.isTool { return nil }
        if let connectionID = kind.connectionID {
            let host = settings.sshConnections.first { $0.id == connectionID }
            return settings.profile(withID: host?.profileID)
        }
        return settings.profile(withID: profileID)
    }

    /// Pushes font, colors, ANSI palette, and the GPU renderer preference
    /// into the engine. Safe to call on every SwiftUI update — the engine
    /// ignores values that haven't changed.
    /// Pushes theme, font and rendering settings into the engine.
    ///
    /// Called from `TerminalHostView.updateNSView`, which SwiftUI runs on
    /// every layout pass — so this runs on every frame of a window resize, a
    /// panel drag, or a split seam being moved, once per visible terminal.
    /// Unguarded it did real work each time: constructing an `NSFont`,
    /// rebuilding the full colour palette, and re-asking SwiftTerm about Metal.
    /// That is what made resizing feel heavy. The inputs are cheap to compare,
    /// so compare them and do nothing when a redraw is just a redraw.
    func applyStyling(settings: AppSettings, darkMode: Bool) {
        // A profile's own theme and font, where it made a choice; otherwise
        // the settings. A bundled tool has no profile.
        let look = TerminalProfile.appearance(
            of: appearanceProfile(settings),
            themeID: settings.terminalThemeID,
            fontName: settings.terminalFontName,
            fontSize: settings.terminalFontSize
        )
        let inputs = StylingInputs(
            themeID: look.themeID,
            appThemeID: settings.appThemeID,
            darkMode: darkMode,
            fontName: look.fontName,
            fontSize: look.fontSize,
            backgroundOpacity: effectiveBackgroundOpacity(settings),
            gpuRequested: settings.useGPURendering,
            cursorStyleTag: settings.cursorStyleTag,
            cursorAnimationTag: settings.cursorAnimationTag,
            cursorColorHex: settings.cursorColorHex,
            cursorTextColorHex: settings.cursorTextColorHex,
            selectionColorHex: settings.selectionColorHex,
            boldAsBright: settings.boldAsBright,
            optionAsMeta: settings.optionAsMeta,
            lineSpacing: settings.terminalLineSpacing
        )
        guard inputs != appliedStyling else { return }
        appliedStyling = inputs

        let theme = settings.resolvedTerminalTheme(id: look.themeID, darkMode: darkMode)
        engine.applyPalette(theme.palette)
        engine.apply(TerminalAppearance(
            font: settings.resolvedTerminalFont(name: look.fontName, size: look.fontSize),
            background: theme.backgroundColor,
            foreground: theme.foregroundColor,
            backgroundAlpha: CGFloat(inputs.backgroundOpacity),
            // A bundled tool draws its own colours and keeps its own cursor.
            cursorColor: kind.isTool ? nil : settings.colorOverride(inputs.cursorColorHex),
            cursorTextColor: kind.isTool ? nil : settings.colorOverride(inputs.cursorTextColorHex),
            selectionColor: settings.colorOverride(inputs.selectionColorHex),
            boldAsBright: inputs.boldAsBright,
            // A bundled tool keeps the keyboard it was built against.
            optionAsMeta: kind.isTool ? true : inputs.optionAsMeta,
            lineSpacing: kind.isTool ? 1 : CGFloat(inputs.lineSpacing)
        ))
        let active = engine.setGPUAcceleration(settings.useGPURendering)
        // Published a turn later: this is called from `updateNSView`, which runs
        // inside a SwiftUI view update, where changing observable state is
        // logged as a fault ("Publishing changes from within view updates").
        if isGPUAccelerated != active {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isGPUAccelerated != active else { return }
                self.isGPUAccelerated = active
            }
        }
        // After the renderer is settled: an animation is only drawn on the CPU
        // one. A bundled tool keeps the cursor it asks for.
        if !kind.isTool {
            engine.applyCursor(
                styleTag: settings.cursorStyleTag,
                animation: CursorAnimation(rawValue: settings.cursorAnimationTag) ?? .none
            )
        }
        // A bundled tool follows the palette the terminal just took on —
        // a theme picked in Settings, or the switch to or from dark mode.
        if let tool = kind.tool, ToolTheming.follow(theme, tool: tool) {
            reloadToolTheme()
        }
    }

    /// Tells a running btop to reread the theme `ToolTheming` just rewrote.
    /// superfile draws in the terminal's palette, so it has already changed
    /// and needs nothing.
    ///
    /// SIGUSR2's default action is to terminate, and btop installs its
    /// handler a moment after it starts. A theme change inside that moment —
    /// dark mode switching as the panel opens — would kill btop instead of
    /// restyling it, so the signal waits until btop has run for two seconds.
    private func reloadToolTheme() {
        guard kind.tool == .btop, isRunning else { return }
        let pid = engine.shellPID
        guard pid > 0 else { return }
        let settle: TimeInterval = 2
        let running = launchedAt.map { Date().timeIntervalSince($0) } ?? settle
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, settle - running)) { [weak self] in
            // Still the same btop: not quit, and not restarted since.
            guard let self, self.isRunning, self.engine.shellPID == pid else { return }
            kill(pid, SIGUSR2)
        }
    }

    func terminate() {
        // Before the guard: a tab closed while it waits to reconnect must not.
        endedByUser = true
        cancelAutoReconnect()
        guard hasStarted, isRunning else { return }
        engine.terminate()
        isRunning = false
    }

    // MARK: Automatic reconnect

    /// Called when the process has ended. Starts it again after a wait if
    /// `AutoReconnect` says so; every rule about when not to is there.
    private func considerAutoReconnect(terminationStatus: Int32?, ranFor: TimeInterval) {
        // One already waiting is the answer to this end too.
        guard reconnectPlan == nil else { return }
        guard AppSettings.shared.autoReconnect, !endedByUser,
              let connection, AutoReconnect.isEligible(connection) else {
            reconnectAttempts = 0
            return
        }
        // What ssh printed last says whether a retry could work.
        let tail = AutoReconnect.tail(of: engine.captureScrollback(maxBytes: 4_096))
        let decision = AutoReconnect.decide(
            terminationStatus: terminationStatus,
            ranFor: ranFor,
            attemptsSoFar: reconnectAttempts,
            cause: AutoReconnect.cause(ofOutput: tail, connection: connection),
            jitterSample: Double.random(in: 0..<1)
        )
        switch decision {
        case .retry(let delay, let attempt):
            reconnectAttempts = attempt
            reconnectNote = nil
            if NetworkWatch.shared.isOnline {
                scheduleAutoReconnect(after: delay, attempt: attempt)
            } else {
                holdForNetwork(attempt: attempt)
            }
        case .stop(let reason):
            reconnectAttempts = 0
            reconnectNote = reason.note
        }
    }

    /// Try number `attempt` starts after `delay`, unless the network comes back
    /// first and brings it forward (`networkMayHaveReturned`).
    private func scheduleAutoReconnect(after delay: TimeInterval, attempt: Int) {
        reconnectWork?.cancel()
        reconnectPlan = ReconnectPlan(
            attempt: attempt,
            total: AutoReconnect.standard.maxAttempts,
            at: Date().addingTimeInterval(delay)
        )
        watchNetwork()
        let work = DispatchWorkItem { [weak self] in self?.runAutoReconnect() }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Try number `attempt` waits for a network to make it over: a try made
    /// with none could not work, and would use up one of the few there are.
    private func holdForNetwork(attempt: Int) {
        reconnectWork?.cancel()
        reconnectWork = nil
        reconnectPlan = ReconnectPlan(
            attempt: attempt,
            total: AutoReconnect.standard.maxAttempts,
            at: Date(),
            waitingForNetwork: true
        )
        watchNetwork()
    }

    private func watchNetwork() {
        guard networkSubscription == nil else { return }
        networkSubscription = NotificationCenter.default
            .publisher(for: NetworkWatch.mayReconnect)
            .sink { [weak self] _ in self?.networkMayHaveReturned() }
    }

    /// There is a network again, a different one, or the Mac has woken: a try
    /// that is waiting starts within a few seconds rather than when its wait
    /// would have ended. It is still the same try, counted the same way.
    private func networkMayHaveReturned() {
        guard let plan = reconnectPlan, !isRunning, !endedByUser else { return }
        let remaining: TimeInterval? = plan.waitingForNetwork ? nil : max(0, plan.at.timeIntervalSinceNow)
        let delay = AutoReconnect.waitAfterNetworkReturns(remaining: remaining, jitterSample: Double.random(in: 0..<1))
        scheduleAutoReconnect(after: delay, attempt: plan.attempt)
    }

    /// The wait is over. Checked again because the person may have turned it
    /// off, closed the tab or reconnected by hand in the meantime — and the
    /// network may have gone, in which case the try waits for it.
    private func runAutoReconnect() {
        reconnectWork = nil
        guard let plan = reconnectPlan else { return }
        guard NetworkWatch.shared.isOnline else {
            holdForNetwork(attempt: plan.attempt)
            return
        }
        reconnectPlan = nil
        guard !isRunning, !endedByUser, AppSettings.shared.autoReconnect,
              let connection, AutoReconnect.isEligible(connection) else { return }
        // `agentApproved` is given, so nothing is asked; a connection that asks
        // is not eligible, and was checked again just above.
        launch(agentApproved: false, unattended: true)
    }

    private func cancelAutoReconnect() {
        reconnectWork?.cancel()
        reconnectWork = nil
        reconnectPlan = nil
    }

    // MARK: Attention

    /// Marks this session as needing attention and publishes `session.attention`.
    ///
    /// Identical repeats within ~1s are coalesced so a ringing bell cannot
    /// flood the bus, but a genuinely different message is reported straight
    /// away rather than being swallowed by an unrelated bell a moment earlier.
    func noteAttention(_ attention: TerminalAttention) {
        // Off means off, for the mark, the bus and the banner alike.
        // Publishing regardless meant a user who had turned pane attention off
        // still saw every bell — and every OSC title and body — on
        // `iterminalctl subscribe events=*`.
        let mode = AttentionSettings.shared.mode
        guard mode != .off else { return }

        let focused = WorkspaceStore.shared.focusedSessionID == id

        // Two separate questions, and the mark answers the one the debounce
        // does not.
        //
        // Pane focus alone is not "the user can see this": a tab with a single
        // pane always holds focus, so a backgrounded app left the headline
        // case — build finishes while you are in another app — marking
        // nothing at all. This is the same test the system banner already
        // applies; the two disagreeing is what made a banner fire with no
        // matching sidebar mark.
        //
        // The mark is also set before the debounce, not after. It is an
        // idempotent flag rather than an event, so throttling it gains
        // nothing, and setting it afterwards meant a pane ringing faster than
        // once a second was never marked at all.
        if !focused || !NSApp.isActive {
            needsAttention = true
        }

        // Only the event and the banner are throttled. The window is not
        // extended by a repeat, so a pane that keeps ringing keeps reporting
        // about once a second instead of falling silent after the first.
        let now = Date()
        let fingerprint = attentionFingerprint(attention)
        if now.timeIntervalSince(lastAttentionAt) < 1.0,
           lastAttentionFingerprint == fingerprint {
            return
        }
        lastAttentionAt = now
        lastAttentionFingerprint = fingerprint

        var data: [String: Any] = [
            "session": id.uuidString,
            "kind": attention.kindName,
            "focused": focused,
        ]
        if let title = attention.title { data["title"] = title }
        if let body = attention.body { data["body"] = body }
        EventBus.shared.publish(APIEvent("session.attention", data))

        // Checked here, not only inside maybeNotify: touching `.shared` builds
        // a UNUserNotificationCenter, which raises in a process without a
        // valid bundle and signature. Behind the guard it is only ever built
        // when the user has actually asked for system banners.
        if mode == .inAppAndSystem {
            AttentionNotifier.shared.maybeNotify(attention, session: self, sessionFocused: focused)
        }
    }

    /// Clears the sidebar attention mark once the user is looking at this pane.
    func clearAttention() {
        guard needsAttention || lastAttentionFingerprint != nil else { return }
        needsAttention = false
        // Reset debounce so a new bell/OSC after the user leaves this pane is
        // not swallowed by the previous attention's 1s window.
        lastAttentionAt = .distantPast
        lastAttentionFingerprint = nil
    }

    private func attentionFingerprint(_ attention: TerminalAttention) -> String {
        switch attention {
        case .bell:
            return "bell"
        case .osc9(let message):
            return "osc9:" + message
        case .osc777(let title, let body):
            return "osc777:" + (title ?? "") + "|" + (body ?? "")
        }
    }

    // MARK: Git metadata

    private func refreshGitBranch() {
        let directory = currentDirectory
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let branch = Self.gitBranch(startingAt: directory)
            DispatchQueue.main.async {
                self?.gitBranch = branch
            }
        }
    }

    /// Walks up from `path` looking for a git directory; returns the branch
    /// name, a short SHA when detached, or nil outside a repository.
    static func gitBranch(startingAt path: String) -> String? {
        var url = URL(fileURLWithPath: path)
        for _ in 0..<16 {
            if let gitDirectory = resolveGitDirectory(url.appendingPathComponent(".git")),
               let contents = try? String(contentsOf: gitDirectory.appendingPathComponent("HEAD"), encoding: .utf8) {
                let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
                let refPrefix = "ref: refs/heads/"
                if trimmed.hasPrefix(refPrefix) {
                    return String(trimmed.dropFirst(refPrefix.count))
                }
                return String(trimmed.prefix(7))
            }
            if url.path == "/" { break }
            url.deleteLastPathComponent()
        }
        return nil
    }

    /// `.git` is a directory in an ordinary clone, but a *file* containing
    /// `gitdir: <path>` inside linked worktrees and submodules — follow that
    /// pointer so branch detection works in both layouts.
    private static func resolveGitDirectory(_ dotGit: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue { return dotGit }

        guard let contents = try? String(contentsOf: dotGit, encoding: .utf8) else { return nil }
        let prefix = "gitdir:"
        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix) else { continue }
            let target = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else { continue }
            if target.hasPrefix("/") {
                return URL(fileURLWithPath: target)
            }
            return URL(fileURLWithPath: target, relativeTo: dotGit.deletingLastPathComponent())
                .standardizedFileURL
        }
        return nil
    }
}

extension TerminalSession: TerminalEngineDelegate {
    func engineTitleChanged(_ title: String) {
        self.title = title
        EventBus.shared.publish(APIEvent("session.title", [
            "session": id.uuidString,
            "title": title,
        ]))
    }

    /// Re-reads the shell's working directory from the kernel.
    ///
    /// Only meaningful for local sessions: a remote session's local child is
    /// `ssh`, whose working directory is this Mac's and says nothing about
    /// where you are on the far end. Those still depend on OSC 7.
    func refreshDirectoryFromProcess() {
        guard !isRemote, isRunning else { return }
        guard let path = ProcessDirectory.path(forPID: engine.shellPID),
              path != currentDirectory else { return }
        applyDirectory(path)
    }

    func engineDirectoryChanged(_ directory: String?) {
        guard let directory else { return }
        // OSC 7 reports a file:// URL; fall back to a plain path.
        let path: String
        if directory.hasPrefix("file://"), let url = URL(string: directory) {
            path = url.path
        } else {
            path = directory
        }
        guard !path.isEmpty, path != currentDirectory else { return }
        applyDirectory(path)
    }

    /// Shared by both routes into a directory change — the OSC 7 escape a
    /// cooperating shell emits, and the kernel read that covers every shell
    /// that doesn't.
    private func applyDirectory(_ path: String) {
        currentDirectory = path
        if !isRemote { refreshGitBranch() }
        EventBus.shared.publish(APIEvent("session.directory", [
            "session": id.uuidString,
            "directory": path,
        ]))
        WorkspaceStore.shared.scheduleSave()
    }

    func engineProcessTerminated(exitCode: Int32?) {
        isRunning = false
        // What the engine hands over is the raw wait status; what is shown and
        // published is the exit code, as a shell's `$?` has it.
        let code = ExitStatus.code(fromWaitStatus: exitCode)
        lastExitCode = code
        EventBus.shared.publish(APIEvent("session.exited", [
            "session": id.uuidString,
            "exitCode": code ?? -1,
            "remote": isRemote,
        ]))
        // The last of what ssh printed is still on its way from the pty, and the
        // decision reads it, so the decision waits a moment for it.
        let launched = launchedAt
        let ranFor = launched.map { Date().timeIntervalSince($0) } ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            // Not if it has been started again, or ended, in that moment.
            guard let self, !self.isRunning, self.launchedAt == launched else { return }
            self.considerAutoReconnect(terminationStatus: exitCode, ranFor: ranFor)
            self.noteLocalNetworkBlock(terminationStatus: exitCode)
            self.noteEndProblem(terminationStatus: exitCode, ranFor: ranFor)
        }
    }

    /// Names on the banner what ssh said went wrong, when it said more than
    /// that the session ended (see `TabConnectionProblem`). Not while a
    /// reconnect is waiting — that banner counts down — nor over the Local
    /// Network note, which says the same thing more exactly for that case.
    private func noteEndProblem(terminationStatus: Int32?, ranFor: TimeInterval) {
        guard reconnectPlan == nil, !localNetworkBlocked, !endedByUser, let connection else { return }
        let tail = AutoReconnect.tail(of: engine.captureScrollback(maxBytes: 4_096))
        endProblem = TabConnectionProblem.diagnose(
            tail: tail,
            connection: connection,
            terminationStatus: terminationStatus,
            ranFor: ranFor
        )
    }

    /// Says on the banner when ssh could not reach a host on the local network,
    /// since the likeliest reason is one only System Settings can change. Not
    /// while a reconnect is waiting: that banner says something else.
    private func noteLocalNetworkBlock(terminationStatus: Int32?) {
        guard reconnectPlan == nil, let connection, LocalNetwork.isLocal(host: connection.host),
              AutoReconnect.isConnectionError(terminationStatus: terminationStatus) else { return }
        let tail = AutoReconnect.tail(of: engine.captureScrollback(maxBytes: 4_096))
        guard LocalNetwork.looksBlocked(output: tail) else { return }
        localNetworkBlocked = true
        reconnectNote = LocalNetwork.endNote(host: connection.host)
    }
}
