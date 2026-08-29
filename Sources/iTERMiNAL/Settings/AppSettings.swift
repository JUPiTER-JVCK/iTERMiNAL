import SwiftUI
import AppKit
import ServiceManagement

/// All user preferences, persisted to UserDefaults and published for live UI
/// updates. Every property applies immediately except the ones the settings
/// UI labels "applies to new terminals" (cursor style, scrollback), which are
/// read when a terminal session is created.
///
/// Secrets are never stored here — the local API token lives in the keychain
/// (see `KeychainStore`), and SSH authentication is delegated to the system
/// ssh-agent and key files rather than stored by this app.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    enum ThemeChoice: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var label: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
    }

    private let defaults = UserDefaults.standard

    // MARK: General
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: "launchAtLogin")
            applyLaunchAtLogin()
        }
    }
    @Published var restoreSession: Bool { didSet { defaults.set(restoreSession, forKey: "restoreSession") } }
    @Published var shellPath: String { didSet { defaults.set(shellPath, forKey: "shellPath") } }
    @Published var loginShell: Bool { didSet { defaults.set(loginShell, forKey: "loginShell") } }
    @Published var defaultDirectory: String { didSet { defaults.set(defaultDirectory, forKey: "defaultDirectory") } }

    // MARK: Appearance
    @Published var theme: ThemeChoice {
        didSet {
            defaults.set(theme.rawValue, forKey: "theme")
            applyAppearance()
        }
    }
    @Published var accentID: String { didSet { defaults.set(accentID, forKey: "accentID") } }
    @Published var backgroundOpacity: Double { didSet { defaults.set(backgroundOpacity, forKey: "backgroundOpacity") } }
    /// The reference app draws a flat sidebar; macOS vibrancy is offered as
    /// an opt-in for people who prefer the native translucent look.
    @Published var sidebarTranslucent: Bool { didSet { defaults.set(sidebarTranslucent, forKey: "sidebarTranslucent") } }

    // MARK: Terminal
    @Published var terminalFontName: String { didSet { defaults.set(terminalFontName, forKey: "terminalFontName") } }
    @Published var terminalFontSize: Double { didSet { defaults.set(terminalFontSize, forKey: "terminalFontSize") } }
    @Published var cursorStyleTag: String { didSet { defaults.set(cursorStyleTag, forKey: "cursorStyleTag") } }
    @Published var scrollbackLines: Int { didSet { defaults.set(scrollbackLines, forKey: "scrollbackLines") } }
    @Published var terminalThemeID: String { didSet { defaults.set(terminalThemeID, forKey: "terminalThemeID") } }
    @Published var useGPURendering: Bool { didSet { defaults.set(useGPURendering, forKey: "useGPURendering") } }

    // MARK: Panels
    @Published var browserHomepage: String { didSet { defaults.set(browserHomepage, forKey: "browserHomepage") } }
    @Published var showHiddenFiles: Bool { didSet { defaults.set(showHiddenFiles, forKey: "showHiddenFiles") } }
    @Published var followTerminalDirectory: Bool { didSet { defaults.set(followTerminalDirectory, forKey: "followTerminalDirectory") } }
    @Published var composerEnabled: Bool { didSet { defaults.set(composerEnabled, forKey: "composerEnabled") } }
    /// Panel geometry, persisted so a resized layout survives relaunch.
    @Published var rightPanelWidth: Double { didSet { defaults.set(rightPanelWidth, forKey: "rightPanelWidth") } }
    @Published var bottomDockHeight: Double { didSet { defaults.set(bottomDockHeight, forKey: "bottomDockHeight") } }

    /// Where the floating composer sits, relative to its default position,
    /// and whether it is collapsed to a pill.
    @Published var composerOffsetX: Double { didSet { defaults.set(composerOffsetX, forKey: "composerOffsetX") } }
    @Published var composerOffsetY: Double { didSet { defaults.set(composerOffsetY, forKey: "composerOffsetY") } }
    @Published var composerCollapsed: Bool { didSet { defaults.set(composerCollapsed, forKey: "composerCollapsed") } }
    @Published var composerTranscriptHeight: Double { didSet { defaults.set(composerTranscriptHeight, forKey: "composerTranscriptHeight") } }
    /// Shell the composer's own session runs. Empty means "same as everything
    /// else"; a path here changes only the composer, so trying something in
    /// bash doesn't change what every new tab opens as.
    @Published var composerShell: String { didSet { defaults.set(composerShell, forKey: "composerShell") } }

    // MARK: Sidebar section state
    @Published var pinnedExpanded: Bool { didSet { defaults.set(pinnedExpanded, forKey: "pinnedExpanded") } }
    @Published var projectsExpanded: Bool { didSet { defaults.set(projectsExpanded, forKey: "projectsExpanded") } }
    @Published var recentsExpanded: Bool { didSet { defaults.set(recentsExpanded, forKey: "recentsExpanded") } }

    // MARK: Security / automation
    /// The local socket API is powerful (it can type into live shells), so it
    /// is opt-in and off until the user turns it on.
    @Published var localAPIEnabled: Bool {
        didSet {
            defaults.set(localAPIEnabled, forKey: "localAPIEnabled")
            LocalAPIServer.shared.applyEnabledState(localAPIEnabled)
        }
    }
    @Published var apiAllowBrowserControl: Bool { didSet { defaults.set(apiAllowBrowserControl, forKey: "apiAllowBrowserControl") } }
    @Published var apiAllowTerminalInput: Bool { didSet { defaults.set(apiAllowTerminalInput, forKey: "apiAllowTerminalInput") } }

    // MARK: Connections (SSH/SFTP)
    @Published var sshConnections: [SSHConnection] {
        didSet { persistConnections() }
    }

    private init() {
        launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        restoreSession = defaults.object(forKey: "restoreSession") as? Bool ?? true
        shellPath = defaults.string(forKey: "shellPath") ?? ""
        loginShell = defaults.object(forKey: "loginShell") as? Bool ?? true
        defaultDirectory = defaults.string(forKey: "defaultDirectory") ?? ""

        theme = ThemeChoice(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system
        accentID = defaults.string(forKey: "accentID") ?? "green"
        backgroundOpacity = defaults.object(forKey: "backgroundOpacity") as? Double ?? 1.0
        sidebarTranslucent = defaults.bool(forKey: "sidebarTranslucent")

        terminalFontName = defaults.string(forKey: "terminalFontName") ?? ""
        terminalFontSize = defaults.object(forKey: "terminalFontSize") as? Double ?? 13
        cursorStyleTag = defaults.string(forKey: "cursorStyleTag") ?? "steadyBlock"
        scrollbackLines = defaults.object(forKey: "scrollbackLines") as? Int ?? 10_000
        terminalThemeID = defaults.string(forKey: "terminalThemeID") ?? "auto"
        useGPURendering = defaults.bool(forKey: "useGPURendering")

        browserHomepage = defaults.string(forKey: "browserHomepage") ?? "https://www.google.com"
        showHiddenFiles = defaults.bool(forKey: "showHiddenFiles")
        followTerminalDirectory = defaults.object(forKey: "followTerminalDirectory") as? Bool ?? true
        composerEnabled = defaults.object(forKey: "composerEnabled") as? Bool ?? true
        rightPanelWidth = defaults.object(forKey: "rightPanelWidth") as? Double ?? 420
        bottomDockHeight = defaults.object(forKey: "bottomDockHeight") as? Double ?? 260
        composerOffsetX = defaults.object(forKey: "composerOffsetX") as? Double ?? 0
        composerOffsetY = defaults.object(forKey: "composerOffsetY") as? Double ?? 0
        composerCollapsed = defaults.bool(forKey: "composerCollapsed")
        composerTranscriptHeight = defaults.object(forKey: "composerTranscriptHeight") as? Double ?? 200
        composerShell = defaults.string(forKey: "composerShell") ?? ""

        pinnedExpanded = defaults.object(forKey: "pinnedExpanded") as? Bool ?? true
        projectsExpanded = defaults.object(forKey: "projectsExpanded") as? Bool ?? true
        recentsExpanded = defaults.object(forKey: "recentsExpanded") as? Bool ?? false

        localAPIEnabled = defaults.bool(forKey: "localAPIEnabled")
        apiAllowBrowserControl = defaults.object(forKey: "apiAllowBrowserControl") as? Bool ?? true
        apiAllowTerminalInput = defaults.object(forKey: "apiAllowTerminalInput") as? Bool ?? true

        if let data = defaults.data(forKey: "sshConnections"),
           let decoded = try? JSONDecoder().decode([SSHConnection].self, from: data) {
            sshConnections = decoded
        } else {
            sshConnections = []
        }

        // `didSet` doesn't fire during init, so reconcile the login item with
        // the stored preference on every launch.
        applyLaunchAtLogin()
    }

    private func persistConnections() {
        if let data = try? JSONEncoder().encode(sshConnections) {
            defaults.set(data, forKey: "sshConnections")
        }
    }

    // MARK: Derived values

    var preferredColorScheme: ColorScheme? {
        switch theme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Forces the whole process's appearance, which `preferredColorScheme`
    /// alone does not.
    ///
    /// Two things went wrong before this existed. SwiftUI does not reliably
    /// un-force a window when the modifier goes back to nil, so returning to
    /// System after picking Light or Dark left the window stuck — cycling the
    /// three settings was the reliable way to see it. And the modifier only
    /// governs SwiftUI's own views: the terminal is an AppKit view, and the
    /// menu bar and titlebar are the system's, so all three kept following the
    /// system while the chrome around them did not.
    ///
    /// Setting `NSApp.appearance` covers every one of those, and nil genuinely
    /// means "follow the system" here.
    func applyAppearance() {
        let appearance: NSAppearance?
        switch theme {
        case .system: appearance = nil
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
        NSApp?.appearance = appearance
    }

    var accentColor: Color { Accents.color(for: accentID) }

    func resolvedTerminalFont() -> NSFont {
        let size = CGFloat(terminalFontSize)
        if !terminalFontName.isEmpty, let font = NSFont(name: terminalFontName, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func resolvedTerminalTheme(darkMode: Bool) -> TerminalTheme {
        TerminalTheme.theme(id: terminalThemeID, darkMode: darkMode)
    }

    /// The shell binary, launch args, and argv[0] override for new sessions.
    ///
    /// `override` lets one session run a different shell from the rest — the
    /// composer offers this, so you can try something in bash without changing
    /// what every other terminal opens as.
    func resolvedShell(override: String? = nil) -> (path: String, args: [String], execName: String?) {
        var path = (override ?? shellPath).trimmingCharacters(in: .whitespaces)
        if path.isEmpty {
            path = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        }
        if !FileManager.default.isExecutableFile(atPath: path) {
            path = "/bin/zsh"
        }
        let name = (path as NSString).lastPathComponent
        // A leading "-" in argv[0] is the Unix convention for a login shell.
        return (path, [], loginShell ? "-" + name : nil)
    }

    var resolvedInitialDirectory: String {
        let dir = (defaultDirectory as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        if !dir.isEmpty,
           FileManager.default.fileExists(atPath: dir, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return dir
        }
        return NSHomeDirectory()
    }

    func connection(withID id: String) -> SSHConnection? {
        sshConnections.first { $0.id.uuidString == id || $0.name == id }
    }

    private func applyLaunchAtLogin() {
        // Only touch the login item when it actually disagrees with the
        // preference, so launching the app isn't doing pointless work.
        let isRegistered = SMAppService.mainApp.status == .enabled
        guard isRegistered != launchAtLogin else { return }
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Launch-at-login update failed: \(error.localizedDescription)")
        }
    }

    func resetToDefaults() {
        launchAtLogin = false
        restoreSession = true
        shellPath = ""
        loginShell = true
        defaultDirectory = ""
        theme = .system
        accentID = "green"
        backgroundOpacity = 1.0
        sidebarTranslucent = false
        terminalFontName = ""
        terminalFontSize = 13
        cursorStyleTag = "steadyBlock"
        scrollbackLines = 10_000
        terminalThemeID = "auto"
        useGPURendering = false
        browserHomepage = "https://www.google.com"
        showHiddenFiles = false
        followTerminalDirectory = true
        composerEnabled = true
        rightPanelWidth = 420
        bottomDockHeight = 260
        composerOffsetX = 0
        composerOffsetY = 0
        composerCollapsed = false
        composerTranscriptHeight = 200
        composerShell = ""
        localAPIEnabled = false
        apiAllowBrowserControl = true
        apiAllowTerminalInput = true
    }
}
