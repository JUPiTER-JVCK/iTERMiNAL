import AppKit
import SwiftTerm

/// One live shell: owns the engine (and therefore the PTY child process),
/// and publishes the metadata the sidebar shows — title, working directory,
/// and git branch. The session object outlives view attachment, which is what
/// keeps processes alive while the user switches tabs or workspaces.
final class TerminalSession: ObservableObject, Identifiable {
    let id: UUID

    @Published private(set) var title: String = ""
    @Published private(set) var currentDirectory: String
    @Published private(set) var gitBranch: String?
    @Published private(set) var isRunning = false
    @Published private(set) var lastExitCode: Int32?

    let engine: SwiftTermEngine
    private var hasStarted = false

    init(id: UUID = UUID(), initialDirectory: String? = nil) {
        let settings = AppSettings.shared
        self.id = id
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
    }

    var displayTitle: String {
        if !title.isEmpty { return title }
        let component = (currentDirectory as NSString).lastPathComponent
        return component.isEmpty ? "Terminal" : component
    }

    var abbreviatedDirectory: String {
        let home = NSHomeDirectory()
        if currentDirectory == home { return "~" }
        if currentDirectory.hasPrefix(home + "/") {
            return "~" + currentDirectory.dropFirst(home.count)
        }
        return currentDirectory
    }

    func startIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true

        let settings = AppSettings.shared
        let shell = settings.resolvedShell()

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["TERM_PROGRAM"] = "iTERMiNAL"
        let environmentList = env.map { "\($0.key)=\($0.value)" }

        engine.start(TerminalLaunchConfiguration(
            executable: shell.path,
            args: shell.args,
            execName: shell.execName,
            environment: environmentList,
            initialDirectory: currentDirectory
        ))
        isRunning = true
        refreshGitBranch()
    }

    func send(text: String) {
        engine.send(text: text)
    }

    func applyAppearance(settings: AppSettings, darkMode: Bool) {
        let theme: Theme = darkMode ? .dark : .light
        engine.apply(TerminalAppearance(
            font: settings.resolvedTerminalFont(),
            background: theme.terminalBackground,
            foreground: theme.terminalForeground,
            backgroundAlpha: CGFloat(settings.backgroundOpacity)
        ))
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

    /// Walks up from `path` looking for .git/HEAD; returns the branch name,
    /// a short SHA when detached, or nil outside a repository.
    static func gitBranch(startingAt path: String) -> String? {
        var url = URL(fileURLWithPath: path)
        for _ in 0..<16 {
            let head = url.appendingPathComponent(".git").appendingPathComponent("HEAD")
            if let contents = try? String(contentsOf: head, encoding: .utf8) {
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
}

extension TerminalSession: TerminalEngineDelegate {
    func engineTitleChanged(_ title: String) {
        self.title = title
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
        currentDirectory = path
        refreshGitBranch()
        WorkspaceStore.shared.scheduleSave()
    }

    func engineProcessTerminated(exitCode: Int32?) {
        isRunning = false
        lastExitCode = exitCode
    }
}
