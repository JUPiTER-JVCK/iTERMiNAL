#if SCREENSHOTS
import AppKit
import SwiftUI
import WebKit

/// What each picture is of, and how the app is put into it. See
/// ScreenshotMode.swift.
///
/// The scenes share one running app, so each starts from `baseline()` and
/// leaves the app as it found it — or as near as the next one needs. The order
/// matters in three places: the HTTP scenes come before the ones that show the
/// sample site's request log, the assistant scenes come last because what they
/// send stays in the composer's history, and the Settings windows come after
/// everything that needs the main window to be the one in front.
///
/// A scene that cannot run (a tool this build does not have, a window that did
/// not come up) says so in the log and writes nothing; the rest carry on.
@MainActor
final class ScreenshotRun {
    private let window: NSWindow
    private let directory: URL
    private let store = WorkspaceStore.shared
    private let settings = AppSettings.shared
    /// The sample project, and the file the sample site logs its requests to.
    private let demo: String?
    private let fixtureLog: String?

    /// Made by `workspace()`, and what the scenes after it are about.
    private var server: WorkspaceTab?
    private var docs: WorkspaceTab?

    private static let site = "http://localhost:8765"
    /// Where the assistant is pointed: the address Ollama's preset uses,
    /// answered by the same sample server the workflow starts on that port.
    private static let assistant = "http://127.0.0.1:11434/v1"

    /// What the composer shows in the hero picture: a command word, flags, a
    /// string, a pipe and a redirect, to show the input's colouring.
    private static let composerSample = #"git log --oneline --graph -n 20 | grep -i "merge" > merges.txt"#

    private static let notes = """
        Standup — Thursday

        • Pagination is merged; add a line to the changelog
        • Rate limit is 60 requests a minute per address — check with Jonas
        • Deploy window is 14:00 (two replicas)

        To do
          ☐ filter users by role (?role=editor)
          ☐ cursor pagination
          ☐ bump to v0.4.0

        Commands I keep forgetting
          git log --oneline --graph --decorate
          kubectl rollout status deploy/hello-api
        """

    /// Invented hosts, on names reserved for examples.
    private static let hosts = [
        SSHConnection(name: "build-box", host: "build.example.com", username: "deploy"),
        SSHConnection(name: "staging", host: "staging.example.com", username: "deploy", transport: .mosh),
        SSHConnection(name: "pi-lab", host: "192.0.2.14", port: 2222, username: "pi"),
    ]

    init(window: NSWindow, directory: URL) {
        self.window = window
        self.directory = directory
        let environment = ProcessInfo.processInfo.environment
        demo = environment[ScreenshotMode.demoVariable]
        fixtureLog = environment[ScreenshotMode.logVariable]
    }

    // MARK: Running

    func runAll() async {
        // Dark, with everything else at its default: the look most people see
        // the app in, and what the README describes. The CPU and memory of the
        // machine it happens to run on are not part of that.
        settings.theme = .dark
        settings.composerEnabled = true
        settings.railPanelOpen = true
        settings.railPanelPinned = true
        settings.showSystemMetrics = false
        settings.composerCollapsed = false
        settings.sshConnections = Self.hosts
        // Set up before anything has asked whether an assistant is: the
        // composer remembers the answer for half a minute, and a "no" from
        // before this would still be in force when the offer scene runs.
        settings.assistantBaseURL = Self.assistant
        settings.assistantModel = "llama3.2"

        await ScreenshotMode.bringToFront(window)
        ScreenshotMode.fit(window)
        await pause(1.5)
        say("main window: \(ScreenshotMode.describe(window))")

        await scene("workspace") { await self.workspace() }

        await scene("composer-ghost") { await self.composerGhost() }
        await scene("composer-history") { await self.composerHistory() }
        await scene("composer-completion") { await self.composerCompletion() }

        await scene("http-client") { await self.httpRequest() }
        await scene("site-explorer") { await self.siteExplorer() }

        await scene("split-panes") { await self.splitPanes() }
        await scene("landing") { await self.landing() }
        await scene("dock") { await self.dock() }
        await scene("tasks") { await self.tasks() }

        await scene("browser") { await self.browser() }
        await scene("files") { await self.files() }
        await scene("notes") { await self.notesPanel() }
        await scene("superfile") { await self.tool(.superfile, panel: .superfile, name: "superfile", settle: 3) }
        await scene("btop") {
            self.speedUpBtop()
            return await self.tool(.btop, panel: .btop, name: "btop", settle: 24)
        }

        await scene("command-palette") { await self.palette() }
        await scene("keyboard-shortcuts") { await self.shortcuts() }

        await scene("light-theme") { await self.lightTheme() }
        await scene("custom-look") { await self.customLook() }

        await scene("ai-assistant") { await self.assistantReply() }
        await scene("error-help") { await self.errorHelp() }

        await settingsWindows()
    }

