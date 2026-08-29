import AppKit
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

    let engine: SwiftTermEngine
    private var hasStarted = false

    /// A shell for this session alone, overriding the global setting. The
    /// composer uses it so switching to bash there leaves every other terminal
    /// on whatever the user configured.
    private let shellOverride: String?

    init(
        id: UUID = UUID(),
        kind: SessionKind = .localShell,
        initialDirectory: String? = nil,
        shellOverride: String? = nil
    ) {
        let settings = AppSettings.shared
        self.id = id
        self.kind = kind
        self.shellOverride = shellOverride
        self.currentDirectory = initialDirectory ?? settings.resolvedInitialDirectory

        let options = TerminalOptions(
            cursorStyle: CursorStyle(tagName: settings.cursorStyleTag) ?? .steadyBlock,
            scrollback: max(100, settings.scrollbackLines)
        )
        engine = SwiftTermEngine(options: options)
        engine.delegate = self
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
        engine.onCommand = { [weak self] command in
            // Same queue caveat as the activity callback above.
            DispatchQueue.main.async {
                self?.noteCommand(command)
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
        launch()
    }

    private func launch() {
        let settings = AppSettings.shared
        switch SessionLaunch.configuration(
            for: kind,
            settings: settings,
            directory: isRemote ? nil : currentDirectory,
            shellOverride: shellOverride
        ) {
        case .success(let configuration):
            launchError = nil
            engine.start(configuration)
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

    /// Pushes font, colors, ANSI palette, and the GPU renderer preference
    /// into the engine. Safe to call on every SwiftUI update — the engine
    /// ignores values that haven't changed.
    func applyStyling(settings: AppSettings, darkMode: Bool) {
        let theme = settings.resolvedTerminalTheme(darkMode: darkMode)
        engine.applyPalette(theme.palette)
        engine.apply(TerminalAppearance(
            font: settings.resolvedTerminalFont(),
            background: theme.backgroundColor,
            foreground: theme.foregroundColor,
            backgroundAlpha: CGFloat(settings.backgroundOpacity)
        ))
        let active = engine.setGPUAcceleration(settings.useGPURendering)
        if isGPUAccelerated != active {
            isGPUAccelerated = active
        }
    }

    func terminate() {
        guard hasStarted, isRunning else { return }
        engine.terminate()
        isRunning = false
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
        lastExitCode = exitCode
        EventBus.shared.publish(APIEvent("session.exited", [
            "session": id.uuidString,
            "exitCode": exitCode ?? -1,
            "remote": isRemote,
        ]))
    }
}
