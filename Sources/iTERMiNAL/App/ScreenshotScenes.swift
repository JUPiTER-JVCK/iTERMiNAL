#if SCREENSHOTS
import AppKit
import Combine
import class SwiftTerm.TerminalView
import SwiftUI
import WebKit

/// The menu a right-click opened, handed from the notification that says it
/// began to the timer that closes it.
private final class MenuWatch: @unchecked Sendable {
    var menu: NSMenu?
}

/// What each picture is of, and how the app is put into it. See
/// ScreenshotMode.swift.
///
/// The scenes share one running app, so each starts from `baseline()` and
/// leaves the app as it found it — or as near as the next one needs. The order
/// matters in five places: the first HTTP scenes come before the ones that show
/// the sample site's request log, and the ones that read the sample site again
/// (the Extract tab, which downloads from it) come after them, so the log those
/// pictures show is the same as ever; the assistant scenes come late because
/// what they send stays in the composer's history; the Settings windows come
/// after everything that needs the main window to be the one in front; and the
/// right-click scene is last of all, because a menu runs an event loop of its
/// own until something closes it.
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
        await probeActivity("after the composer pictures")

        await scene("http-client") { await self.httpRequest() }
        await scene("site-explorer") { await self.siteExplorer() }

        await scene("split-panes") { await self.splitPanes() }
        await scene("landing") { await self.landing() }
        await scene("dock") { await self.dock() }
        await scene("tasks") { await self.tasks() }
        await probeActivity("after the dock and the task manager")

        await scene("browser") { await self.browser() }
        await scene("files") { await self.files() }
        await scene("notes") { await self.notesPanel() }
        await probeActivity("after the browser, files and notes panels")
        await scene("superfile") { await self.tool(.superfile, panel: .superfile, name: "superfile", settle: 3) }
        await scene("btop") {
            self.speedUpBtop()
            return await self.tool(.btop, panel: .btop, name: "btop", settle: 24)
        }
        await probeActivity("after superfile and btop, which each took the whole content area")

        await scene("terminal-colors") { await self.terminalColors() }
        await scene("terminal-tools") { await self.bundledTools() }
        await scene("terminal-opacity") { await self.terminalOpacity() }
        await scene("edit-in-terminal") { await self.editInTerminal() }
        await scene("extract") { await self.pageExtraction() }
        await scene("extract-feed") { await self.feedExtraction() }
        await scene("extract-crawl") { await self.siteCrawl() }
        await scene("extract-ask") { await self.askAboutPage() }
        await scene("sftp-problems") { await self.remoteProblems() }
        await scene("sftp-shared") { await self.sharedSignIn() }
        await scene("sftp-jump") { await self.jumpHosts() }

        await scene("command-palette") { await self.palette() }
        await scene("keyboard-shortcuts") { await self.shortcuts() }
        await probeActivity("after the two sheets")

        await scene("light-theme") { await self.lightTheme() }
        await scene("custom-look") { await self.customLook() }
        await probeActivity("after the themes")

        await scene("ai-assistant") { await self.assistantReply() }
        await scene("error-help") { await self.errorHelp() }

        await settingsWindows()

        await scene("terminal-context-menu") { await self.contextMenu() }
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
        await run("git log --oneline -n 12", in: server?.primarySession)
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

    // MARK: The Extract tab

    /// The sample site's article, read into lists. One request, sent the way a
    /// person sends one; everything after it is read from that response, and
    /// the only requests that follow are the downloads, which wait for a yes.
    private func pageExtraction() async -> Bool {
        await baseline()
        settings.railPanelOpen = false
        store.openPanelExpanded(.http)
        await pause(1.5)
        let model = store.panelHTTPClient
        let extraction = model.extraction
        model.mode = .request
        model.method = .get
        model.urlText = "\(Self.site)/blog/ledger-notes"
        model.headerFields = [HTTPHeaderField(name: "Accept", value: "text/html")]
        model.responseTab = .extract
        model.send(settings: settings)
        let sent = await ScreenshotMode.until(timeout: 20) { !model.isSending }
        let read = await ScreenshotMode.until(timeout: 20) {
            extraction.extraction != nil && extraction.pageURL.hasSuffix("/blog/ledger-notes")
        }
        say("extract: request finished \(sent), response read \(read)")
        guard read, let result = extraction.extraction, let page = result.page else { return false }
        say("extract: \(result.kindLabel), \(result.byteCount) bytes: "
            + extraction.chips(for: result).map { "\($0.title) \($0.count.map(String.init) ?? "")" }.joined(separator: ", "))

        // The response is the point of these pictures, so it gets the room: the
        // request above it is put down to its address, and the history beside
        // it is narrowed — both are dividers a person drags.
        ScreenshotMode.giveResponseRoom(in: window)
        ScreenshotMode.giveResponseWidth(in: window)
        await pause(1.2)
        var everything = capture("extract-overview")

        for (section, name) in [
            (ExtractSection.links, "extract-links"), (.media, "extract-media"),
            (.files, "extract-files"), (.tables, "extract-tables"),
        ] {
            extraction.select(section)
            await pause(0.8)
            everything = capture(name) && everything
        }

        // Pictures, three of them picked the way a person would: a click each.
        extraction.select(.images)
        let content = page.images.rows.filter { $0.canDownload && $0.url != nil && $0.cells[3] != "icon" && !($0.url ?? "").hasPrefix("http://cdn.") }
        extraction.selection = Set(content.prefix(3).map(\.id))
        await pause(0.8)

        // Previews start off, and are asked for with the footer's toggle. The
        // sample site's pictures are real ones; the banner it names over plain
        // http is not fetched, and the log says why.
        say("extract: previews are off to begin with: \(!settings.httpImagePreviews), \(extraction.previews.thumbnails.count) requested")
        settings.httpImagePreviews = true
        _ = await ScreenshotMode.until(timeout: 30) {
            let states = extraction.previews.thumbnails.values
            return !states.isEmpty && !states.contains { if case .loading = $0 { return true } else { return false } }
        }
        await pause(0.8)
        for (address, thumbnail) in extraction.previews.thumbnails.sorted(by: { $0.key < $1.key }) {
            switch thumbnail {
            case .ready(let image): say("extract: preview \(address): ready, \(Int(image.size.width)) × \(Int(image.size.height))")
            case .failed(let reason): say("extract: preview \(address): \(reason)")
            case .loading: say("extract: preview \(address): still loading")
            }
        }
        everything = capture("extract-images") && everything
        settings.httpImagePreviews = false

        // The reading part, as Markdown.
        extraction.select(.text)
        extraction.textMode = .markdown
        await pause(0.8)
        everything = capture("extract-text") && everything
        extraction.textMode = .reading

        // A question of its own, in the language a scraper would use.
        extraction.select(.query)
        await pause(0.6)
        for (language, text, output) in [
            (QueryLanguage.xpath, "//h2/text()", PageExtractionModel.OutputChoice.text),
            (.regex, #"\d+%"#, .text),
            (.css, "img::attr(src)", .text),
        ] {
            extraction.queryLanguage = language
            extraction.queryText = text
            extraction.queryOutput = output
            // Until it is done: a result from the one before is already there,
            // and a Run pressed while one is running is ignored.
            _ = await ScreenshotMode.until(timeout: 10) { !extraction.isQuerying }
            extraction.runQuery()
            _ = await ScreenshotMode.until(timeout: 10) { !extraction.isQuerying }
            say("extract: \(language.rawValue) \(text): \(extraction.queryError ?? "\(extraction.queryResult?.table.rows.count ?? -1) rows")"
                + " \(extraction.queryResult?.table.rows.prefix(3).map { $0.cells.joined(separator: " | ") } ?? [])")
        }
        await pause(0.8)
        everything = capture("extract-query") && everything

        let downloaded = await downloadFromExtraction(extraction, page: page)
        closePanels()
        return everything && downloaded
    }

    /// Download is asked about before anything is fetched, and then it is the
    /// real thing, from the sample site into a folder of this run's own.
    private func downloadFromExtraction(_ extraction: PageExtractionModel, page: ExtractedPage) async -> Bool {
        // Under the projects folder, not Downloads: macOS asks before an app
        // reads Downloads, and a runner has no one to say yes. The sheet shows
        // it with ~, as it does for anyone.
        let base = demo.map { URL(fileURLWithPath: $0, isDirectory: true).deletingLastPathComponent() }
            ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("downloads", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        let savedFolder = settings.httpDownloadFolder
        settings.httpDownloadFolder = folder.path
        defer {
            settings.httpDownloadFolder = savedFolder
            try? FileManager.default.removeItem(at: folder)
        }

        // Three pictures and the one the page names over plain http, which the
        // plan leaves out and says why.
        extraction.select(.images)
        let wanted = page.images.rows.filter { $0.canDownload && $0.url != nil && $0.cells[3] != "icon" }
        extraction.selection = Set(wanted.map(\.id))
        extraction.prepareDownload(urls: ResultTable.downloadURLs(in: wanted), title: "Images", settings: settings)
        await pause(1.5)
        guard let pending = extraction.pendingDownload else {
            say("extract: no download was planned")
            return false
        }
        say("extract: planned \(pending.plan.items.map(\.fileName)) from \(pending.plan.hosts) into a folder of this run's; "
            + "left out: \(pending.plan.refused.map { "\($0.url) (\($0.reason))" })")
        var taken = false
        if let sheet = window.attachedSheet {
            taken = ScreenshotMode.capture(sheet, "extract-download-confirm", in: directory)
        } else {
            say("extract: the confirmation sheet did not appear")
        }

        extraction.confirmDownload(settings: settings)
        let finished = await ScreenshotMode.until(timeout: 40) {
            !extraction.downloader.isRunning && !extraction.downloader.entries.isEmpty
        }
        await pause(1.0)
        say("extract: download finished \(finished); \(extraction.downloader.summary)")
        for entry in extraction.downloader.entries {
            if case .saved(let path, let bytes) = entry.state {
                let marked = getxattr(path, "com.apple.quarantine", nil, 0, 0, 0)
                say("extract: saved \(URL(fileURLWithPath: path).lastPathComponent), \(bytes) bytes, "
                    + "marked as downloaded from the web: \(marked >= 0)")
            } else {
                say("extract: \(entry.item.fileName): \(entry.state)")
            }
        }
        if let sheet = window.attachedSheet {
            taken = ScreenshotMode.capture(sheet, "extract-download-done", in: directory) && taken
        } else {
            say("extract: the progress sheet did not appear")
            taken = false
        }
        extraction.showingDownloadProgress = false
        extraction.downloader.reset()
        await pause(0.8)
        return taken
    }

    /// A feed, a CSV file and some JSON, read into tables.
    private func feedExtraction() async -> Bool {
        await baseline()
        settings.railPanelOpen = false
        store.openPanelExpanded(.http)
        await pause(1.5)
        let model = store.panelHTTPClient
        let extraction = model.extraction
        model.mode = .request
        model.responseTab = .extract
        var feedTaken = false
        for (path, accept, name) in [
            ("/feed.xml", "application/rss+xml, application/xml", "extract-feed"),
            ("/files/ledger-data.csv", "text/csv", "extract-csv"),
            ("/api/users", "application/json", "extract-json"),
        ] {
            model.method = .get
            model.urlText = "\(Self.site)\(path)"
            model.headerFields = [HTTPHeaderField(name: "Accept", value: accept)]
            model.send(settings: settings)
            _ = await ScreenshotMode.until(timeout: 20) { !model.isSending }
            let read = await ScreenshotMode.until(timeout: 20) {
                extraction.extraction != nil && extraction.pageURL.hasSuffix(path)
            }
            guard read, let result = extraction.extraction else {
                say("extract: \(path) was not read")
                continue
            }
            say("extract: \(path): \(result.kindLabel); "
                + extraction.chips(for: result).map { "\($0.title) \($0.count.map(String.init) ?? "")" }.joined(separator: ", "))
            ScreenshotMode.giveResponseRoom(in: window)
            ScreenshotMode.giveResponseWidth(in: window)
            await pause(1.0)
            let taken = capture(name)
            if path == "/feed.xml" { feedTaken = taken }
        }
        closePanels()
        return feedTaken
    }

    // MARK: The crawl

    /// Lines in the sample site's request log, for what a stretch of the run
    /// asked of it.
    private func requestLog() -> [String] {
        guard let fixtureLog, let text = try? String(contentsOfFile: fixtureLog, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    /// A crawl of the sample site from its article, with the limits the sheet
    /// starts from. The pictures matter less than what the site saw: robots.txt
    /// asked for before any page, the one page it asks crawlers to leave alone
    /// never requested, and the pages one at a time.
    private func siteCrawl() async -> Bool {
        await baseline()
        settings.railPanelOpen = false
        store.openPanelExpanded(.http)
        await pause(1.5)
        let model = store.panelHTTPClient
        let extraction = model.extraction
        model.mode = .request
        model.method = .get
        model.urlText = "\(Self.site)/blog/ledger-notes"
        model.headerFields = [HTTPHeaderField(name: "Accept", value: "text/html")]
        model.responseTab = .extract
        model.send(settings: settings)
        _ = await ScreenshotMode.until(timeout: 20) { !model.isSending }
        let read = await ScreenshotMode.until(timeout: 20) {
            extraction.extraction?.page != nil && extraction.pageURL.hasSuffix("/blog/ledger-notes")
        }
        guard read else {
            say("crawl: the page was not read")
            closePanels()
            return false
        }
        ScreenshotMode.giveResponseRoom(in: window)
        ScreenshotMode.giveResponseWidth(in: window)
        await pause(1.0)

        // The sheet first: what the crawl will do, before it has done anything.
        let before = requestLog().count
        extraction.proposeCrawl(settings: settings)
        await pause(1.5)
        guard let proposal = extraction.crawlProposal else {
            say("crawl: no proposal was made")
            closePanels()
            return false
        }
        say("crawl: proposal for \(proposal.host): \(proposal.candidates) addresses on the page would be queued; "
            + "up to \(proposal.limits.maxPages) pages, \(proposal.limits.maxDepth) deep, \(proposal.limits.delay) s apart; "
            + "stays under \(proposal.directory) if asked; refusal \(proposal.refusal.debugDescription)")
        say("crawl: requests the site saw while the sheet was open: \(requestLog().count - before)")
        var taken = false
        if let sheet = window.attachedSheet {
            taken = ScreenshotMode.capture(sheet, "extract-crawl-confirm", in: directory)
        } else {
            say("crawl: the sheet did not appear")
        }

        let crawler = extraction.crawler
        let started = requestLog().count
        extraction.confirmCrawl(limits: proposal.limits, settings: settings)
        let finished = await ScreenshotMode.until(timeout: 120) { !crawler.isActive && !crawler.isIdle }
        say("crawl: finished \(finished): \(crawler.phase)")
        say("crawl: \(crawler.robotsNote)")
        for page in crawler.results.pages {
            say("crawl: page \(page.id) depth \(page.depth) status \(page.status) \(page.url)"
                + (page.note.isEmpty ? "" : " — \(page.note)") + (page.foundOn.isEmpty ? "" : " (found on \(page.foundOn))"))
        }
        say("crawl: kept \(crawler.results.links.rows.count) links, \(crawler.results.images.rows.count) images, "
            + "\(crawler.results.media.rows.count) media, \(crawler.results.files.rows.count) files")
        let seen = requestLog().dropFirst(started)
        say("crawl: the site saw \(seen.count) requests: \(seen.map { $0.split(separator: " ").dropFirst().prefix(2).joined(separator: " ") })")
        // The folder robots.txt rules out is named by a link and by a redirect from an
        // allowed page; neither may have led the crawl into it.
        say("crawl: requests for the folder robots.txt rules out: \(seen.filter { $0.contains(" /admin") }.count)")
        await pause(1.0)
        taken = capture("extract-crawl") && taken

        crawler.list = .links
        extraction.selection = []
        await pause(0.8)
        taken = capture("extract-crawl-links") && taken
        closePanels()
        return taken
    }

    // MARK: Asking the assistant about a page

    /// The sample article read into rows by the stand-in for a model the
    /// assistant is pointed at. What the sheet would send is logged whole, and so
    /// is what each cell of the answer would be allowed to do.
    private func askAboutPage() async -> Bool {
        await baseline()
        settings.railPanelOpen = false
        store.openPanelExpanded(.http)
        await pause(1.5)
        let model = store.panelHTTPClient
        let extraction = model.extraction
        model.mode = .request
        model.method = .get
        model.urlText = "\(Self.site)/blog/ledger-notes"
        model.headerFields = [HTTPHeaderField(name: "Accept", value: "text/html")]
        model.responseTab = .extract
        model.send(settings: settings)
        _ = await ScreenshotMode.until(timeout: 20) { !model.isSending }
        let read = await ScreenshotMode.until(timeout: 20) {
            extraction.extraction?.page != nil && extraction.pageURL.hasSuffix("/blog/ledger-notes")
        }
        guard read else {
            say("ask: the page was not read")
            closePanels()
            return false
        }
        ScreenshotMode.giveResponseRoom(in: window)
        ScreenshotMode.giveResponseWidth(in: window)
        await pause(1.0)

        let question = "The revenue and costs for each region"
        say("ask: the assistant is set up: \(AssistantServiceProvider.current.isConfigured); it goes to \(AssistantDestination.describe(baseURL: settings.assistantBaseURL))")
        extraction.proposeAsk(settings: settings, question: question)
        await pause(1.5)
        guard let proposal = extraction.askProposal else {
            say("ask: no sheet was opened")
            closePanels()
            return false
        }
        if let request = AIExtractionRequest.make(question: proposal.question, page: proposal.page, baseURL: settings.assistantBaseURL) {
            say("ask: consent: \(request.consentMessage)")
            say("ask: the page text is \(request.coverage); the whole payload is \(request.preview.count) characters")
            say("ask: what would be sent begins: \(String(request.preview.prefix(900)).debugDescription)")
        } else {
            say("ask: no request could be made")
        }
        var taken = false
        if let sheet = window.attachedSheet {
            taken = ScreenshotMode.capture(sheet, "extract-ask-confirm", in: directory)
        } else {
            say("ask: the sheet did not appear")
        }

        let assistant = extraction.assistant
        extraction.confirmAsk(question: question)
        _ = await ScreenshotMode.until(timeout: 30) { assistant.phase != .asking }
        say("ask: \(assistant.phase); outcome \(String(describing: assistant.outcome).prefix(240))")
        if let table = assistant.table {
            say("ask: columns \(table.columns); \(table.rows.count) rows: \(table.rows.map(\.cells))")
        }
        await pause(1.0)
        taken = capture("extract-ask") && taken

        // An answer that names an address of its own: only one the page named
        // is something to act on.
        extraction.proposeAsk(settings: settings, question: "The author and a link to their profile")
        await pause(0.6)
        extraction.confirmAsk(question: "The author and a link to their profile")
        _ = await ScreenshotMode.until(timeout: 30) { assistant.phase != .asking }
        if let table = assistant.table {
            for row in table.rows {
                say("ask: \(row.cells) — address to act on: \(row.url.debugDescription); can be downloaded: \(row.canDownload)")
            }
        } else {
            say("ask: the second question gave no table: \(assistant.phase)")
        }
        closePanels()
        return taken
    }

    // MARK: Colored output

    /// `ls` and a man page in the server tab's own shell, which the app started
    /// with the environment it gives every local shell. The sample project's
    /// startup file sets `CLICOLOR` and nothing else: the colors are the app's.
    private func terminalColors() async -> Bool {
        guard let demo, let session = server?.primarySession else { return false }
        await baseline()

        // One of each kind of thing, made here and removed after, so the sample
        // project is left as it was found.
        let manager = FileManager.default
        let folder = URL(fileURLWithPath: demo, isDirectory: true).appendingPathComponent("listing", isDirectory: true)
        try? manager.removeItem(at: folder)
        defer { try? manager.removeItem(at: folder) }
        do {
            for name in ["assets", "logs"] {
                try manager.createDirectory(at: folder.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            for name in ["notes.txt", "photo.png", "backup.tar.gz", "README.md"] {
                try Data("sample\n".utf8).write(to: folder.appendingPathComponent(name))
            }
            let script = folder.appendingPathComponent("deploy.sh")
            try Data("#!/bin/sh\necho deployed\n".utf8).write(to: script)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            try manager.createSymbolicLink(atPath: folder.appendingPathComponent("current").path, withDestinationPath: "deploy.sh")
        } catch {
            say("colors: could not make the sample folder: \(error.localizedDescription)")
            return false
        }

        // What the shell was given, as the shell sees it.
        await run(#"echo "CLICOLOR=$CLICOLOR NO_COLOR=${NO_COLOR-unset} GROFF_NO_SGR=$GROFF_NO_SGR"; echo "LSCOLORS=$LSCOLORS"; echo "bold in less: ${LESS_TERMCAP_md:+set}""#, in: session)
        await pause(1.5)
        for line in session.captureVisibleText().split(separator: "\n").suffix(5) {
            say("colors: the shell says: \(line)")
        }

        await run("(cd listing && ls -AF)", in: session)
        await pause(1.8)
        var taken = capture("terminal-colors")

        // The composer put down to its pill, so the pager's status line — the
        // last line of the terminal — is not behind it.
        settings.composerCollapsed = true
        await pause(0.8)
        await run("man ls", in: session)
        await pause(3.0)
        taken = capture("terminal-colors-man") && taken
        // Out of the pager, back to the prompt.
        session.send(text: "q")
        await pause(1.0)
        session.send(text: "clear\n")
        settings.composerCollapsed = false
        await pause(0.8)
        return taken
    }

    // MARK: Edit in Terminal

    /// "Edit in Terminal" for a file with a space in its name, with the editor
    /// the runner has — Vim, which macOS ships; Helix and Neovim are not
    /// installed there. A tab opens, the line typed into it is quoted, and the
    /// editor comes up on that file.
    private func editInTerminal() async -> Bool {
        guard let demo else { return false }
        await baseline()
        let manager = FileManager.default
        let folder = URL(fileURLWithPath: demo, isDirectory: true).appendingPathComponent("edit-demo", isDirectory: true)
        try? manager.removeItem(at: folder)
        defer { try? manager.removeItem(at: folder) }
        let file = folder.appendingPathComponent("release notes.txt")
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("Release notes\n\n- faster startup\n- jump hosts\n".utf8).write(to: file)
        } catch {
            say("edit: could not make the sample file: \(error.localizedDescription)")
            return false
        }
        let before = store.workspaces.flatMap(\.tabs).count
        if let problem = store.editFile(at: file.path) {
            say("edit: refused: \(problem)")
            return false
        }
        await pause(3.5)
        let after = store.workspaces.flatMap(\.tabs).count
        guard let tab = store.selectedTab, let session = tab.primarySession else {
            say("edit: no tab came up")
            return false
        }
        say("edit: tabs \(before) -> \(after); the editor is \(settings.editorChoice.label)")
        let lines = session.captureVisibleText().split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines.prefix(5) { say("edit: the screen: \(line)") }
        for line in lines.suffix(3) { say("edit: the last lines: \(line)") }
        let taken = capture("edit-in-terminal")
        // Out of the editor without saving, and the tab away.
        session.send(text: "\u{1b}:q!\r")
        await pause(1.0)
        store.closeTab(tab)
        return taken
    }

    // MARK: Terminal opacity

    /// The Appearance slider, as the terminals receive it. A picture cannot show
    /// a desktop through a window — the window is drawn by itself — so what is
    /// read is what the setting did to each terminal's views: its background
    /// carries the opacity, a frosted view sits beneath it and the padding round
    /// it is tinted; and at 100% all of that is gone again.
    private func terminalOpacity() async -> Bool {
        guard let root = window.contentView else { return false }
        await baseline()
        let before = settings.backgroundOpacity
        defer { settings.backgroundOpacity = before }
        say("opacity: the window is opaque: \(window.isOpaque); its background is \(window.backgroundColor.map { "\($0)" } ?? "none")")
        var taken = false
        for value in [0.5, 1.0] {
            settings.backgroundOpacity = value
            await pause(1.5)
            for container in ScreenshotMode.allViews(of: TerminalContainerView.self, in: root) where !container.visibleRect.isEmpty {
                let terminalAlpha = (container.terminal as? TerminalView)?.nativeBackgroundColor.cgColor.alpha
                let containerAlpha = container.layer?.backgroundColor?.alpha
                let painted = terminalAlpha.map { String(format: "%.2f", Double($0)) } ?? "-"
                let contained = containerAlpha.map { String(format: "%.2f", Double($0)) } ?? "-"
                let frost = container.subviews.compactMap { $0 as? NSVisualEffectView }
                var frosted = "none"
                if let view = frost.first {
                    let place = view.blendingMode == .behindWindow ? "behind the window" : "within the window"
                    let drawn = view.state == .active ? "always drawn" : "follows the window"
                    frosted = "\(frost.count) (\(place), \(drawn))"
                }
                let order = container.subviews.map { String(describing: type(of: $0)) }
                say("opacity: \(Int(value * 100))%: the terminal paints its background at \(painted), its container at \(contained); frost views: \(frosted); subviews bottom to top: \(order)")
            }
            if value < 1 { taken = capture("terminal-opacity") }
        }
        return taken
    }

    // MARK: Bundled command-line tools

    /// `rg`, `bat` and `imgcat` typed into the server tab's own shell, which the
    /// app started with the folder they ship in on its `PATH`. Where the shell
    /// finds each goes to the log, and what they print is the picture: `imgcat`'s
    /// image is drawn by the terminal itself, which nothing else here exercises.
    private func bundledTools() async -> Bool {
        guard let demo, let session = server?.primarySession else { return false }
        await baseline()

        let manager = FileManager.default
        let folder = URL(fileURLWithPath: demo, isDirectory: true).appendingPathComponent("tools-demo", isDirectory: true)
        try? manager.removeItem(at: folder)
        defer { try? manager.removeItem(at: folder) }
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try Self.sampleImage().write(to: folder.appendingPathComponent("logo.png"))
            let source = "fn main() {\n    println!(\"hello, hello-api\");\n}\n"
            try Data(source.utf8).write(to: folder.appendingPathComponent("main.rs"))
        } catch {
            say("tools: could not make the sample folder: \(error.localizedDescription)")
            return false
        }

        // Where the shell finds each one: the bundle's, unless something on the
        // machine is earlier on the PATH.
        await run("command -v rg bat imgcat", in: session)
        await pause(1.5)
        for line in session.captureVisibleText().split(separator: "\n").suffix(4) {
            say("tools: the shell says: \(line)")
        }

        // bat is told not to page: the scene must not be left in a pager.
        await run("(cd tools-demo && imgcat -W 24 logo.png && bat --paging=never main.rs && rg -n hello)", in: session)
        await pause(3.5)
        for line in session.captureVisibleText().split(separator: "\n").suffix(10) {
            say("tools: on the screen: \(line)")
        }
        let taken = capture("terminal-tools")

        // The picture above shows the room an image took and not the image. So:
        // the same from another encoder (the sample site's own PNG, through a
        // pipe), at its own size, and what the system does with the way the
        // terminal cuts an image into rows.
        await run("curl -s http://localhost:8765/media/cover.png | imgcat -W 24", in: session)
        await pause(2.5)
        _ = capture("terminal-tools-piped")
        await run("(cd tools-demo && imgcat logo.png)", in: session)
        await pause(2.5)
        _ = capture("terminal-tools-auto")
        stripeProbe()

        session.send(text: "clear\n")
        await pause(0.8)
        return taken
    }

    /// What SwiftTerm does to cut an inline image into one strip per row — an
    /// `NSImage` holding a bitmap, focus locked, the source drawn into it — and
    /// then how a strip is drawn into a view: done here by hand, on this
    /// machine, and counted. A strip with nothing painted in it is a terminal
    /// that makes room for an image and draws none.
    private func stripeProbe() {
        guard let source = NSImage(data: Self.sampleImage()) else {
            say("stripe: the sample picture does not decode")
            return
        }
        say("stripe: the picture decodes to \(source.size), \(source.representations.count) representation(s); the window's scale is \(window.backingScaleFactor)")
        let width = 192, height = 16
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: NSColorSpaceName.calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            say("stripe: no bitmap")
            return
        }
        let strip = NSImage(size: NSSize(width: width, height: height))
        strip.addRepresentation(bitmap)
        strip.lockFocus()
        source.draw(
            in: CGRect(x: 0, y: 0, width: width, height: height),
            from: CGRect(x: 0, y: 90, width: source.size.width, height: 10),
            operation: .copy, fraction: 1
        )
        strip.unlockFocus()
        say("stripe: the strip holds \(strip.representations.count) representation(s)")

        func painted(_ rep: NSBitmapImageRep) -> Int {
            var count = 0
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { count += 1 }
            }
            return count
        }
        say("stripe: the bitmap that was added has \(painted(bitmap)) of \(width * height) pixels painted")
        guard let probe = ScreenshotMode.bitmap(width: width, height: height),
              let context = NSGraphicsContext(bitmapImageRep: probe) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        strip.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        say("stripe: the strip, drawn into a view's kind of context, paints \(painted(probe)) of \(width * height) pixels")
    }

    /// A small picture to show: a diagonal wash from green to blue under a pale
    /// disc. Drawn here, so the sample project holds nothing a person made.
    private static func sampleImage() -> Data {
        let width = 320, height = 180
        guard let bitmap = ScreenshotMode.bitmap(width: width, height: height) else { return Data() }
        for y in 0..<height {
            for x in 0..<width {
                let t = (Double(x) / Double(width) + Double(y) / Double(height)) / 2
                let dx = Double(x - 230), dy = Double(y - 70)
                let inDisc = dx * dx + dy * dy < 38 * 38
                let color = inDisc
                    ? NSColor(srgbRed: 0.96, green: 0.96, blue: 0.98, alpha: 1)
                    : NSColor(srgbRed: 0.06 + 0.08 * t, green: 0.64 - 0.28 * t, blue: 0.50 + 0.35 * t, alpha: 1)
                bitmap.setColor(color, atX: x, y: y)
            }
        }
        return bitmap.representation(using: .png, properties: [:]) ?? Data()
    }

    // MARK: Remote problems

    /// What the file browser says when a host turns it away, from the real
    /// `sftp`, run the way the app runs it. The first host is the throwaway SSH
    /// server the workflow starts on this machine, which lets no one in; the
    /// others are a port with nothing on it and a name that does not exist.
    private func remoteProblems() async -> Bool {
        let hosts = [
            SSHConnection(name: "staging-vm", host: "127.0.0.1", port: 2299, username: "deploy"),
            SSHConnection(name: "old-nas", host: "127.0.0.1", port: 2298, username: "admin"),
            SSHConnection(name: "lab-box", host: "lab-box.example.invalid", username: "pi"),
        ]
        let saved = settings.sshConnections
        settings.sshConnections = saved + hosts
        defer { settings.sshConnections = saved }

        await baseline()
        settings.railPanelOpen = false
        settings.rightPanelWidth = 460
        store.openPanel(.files)
        await pause(2.0)
        let model = store.panelFiles
        var first = false
        for (index, host) in hosts.enumerated() {
            model.switchTo(connectionID: host.id.uuidString)
            _ = await ScreenshotMode.until(timeout: 45) { !model.isLoading }
            await pause(1.0)
            if let problem = model.listingProblem {
                say("sftp: \(host.name): \(problem.title) — \(problem.explanation) "
                    + "[\(problem.kind); \(problem.steps.count) steps; actions \(problem.actions.map(\.title))]")
                say("sftp: \(host.name): sftp said: \(problem.output.debugDescription)")
            } else {
                say("sftp: \(host.name): no problem was reported; error \(model.errorMessage.debugDescription), \(model.items.count) items")
            }
            if index == 0 { await tidyServer() }
            let taken = capture(["files-sftp-denied", "files-sftp-refused", "files-sftp-unknown-host"][index])
            if index == 0 { first = taken }
        }
        model.switchTo(connectionID: nil)
        closePanels()
        return first
    }

    // MARK: A sign-in the file browser shares

    /// A host the file browser cannot sign in to by itself, reached through a
    /// terminal tab's sign-in. The workflow starts a second throwaway SSH server
    /// on this machine, which takes one key. The key goes to the *terminal's*
    /// ssh, in the connection's extra arguments, which the file browser never
    /// reads — so the browser's own sign-in is refused, as it is for a host that
    /// wants a password, until the tab has signed in. The key stands in for the
    /// password; what is shown is that the browser rides on a connection it did
    /// not make, and that closing the tab ends it.
    private func sharedSignIn() async -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let portText = environment["ITERMINAL_SSH_SHARED_PORT"], let port = Int(portText),
              let key = environment["ITERMINAL_SSH_SHARED_KEY"] else {
            say("shared sign-in: the workflow did not start a server for it")
            return false
        }
        let knownHosts = FileManager.default.temporaryDirectory
            .appendingPathComponent("iterminal-known-hosts-\(UUID().uuidString.prefix(8))").path
        let host = SSHConnection(
            name: "build-vm", host: "127.0.0.1", port: port, username: NSUserName(), initialPath: demo,
            extraArguments: "-i \(key) -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=\(knownHosts)"
        )
        let saved = settings.sshConnections
        settings.sshConnections = saved + [host]
        defer {
            settings.sshConnections = saved
            try? FileManager.default.removeItem(atPath: knownHosts)
        }

        await baseline()
        settings.railPanelOpen = false
        settings.rightPanelWidth = 460
        store.openPanel(.files)
        await pause(2.0)
        let model = store.panelFiles
        let socketBase = NSTemporaryDirectory()
        func isOpen() -> Bool { SSHControlSocket.liveSocket(for: host, base: socketBase) != nil }

        // On its own, the browser has no way in.
        model.switchTo(connectionID: host.id.uuidString)
        _ = await ScreenshotMode.until(timeout: 45) { !model.isLoading }
        await pause(0.8)
        if let problem = model.listingProblem {
            say("shared: before: \(problem.title) [\(problem.kind)]; actions \(problem.actions.map(\.title))")
            say("shared: before: sftp said: \(problem.output.debugDescription)")
        } else {
            say("shared: before: no problem was reported; \(model.items.count) items — the server let the browser in on its own")
        }
        say("shared: before: a connection is open: \(isOpen())")

        // The button: a tab signed in to the host, listening for the browser.
        model.perform(.signInInTerminal)
        say("shared: the sign-in note: \(model.errorMessage.debugDescription)")
        guard let tab = store.selectedTab else {
            say("shared: no tab opened")
            return false
        }
        let up = await ScreenshotMode.until(timeout: 40) { isOpen() }
        say("shared: the tab's connection is open: \(up); the socket path is \(SSHControlSocket.path(for: host, base: socketBase)?.count ?? -1) characters")
        guard up else {
            for line in (tab.primarySession?.captureVisibleText() ?? "").split(separator: "\n").suffix(8) {
                say("shared: the tab says: \(line)")
            }
            store.closeTab(tab)
            model.switchTo(connectionID: nil)
            closePanels()
            return false
        }

        // Back to the server tab for the picture; the sign-in tab stays open.
        if let server {
            store.selectedTabID = server.id
            store.focusedSessionID = server.primarySession?.id
        }
        await tidyServer()
        model.reload()
        _ = await ScreenshotMode.until(timeout: 45) { !model.isLoading }
        await pause(1.0)
        say("shared: after: \(model.items.count) items in \(model.directory); through a tab: \(model.usesSharedSignIn); "
            + "problem: \(model.listingProblem?.title ?? "none")")
        say("shared: after: the first items: \(model.items.prefix(6).map(\.name))")
        let taken = capture("files-sftp-shared")

        // Closing the tab's session ends the connection, and the browser says so.
        tab.primarySession?.send(text: "exit\n")
        let closed = await ScreenshotMode.until(timeout: 30) { !isOpen() }
        say("shared: after the tab's shell exited the connection is closed: \(closed)")
        model.reload()
        _ = await ScreenshotMode.until(timeout: 45) { !model.isLoading }
        await pause(0.8)
        say("shared: afterwards: \(model.listingProblem?.title ?? "no problem"); \(model.items.count) items; through a tab: \(model.usesSharedSignIn)")

        store.closeTab(tab)
        model.switchTo(connectionID: nil)
        closePanels()
        return taken
    }

    // MARK: Through jump hosts

    /// A host reached through jump hosts, with the real `sftp` and `ssh`. The
    /// workflow's one-key server is the destination and, since it is the only
    /// server there is, the hop as well: the hop is an alias in the runner's own
    /// ssh config (named by `ITERMINAL_SSH_JUMP_HOST`) that holds the server's
    /// address and key, because ssh configures a hop there and not from the
    /// connection's own settings.
    ///
    /// With both ends on one machine, the evidence that a connection went the
    /// long way is the server's own log: each ssh connection it lets in is one
    /// "Accepted publickey", so a listing made directly costs some number of
    /// them, through one hop twice as many, through two hops three times. The
    /// numbers go to the log; the scene only reports what it saw.
    private func jumpHosts() async -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard let portText = environment["ITERMINAL_SSH_SHARED_PORT"], let port = Int(portText),
              let key = environment["ITERMINAL_SSH_SHARED_KEY"],
              let hop = environment["ITERMINAL_SSH_JUMP_HOST"],
              let logPath = environment["ITERMINAL_SSH_SHARED_LOG"] else {
            say("jump hosts: the workflow did not set up a jump host for it")
            return false
        }
        func logins() -> Int {
            let text = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
            return text.components(separatedBy: "Accepted publickey").count - 1
        }
        let knownHosts = FileManager.default.temporaryDirectory
            .appendingPathComponent("iterminal-known-hosts-\(UUID().uuidString.prefix(8))").path
        func make(_ name: String, jumps: String) -> SSHConnection {
            SSHConnection(
                name: name, host: "127.0.0.1", port: port, username: NSUserName(),
                identityFile: key, initialPath: demo,
                extraArguments: "-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=\(knownHosts)",
                jumpHosts: jumps
            )
        }
        let hosts = [
            make("direct-vm", jumps: ""),
            make("one-hop-vm", jumps: hop),
            make("two-hop-vm", jumps: "\(hop),\(hop)"),
        ]
        let saved = settings.sshConnections
        settings.sshConnections = saved + hosts
        defer {
            settings.sshConnections = saved
            try? FileManager.default.removeItem(atPath: knownHosts)
        }

        await baseline()
        settings.railPanelOpen = false
        settings.rightPanelWidth = 460
        store.openPanel(.files)
        await pause(2.0)
        let model = store.panelFiles
        var taken = false
        for (index, host) in hosts.enumerated() {
            let before = logins()
            model.switchTo(connectionID: host.id.uuidString)
            _ = await ScreenshotMode.until(timeout: 60) { !model.isLoading }
            await pause(1.0)
            say("jump hosts: \(host.name) [\(host.jumpHosts.isEmpty ? "direct" : host.jumpHosts)]: "
                + "\(model.items.count) items in \(model.directory); problem: \(model.listingProblem?.title ?? "none"); "
                + "logins at the server: \(logins() - before)")
            if index == 1 {
                await tidyServer()
                taken = capture("files-sftp-jump")
            }
        }
        model.switchTo(connectionID: nil)
        closePanels()

        // And a terminal tab, opened the way a person opens a saved host,
        // through the one hop. The line is typed after the handshakes, which a
        // terminal in raw mode would not otherwise be sure to keep.
        let before = logins()
        let tab = store.newTab(kind: .remote(hosts[1].id))
        guard let session = tab.primarySession else {
            say("jump hosts: the tab has no terminal")
            return taken
        }
        await pause(6.0)
        session.send(text: "echo via-$((6 * 7))\n")
        let answered = await ScreenshotMode.until(timeout: 40) { session.captureVisibleText().contains("via-42") }
        say("jump hosts: the tab through one hop answered: \(answered); logins at the server: \(logins() - before)")
        for line in session.captureVisibleText().split(separator: "\n").suffix(6) {
            say("jump hosts: the tab says: \(line)")
        }
        session.send(text: "exit\n")
        await pause(1.5)
        store.closeTab(tab)
        return taken
    }

    // MARK: The right-click menu

    /// A right-click on the server's terminal, sent the way the system sends
    /// one, and what it opens: the menu, its items, and what a few of them do.
    /// Last of all, because a menu runs an event loop of its own until
    /// something closes it.
    private func contextMenu() async -> Bool {
        await baseline()
        await showHistory()
        guard let root = window.contentView,
              let terminal = ScreenshotMode.firstView(ofType: InstrumentedTerminalView.self, in: root) else {
            say("right-click: no terminal in the window")
            return false
        }
        let point = terminal.convert(NSPoint(x: terminal.bounds.midX, y: terminal.bounds.midY), to: nil)
        let make = { () -> NSEvent? in
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: self.window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )
        }
        guard let event = make() else {
            say("right-click: no event could be made")
            return false
        }

        // What the terminal offers, and what its editing items do.
        guard let menu = terminal.menu(for: event) else {
            say("right-click: the terminal offers no menu")
            return false
        }
        func describe(_ menu: NSMenu) -> String {
            menu.update()
            return menu.items.map { $0.isSeparatorItem ? "—" : "\($0.title)\($0.isEnabled ? "" : " (off)")\($0.keyEquivalent.isEmpty ? "" : " ⌘\($0.keyEquivalent.uppercased())")" }
                .joined(separator: " | ")
        }
        say("right-click: no selection: \(describe(menu))")
        if let index = menu.items.firstIndex(where: { $0.title == "Select All" }) { menu.performActionForItem(at: index) }
        await pause(0.6)
        say("right-click: after Select All: \(describe(menu))")
        NSPasteboard.general.clearContents()
        if let index = menu.items.firstIndex(where: { $0.title == "Copy" }) { menu.performActionForItem(at: index) }
        let copied = NSPasteboard.general.string(forType: .string) ?? ""
        say("right-click: Copy put \(copied.count) characters on the pasteboard, starting \(copied.prefix(40).debugDescription)")

        // Paste lands at the prompt of the terminal that was clicked, whoever has
        // the keyboard (here, the composer has it).
        if let session = server?.primarySession {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("echo pasted-by-the-menu", forType: .string)
            if let index = menu.items.firstIndex(where: { $0.title == "Paste" }) { menu.performActionForItem(at: index) }
            await pause(1.2)
            say("right-click: Paste put its text at the prompt: \(session.captureVisibleText().contains("pasted-by-the-menu"))")
            // Control-U: the line, unsent.
            session.send(text: "\u{15}")
            await pause(0.5)
        }

        // Find… opens the terminal's own find bar.
        if let index = menu.items.firstIndex(where: { $0.title == "Find…" }) { menu.performActionForItem(at: index) }
        await pause(1.0)
        let bar = terminal.subviews.first { String(describing: type(of: $0)).contains("FindBar") }
        say("right-click: Find… \(bar.map { "showed a find bar, hidden \($0.isHidden)" } ?? "showed no find bar")")
        _ = capture("terminal-find")
        let hide = NSMenuItem(title: "Hide", action: nil, keyEquivalent: "")
        hide.tag = NSTextFinder.Action.hideFindInterface.rawValue
        terminal.performTextFinderAction(hide)
        await pause(0.6)

        // The real event, through the window: the view under the pointer gets
        // it and opens its menu. `sendEvent` comes back when the menu closes,
        // so something has to close it; and something has to give up if that
        // never happens, so a menu that will not close ends this scene, not the
        // run.
        let watch = MenuWatch()
        let begin = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
            watch.menu = note.object as? NSMenu
        }
        defer { NotificationCenter.default.removeObserver(begin) }
        let giveUp = DispatchWorkItem {
            ScreenshotMode.say("right-click: the menu did not close; giving up on it")
            exit(3)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 40, execute: giveUp)
        let directory = directory
        let timer = Timer(timeInterval: 1.5, repeats: false) { _ in
            MainActor.assumeIsolated {
                let titles = watch.menu?.items.map { $0.isSeparatorItem ? "—" : $0.title } ?? []
                ScreenshotMode.say("right-click: while the menu is open it holds: \(titles)")
                for popup in NSApp.windows {
                    ScreenshotMode.say("right-click: window \(type(of: popup)) at \(popup.frame), visible \(popup.isVisible)")
                    if String(describing: type(of: popup)).contains("Menu") {
                        _ = ScreenshotMode.capture(popup, "terminal-context-menu", in: directory)
                    }
                }
                watch.menu?.cancelTracking()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        guard let click = make() else {
            giveUp.cancel()
            return false
        }
        NSApp.sendEvent(click)
        giveUp.cancel()
        say("right-click: the menu closed; it had \(watch.menu?.numberOfItems ?? -1) items")
        return watch.menu != nil
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
        // Without the sidebar the cards fit on one row, and with the composer
        // put down to its pill none of them is behind it.
        settings.railPanelOpen = false
        settings.composerCollapsed = true
        store.selectedTabID = nil
        await pause(1.8)
        guard store.selectedTab == nil else {
            say("landing: a tab is still selected")
            return false
        }
        let taken = capture("landing")
        store.selectedTabID = server?.id
        settings.composerCollapsed = false
        return taken
    }

    private func dock() async -> Bool {
        await baseline()
        settings.bottomDockHeight = 250
        store.toggleBottomDock()
        await pause(2.5)
        guard let first = store.dockSessions.first else { return false }
        await run("git status -sb; git log --oneline -n 5", in: first)
        // A second tab, running something that goes on running: the task
        // manager lists it, and the strip shows there is more than one.
        let second = store.newDockSession(directory: demo.map { $0 + "/docs" })
        await pause(2.5)
        await run(fixtureLog.map { "tail -n 12 -f '\($0)'" } ?? "ls -F", in: second)
        await pause(2.5)
        // The first in front: its output is the fuller picture.
        store.selectedDockSessionID = first.id
        await pause(2.5)
        let taken = capture("dock")
        store.closeBottomDock()
        return taken
    }

    /// Whether the server tab's terminal still reports activity at this point
    /// in the run. The error offer waits on it, and so do the ages beside the
    /// tabs in the sidebar. It never reported any until SwiftTerm was asked to
    /// (`notifyUpdateChanges`), so a "did not move" here is that coming back. A
    /// bare Return makes the shell print a new prompt, which is output.
    private func probeActivity(_ label: String) async {
        guard let session = server?.primarySession else { return }
        let before = session.lastActivityAt
        session.send(text: "\n")
        await pause(1.5)
        say("activity probe, \(label): the server terminal's activity \(session.lastActivityAt > before ? "moved" : "did not move")")
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
        await pause(3.0)
        // A tab used to learn its page's title only when a load started or
        // finished, and on a runner the title arrives after the load has
        // finished, so every tab said "New tab". The tab now follows the
        // title, and this says what each one has: the tab's, what WebKit says
        // it is, and what the page itself says.
        for tab in tabs.tabs {
            let page = await pageSays(tab)
            say("browser: \(tab.urlText): the tab says \(tab.pageTitle.debugDescription), WebKit says "
                + "\(tab.webView.title.debugDescription), the page says \(page); loading \(tab.isLoading)")
        }
        await tidyServer()
        await pause(1.0)
        guard let web = tabs.active?.webView, let image = await ScreenshotMode.snapshot(of: web) else {
            say("browser: no snapshot of the page")
            return false
        }
        say("browser: snapshot \(Int(image.size.width))x\(Int(image.size.height)) of a \(Int(web.bounds.width))x\(Int(web.bounds.height)) view")
        return capture("browser", overlays: [ScreenshotMode.Overlay(view: web, image: image)])
    }

    /// What the page in a tab says its title is, asked of the page itself.
    private func pageSays(_ tab: BrowserModel) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            tab.evaluate("document.title") { result in
                switch result {
                case .success(let title): continuation.resume(returning: title.debugDescription)
                case .failure(let error): continuation.resume(returning: "an error (\(error.localizedDescription))")
                }
            }
        }
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
        if tool == .superfile, let session = store.toolSessions[.superfile] {
            await dismissSuperfileWelcome(session)
        }
        ScreenshotMode.describeTerminals(in: window, label: name)
        let taken = capture(name)
        closePanels()
        return taken
    }

    /// superfile greets a launch it has not seen before with a page of its
    /// own, over the file manager — and on a runner every launch is the first.
    /// It goes away at a key; which key is its business, so each is tried in
    /// turn until the page is gone.
    private func dismissSuperfileWelcome(_ session: TerminalSession) async {
        let greeting = "Thanks for using superfile"
        for key in ["\u{1B}", "\r", " "] {
            guard session.captureVisibleText().contains(greeting) else { return }
            say("superfile: its welcome page is up; pressing \(key.debugDescription)")
            session.send(text: key)
            await pause(1.5)
        }
        say("superfile: the welcome page is \(session.captureVisibleText().contains(greeting) ? "still" : "no longer") up")
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
        // The reply floats over whatever the terminal shows, so it is given a
        // clear screen to float over.
        server?.primarySession?.send(text: "clear\n")
        await pause(1.0)
        _ = ScreenshotMode.focusComposer(in: window)
        compose("@ai how do I discard my local changes and match origin/main?")
        await pause(0.8)
        ScreenshotMode.pressReturn(in: window)
        await pause(4.5)
        if let field = ScreenshotMode.composerField(in: window) {
            say("ai-assistant: the input holds \(field.string.debugDescription), marked text \(field.hasMarkedText()), "
                + "\(field.textStorage?.length ?? -1) characters stored, \(field.layoutManager?.numberOfGlyphs ?? -1) glyphs laid out")
            // The first pictures had one letter in the empty input, at its left
            // edge, where the placeholder should have been. It is the last
            // letter of the placeholder: the input had been scrolled sideways
            // while the card was still changing width, and an empty field has
            // nothing to scroll it back. Put back where it starts.
            if let scroller = field.enclosingScrollView {
                say("ai-assistant: the input is scrolled to \(scroller.contentView.bounds.origin); its text view is \(field.frame)")
                scroller.contentView.scroll(to: .zero)
                scroller.reflectScrolledClipView(scroller.contentView)
            }
            field.needsDisplay = true
            field.displayIfNeeded()
        }
        await pause(0.6)
        let taken = capture("ai-assistant")
        await sendFromComposer("clear")
        return taken
    }

    /// A command that fails, and the offer to explain it that appears. Nothing
    /// is sent anywhere until it is chosen.
    ///
    /// The offer is made by the composer's own watcher, which wakes on the
    /// terminal's activity. That signal was dead in every build until SwiftTerm
    /// was asked to report updates, so an earlier version of this scene made the
    /// offer itself when none came. It no longer does: if the composer does not
    /// make it, there is no picture, and the log says why.
    private func errorHelp() async -> Bool {
        await baseline()
        _ = ScreenshotMode.focusComposer(in: window)
        compose("make build")
        await pause(0.8)
        let target = store.composerDestinationSession
        let before = target?.captureScrollback(maxBytes: CommandOutcomeWatcher.captureBytes) ?? ""
        ScreenshotMode.pressReturn(in: window)
        await pause(7.0)
        var offered = false
        if case .offer? = ScreenshotMode.composerAssistant?.banner { offered = true }
        // What the watcher read: the terminal now, against the terminal before.
        let after = target?.captureScrollback(maxBytes: CommandOutcomeWatcher.captureBytes) ?? ""
        let fresh = OutputDiff.newLines(baseline: before, current: after)
        let match = FailureSignature.firstMatch(in: fresh, excludingCommand: "make build")
        say("error-help: the composer ran it in the server tab: \(target?.id == server?.primarySession?.id); "
            + "new since the command was sent: \(fresh.suffix(4)); signature \(String(describing: match)); "
            + "assistant set up \(AssistantServiceProvider.current.isConfigured); offers on \(settings.assistantOfferErrorHelp); "
            + "the composer's own watcher made the offer: \(offered)")
        let taken = offered && capture("error-help")
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
        // Taller where a page has more on it than the usual window shows.
        let pages: [(SettingsSection, String, CGFloat)] = [
            (.terminal, "settings-terminal", 640),
            (.composer, "settings-composer", 640),
            (.panels, "settings-panels", 640),
            (.security, "settings-security", 640),
            (.ai, "settings-ai", 640),
            (.http, "settings-http", 640),
            (.advanced, "settings-advanced", 640),
        ]
        for (section, name, height) in pages {
            await scene(name) {
                await ScreenshotMode.host(
                    SettingsRootView(initialSection: section),
                    size: NSSize(width: 940, height: height),
                    name: name,
                    in: self.directory
                )
            }
        }
        // The HTTP Client page again, scrolled to the end: the Downloads settings
        // and the privacy note sit below what the usual window shows. (A window
        // cannot be made taller than the screen, so it is the page that moves.)
        await scene("settings-http-downloads") {
            await ScreenshotMode.host(
                SettingsRootView(initialSection: .http),
                size: NSSize(width: 940, height: 640),
                name: "settings-http-downloads",
                in: self.directory,
                scrolledToEnd: true
            )
        }

        // The Terminal page again, a little over a third of the way down: the
        // font picker with its preview and the Import button, and the cursor
        // choices, which the first screenful of that page does not reach. Only
        // looked at; the installed fonts are this runner's.
        for (fraction, name) in [(0.35, "settings-terminal-font"), (0.6, "settings-terminal-cursor")] {
            await scene(name) {
                await ScreenshotMode.host(
                    SettingsRootView(initialSection: .terminal),
                    size: NSSize(width: 940, height: 640),
                    name: name,
                    in: self.directory,
                    scrolledTo: fraction
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