    private func scene(_ name: String, _ body: @MainActor () async -> Bool) async {
        say("scene \(name)…")
        let ok = await body()
        say("scene \(name): \(ok ? "ok" : "no picture")")
    }

    private func say(_ message: String) { ScreenshotMode.say(message) }
    private func pause(_ seconds: TimeInterval) async { await ScreenshotMode.pause(seconds) }

    private func capture(_ name: String, overlays: [ScreenshotMode.Overlay] = []) -> Bool {
        ScreenshotMode.capture(window, name, in: directory, overlays: overlays)
    }

    private func compose(_ text: String) {
        if !ScreenshotMode.typeIntoComposer(text, in: window) { say("no composer to type into") }
    }

    /// The arrangement every picture starts from: the server tab in front with
    /// the sidebar beside it, no panel, dock, sheet or page over it, and
    /// nothing in the composer.
    private func baseline() async {
        closePanels()
        store.closeBottomDock()
        store.detailMode = .terminal
        store.showCommandPalette = false
        store.showKeyboardShortcuts = false
        settings.railPanelOpen = true
        settings.composerCollapsed = false
        if let server {
            store.selectedTabID = server.id
            store.focusedSessionID = server.primarySession?.id
        }
        await ScreenshotMode.bringToFront(window)
        // Not before the window has put the composer back: after a panel that
        // covered the whole surface, there is nothing to clear until it has.
        await pause(0.8)
        compose("")
        // The sidebar starts with its folders shut, and is built afresh each
        // time it is brought back.
        NotificationCenter.default.post(name: .screenshotsExpandSidebar, object: nil)
        await pause(0.4)
    }

    private func closePanels() {
        for panel in SidePanel.allCases { store.closePanel(panel) }
        store.closeRightRegion()
    }

    /// Runs `command` in `session` the way a person would: the screen cleared,
    /// then the command as a line of its own. Typed as one line, `clear; git
    /// log` would name the tab "clear; git" in the sidebar and the task list,
    /// which name a tab by the first words of what it was last given.
    private func run(_ command: String, in session: TerminalSession?) async {
        guard let session else { return }
        session.send(text: "clear\n")
        await pause(0.4)
        session.send(text: command + "\n")
    }

    /// The server tab's terminal, for the pictures where it sits beside a
    /// panel: a command whose lines fit a narrow pane, because lines that wrap
    /// look like a bug.
    private func tidyServer() async {
        await run("git log --oneline --decorate -n 12", in: server?.primarySession)
        await pause(1.5)
    }

    /// The server tab's terminal with the whole picture of the history in it,
    /// for the pictures where the window is what is being looked at.
    private func showHistory() async {
        await run("git log --oneline --graph --decorate -n 14; echo; ls -F", in: server?.primarySession)
        await pause(1.5)
    }

    // MARK: The workspace

    private func workspace() async -> Bool {
        guard let hello = store.workspaces.first else { return false }
        hello.name = "hello-api"
        server = hello.tabs.first
        server?.customName = "server"
        let tests = store.newTab(in: hello, directory: demo)
        tests.customName = "tests"

        store.newWorkspace(named: "infra")
        let infra = store.workspaces.last
        infra?.tabs.first?.customName = "deploy"
        docs = store.newTab(in: infra, directory: demo.map { $0 + "/docs" })
        docs?.customName = "docs"
        if let server { store.togglePin(server) }

        // A tab opened and shut again, so Recents has something in it — and
        // open, so the sidebar shows it.
        let logs = store.newTab(in: hello, directory: demo)
        logs.customName = "logs"
        settings.recentsExpanded = true

        // The tabs nobody is looking at get their output now; the one in the
        // picture is shown first, so it is sized to its window before anything
        // is printed into it.
        await pause(2.0)
        await run("git status -sb; git diff --stat", in: tests.primarySession)
        await run("ls -F", in: infra?.tabs.first?.primarySession)
        await run("ls -F", in: docs?.primarySession)
        await run("git log --oneline -n 3", in: logs.primarySession)
        await pause(1.5)
        store.closeTab(logs)

        guard let shown = server, let session = shown.primarySession else { return false }
        store.selectedTabID = shown.id
        store.focusedSessionID = session.id
        await pause(2.0)
        await run("git log --oneline --graph --decorate -n 14; echo; ls -F", in: session)
        await pause(2.5)
        NotificationCenter.default.post(name: .screenshotsExpandSidebar, object: nil)
        say("composer: \(ScreenshotMode.typeIntoComposer(Self.composerSample, in: window) ? "typed" : "no input field found")")
        await pause(1.5)
        return capture("workspace")
    }

    // MARK: The composer

    /// The rest of a command you have run before, in grey after the caret.
    private func composerGhost() async -> Bool {
        await baseline()
        _ = ScreenshotMode.focusComposer(in: window)
        compose("curl -s local")
        await pause(1.2)
        let taken = capture("composer-ghost")
        compose("")
        return taken
    }

    /// ⌃R: a list that searches what you have run.
    private func composerHistory() async -> Bool {
        await baseline()
        _ = ScreenshotMode.focusComposer(in: window)
        compose("git")
        await pause(0.6)
        ScreenshotMode.pressControlR(in: window)
        await pause(1.4)
        let taken = capture("composer-history")
        ScreenshotMode.pressEscape(in: window)
        compose("")
        return taken
    }

    /// ⇥: file names, from the directory the command would run in.
    private func composerCompletion() async -> Bool {
        await baseline()
        _ = ScreenshotMode.focusComposer(in: window)
        compose("cat ")
        await pause(0.6)
        ScreenshotMode.pressTab(in: window)
        await pause(1.4)
        let taken = capture("composer-completion")
        ScreenshotMode.pressEscape(in: window)
        compose("")
        return taken
    }

    // MARK: The HTTP client

    private func httpRequest() async -> Bool {
        await baseline()
        store.openPanelExpanded(.http)
        await pause(1.5)
        let model = store.panelHTTPClient
        model.mode = .request
        model.method = .get
        model.urlText = "\(Self.site)/api/users"
        model.headerFields = [
            HTTPHeaderField(name: "Accept", value: "application/json"),
            HTTPHeaderField(name: "Cache-Control", value: "no-cache"),
        ]
        model.send(settings: settings)
        let finished = await ScreenshotMode.until(timeout: 20) { !model.isSending }
        say("request finished: \(finished)")
        await pause(1.0)
        // The response is the point of this picture, so it gets the room.
        ScreenshotMode.giveResponseRoom(in: window)
        // And the app's own CPU reading, in the sidebar, a moment to come
        // back down from sending and laying this out.
        await pause(3.5)
        return capture("http-client")
    }

    private func siteExplorer() async -> Bool {
        let model = store.panelHTTPClient
        model.mode = .explore
        await pause(1.5)
        await explore("open \(Self.site)", model.explorer)
        await explore("ls -l", model.explorer)
        await explore("cd docs", model.explorer)
        await explore("tree -L 2", model.explorer)
        await pause(1.0)
        let taken = capture("site-explorer")
        closePanels()
        return taken
    }

    /// One line at the explorer's prompt, then until what it started is done.
    private func explore(_ line: String, _ explorer: SiteExplorerModel) async {
        explorer.input = line
        explorer.submit(settings: settings)
        _ = await ScreenshotMode.until(timeout: 30) { !explorer.isWorking }
        await pause(0.5)
    }

    // MARK: Layout

    private func splitPanes() async -> Bool {
        await baseline()
        guard let tab = docs, let first = tab.primarySession else { return false }
        store.selectedTabID = tab.id
        store.focusedSessionID = first.id
        // The sidebar gives its width to the panes, which are what this
        // picture is of; lines that wrap in a narrow pane look like a bug. The
        // composer is put down to its pill, which covers none of them.
        settings.railPanelOpen = false
        settings.composerCollapsed = true
        await pause(2.0)
        _ = store.splitFocusedPane(.horizontal, kind: .terminal)
        _ = store.splitFocusedPane(.vertical, kind: .files)
        await pause(2.5)

        let sessions = tab.root.allSessions()
        await run("git log --oneline -n 14", in: sessions.first)
        if sessions.count > 1 {
            await run(fixtureLog.map { "tail -n 14 '\($0)'" } ?? "ls -F", in: sessions[1])
        }
        await pause(2.5)
        let taken = capture("split-panes")
        settings.composerCollapsed = false
        return taken
    }

    /// What shows when no tab is open: the quick-start cards, and the commands
    /// from the shell's history.
    private func landing() async -> Bool {
        await baseline()
        // Without the sidebar the cards fit on one row, clear of the composer.
        settings.railPanelOpen = false
        store.selectedTabID = nil
        await pause(1.8)
        guard store.selectedTab == nil else {
            say("landing: a tab is still selected")
            return false
        }
        let taken = capture("landing")
        store.selectedTabID = server?.id
        return taken
    }

    private func dock() async -> Bool {
        await baseline()
        settings.bottomDockHeight = 250
        store.toggleBottomDock()
        await pause(2.5)
        guard let first = store.dockSessions.first else { return false }
        await run("git status -sb; git log --oneline -n 5", in: first)
        // The newest tab is the one shown: put back, an older one has come up
        // empty in a picture before.
        let second = store.newDockSession(directory: demo.map { $0 + "/docs" })
        await pause(2.5)
        await run(fixtureLog.map { "tail -n 12 -f '\($0)'" } ?? "ls -F", in: second)
        await pause(2.5)
        ScreenshotMode.describeTerminals(in: window, label: "dock")
        say("dock: the new tab holds \(second.captureVisibleText().count) characters")
        let taken = capture("dock")
        // The first tab again, for comparison.
        store.selectedDockSessionID = first.id
        await pause(2.5)
        ScreenshotMode.describeTerminals(in: window, label: "dock, first tab")
        say("dock: the first tab holds \(first.captureVisibleText().count) characters")
        _ = capture("dock-first")
        store.closeBottomDock()
        return taken
    }

    private func tasks() async -> Bool {
        await baseline()
        store.detailMode = .tasks
        await pause(1.8)
        let taken = capture("tasks")
        store.detailMode = .terminal
        return taken
    }

    // MARK: Panels

    private func browser() async -> Bool {
        await baseline()
        settings.railPanelOpen = false
        settings.rightPanelWidth = 560
        store.openPanel(.browser)
        await pause(1.0)
        let tabs = store.panelBrowserTabs
        guard let first = tabs.tabs.first else { return false }
        first.urlText = Self.site + "/"
        first.loadCurrentText()
        tabs.newTab(url: Self.site + "/docs/")
        tabs.newTab(url: Self.site + "/changelog")
        tabs.selectedID = first.id
        let loaded = await ScreenshotMode.until(timeout: 25) {
            tabs.tabs.allSatisfy { $0.hasNavigated && !$0.isLoading && !$0.pageTitle.isEmpty }
        }
        say("browser: pages loaded: \(loaded) — \(tabs.tabs.map { "\($0.pageTitle.isEmpty ? "(no title)" : $0.pageTitle), loading \($0.isLoading)" })")
        await tidyServer()
        await pause(1.0)
        guard let web = tabs.active?.webView, let image = await ScreenshotMode.snapshot(of: web) else {
            say("browser: no snapshot of the page")
            return false
        }
        say("browser: snapshot \(Int(image.size.width))x\(Int(image.size.height)) of a \(Int(web.bounds.width))x\(Int(web.bounds.height)) view")
        return capture("browser", overlays: [ScreenshotMode.Overlay(view: web, image: image)])
    }

    private func files() async -> Bool {
        await baseline()
        settings.railPanelOpen = false
        settings.rightPanelWidth = 460
        store.openPanel(.files)
        await pause(2.0)
        let model = store.panelFiles
        if let item = model.items.first(where: { $0.name == "README.md" }) { model.selection = item.path }
        await tidyServer()
        return capture("files")
    }

    private func notesPanel() async -> Bool {
        await baseline()
        settings.railPanelOpen = false
        settings.rightPanelWidth = 460
        store.openPanel(.notes)
        await pause(1.0)
        store.panelNotes.text = Self.notes
        await tidyServer()
        return capture("notes")
    }

    /// superfile and btop draw a full-screen interface of their own, so they
    /// get the whole content area. Not in a build made without them.
    private func tool(_ tool: TerminalTool, panel: SidePanel, name: String, settle: TimeInterval) async -> Bool {
        guard tool.resolvedExecutable != nil else {
            say("\(name): \(tool.title) is not in this build")
            return false
        }
        await baseline()
        settings.railPanelOpen = false
        store.openPanelExpanded(panel)
        await pause(2.5 + settle)
        ScreenshotMode.describeTerminals(in: window, label: name)
        let taken = capture(name)
        closePanels()
        return taken
    }

    /// btop draws one more column of each graph per update, and its default is
    /// one every two seconds: a picture taken in the first minute is of graphs
    /// that are mostly empty. Asked for ten a second, they fill in twenty.
    /// Written ahead of the launch, which keeps every setting it finds in the
    /// file and sets only the colour theme.
    private func speedUpBtop() {
        let url = ToolTheming.btopConfigURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let updated = ToolTheming.settingKeys([("update_ms", "100")], in: existing)
            try updated.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            say("btop: could not set its update interval: \(error.localizedDescription)")
        }
    }

    // MARK: Sheets

    private func palette() async -> Bool {
        await baseline()
        // The real thing first: the palette is a sheet, which is a window of
        // its own, so the main window's picture does not include it.
        store.showCommandPalette = true
        await pause(1.5)
        var saved = false
        if let sheet = window.attachedSheet {
            saved = ScreenshotMode.capture(sheet, "command-palette", in: directory)
            // The search field has the focus when the sheet opens.
            if let editor = sheet.firstResponder as? NSTextView {
                let whole = NSRange(location: 0, length: (editor.string as NSString).length)
                editor.insertText("panel", replacementRange: whole)
                await pause(1.0)
                _ = ScreenshotMode.capture(sheet, "command-palette-search", in: directory)
            } else {
                say("palette: the search field does not have the focus")
            }
        } else {
            say("palette: no sheet is attached")
        }
        store.showCommandPalette = false
        await pause(0.8)
        if saved { return true }
        return await ScreenshotMode.host(CommandPaletteView(), size: nil, name: "command-palette", in: directory)
    }

    private func shortcuts() async -> Bool {
        await baseline()
        ScreenshotMode.describeMenus()
        store.showShortcuts()
        await pause(1.5)
        guard let sheet = window.attachedSheet else {
            say("shortcuts: no sheet is attached")
            return false
        }
        let everything = ScreenshotMode.capture(sheet, "keyboard-shortcuts", in: directory)
        // The search field has the focus when the window opens, so type
        // into it the way a person would.
        if let editor = sheet.firstResponder as? NSTextView {
            let whole = NSRange(location: 0, length: (editor.string as NSString).length)
            editor.insertText("shift split", replacementRange: whole)
            await pause(1.0)
            _ = ScreenshotMode.capture(sheet, "keyboard-shortcuts-search", in: directory)
        } else {
            say("shortcuts: the search field does not have the focus")
        }
        store.showKeyboardShortcuts = false
        await pause(0.8)
        return everything
    }

    // MARK: Looks

    private func lightTheme() async -> Bool {
        await baseline()
        await showHistory()
        settings.theme = .light
        await pause(2.5)
        compose(Self.composerSample)
        await pause(1.5)
        let taken = capture("light-theme")
        settings.theme = .dark
        await pause(1.5)
        return taken
    }

    /// A different terminal theme, accent, and frame — and the Appearance page
    /// that sets them, which is what that picture is of.
    private func customLook() async -> Bool {
        await baseline()
        await showHistory()
        settings.terminalThemeID = "catppuccin-mocha"
        settings.accentID = "purple"
        settings.frameTintSource = .accent
        settings.frameTintStrength = 0.22
        settings.frameCornerRadius = 18
        settings.frameGap = 10
        settings.uiFontDesign = .rounded
        await pause(2.5)
        compose(Self.composerSample)
        await pause(1.5)
        let taken = capture("custom-look")
        _ = await ScreenshotMode.host(
            SettingsRootView(initialSection: .appearance),
            size: NSSize(width: 940, height: 640),
            name: "settings-appearance",
            in: directory
        )
        settings.resetFrame()
        settings.accentID = "green"
        settings.terminalThemeID = "auto"
        settings.uiFontDesign = .system
        await pause(1.5)
        return taken
    }

    // MARK: The assistant

    /// An `@ai` question, answered by the sample server standing in for a model.
    private func assistantReply() async -> Bool {
        await baseline()
        _ = ScreenshotMode.focusComposer(in: window)
        compose("@ai how do I discard my local changes and match origin/main?")
        await pause(0.8)
        ScreenshotMode.pressReturn(in: window)
        await pause(4.5)
        if let field = ScreenshotMode.composerField(in: window) {
            say("ai-assistant: the input holds \(field.string.debugDescription), marked text \(field.hasMarkedText())")
        }
        let taken = capture("ai-assistant")
        await sendFromComposer("clear")
        return taken
    }

    /// A command that fails, and the offer to explain it that appears. Nothing
    /// is sent anywhere until it is chosen.
    private func errorHelp() async -> Bool {
        await baseline()
        _ = ScreenshotMode.focusComposer(in: window)
        compose("make build")
        await pause(0.8)
        ScreenshotMode.pressReturn(in: window)
        await pause(6.0)
        // What the watcher that makes the offer would have read.
        let text = server?.primarySession?.captureScrollback(maxBytes: 8_192) ?? ""
        let fresh = OutputDiff.newLines(baseline: "", current: text)
        say("error-help: the terminal ends \(fresh.suffix(4))")
        say("error-help: signature \(String(describing: FailureSignature.firstMatch(in: fresh, excludingCommand: "make build"))); "
            + "assistant set up \(AssistantServiceProvider.current.isConfigured); offers on \(settings.assistantOfferErrorHelp)")
        let taken = capture("error-help")
        await sendFromComposer("clear")
        return taken
    }

    /// Runs a command from the composer, which is also what puts away whatever
    /// the assistant last showed above it.
    private func sendFromComposer(_ command: String) async {
        compose(command)
        await pause(0.4)
        ScreenshotMode.pressReturn(in: window)
        await pause(1.2)
    }

    // MARK: Settings

    /// The Settings window, which does not exist until someone asks for it, one
    /// page at a time. Not Backup, whose page prints where the state file is on
    /// this machine; and not Connections, whose page lists whatever Bonjour
    /// finds on the network — on a runner, that is the runner's own name.
    private func settingsWindows() async {
        let pages: [(SettingsSection, String)] = [
            (.terminal, "settings-terminal"),
            (.composer, "settings-composer"),
            (.panels, "settings-panels"),
            (.security, "settings-security"),
            (.ai, "settings-ai"),
            (.http, "settings-http"),
            (.advanced, "settings-advanced"),
        ]
        for (section, name) in pages {
            await scene(name) {
                await ScreenshotMode.host(
                    SettingsRootView(initialSection: section),
                    size: NSSize(width: 940, height: 640),
                    name: name,
                    in: self.directory
                )
            }
        }

        // The default directory is a field, and shows what it holds: written
        // with the home folder as ~, which the app expands, rather than as
        // wherever this machine's is.
        await scene("settings-general") {
            let saved = self.settings.defaultDirectory
            self.settings.defaultDirectory = "~/Developer/hello-api"
            let taken = await ScreenshotMode.host(
                SettingsRootView(initialSection: .general),
                size: NSSize(width: 940, height: 640),
                name: "settings-general",
                in: self.directory
            )
            self.settings.defaultDirectory = saved
            return taken
        }
    }
}
#endif
