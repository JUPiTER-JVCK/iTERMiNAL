import SwiftUI
import AppKit
import ServiceManagement

/// All user preferences, persisted to UserDefaults and published for live UI
/// updates. Every property applies immediately except the ones the settings
/// UI labels "applies to new terminals" (cursor style, scrollback), which are
/// read when a terminal session is created.
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
    @Published var theme: ThemeChoice { didSet { defaults.set(theme.rawValue, forKey: "theme") } }
    @Published var accentID: String { didSet { defaults.set(accentID, forKey: "accentID") } }
    @Published var backgroundOpacity: Double { didSet { defaults.set(backgroundOpacity, forKey: "backgroundOpacity") } }

    // MARK: Terminal
    @Published var terminalFontName: String { didSet { defaults.set(terminalFontName, forKey: "terminalFontName") } }
    @Published var terminalFontSize: Double { didSet { defaults.set(terminalFontSize, forKey: "terminalFontSize") } }
    @Published var cursorStyleTag: String { didSet { defaults.set(cursorStyleTag, forKey: "cursorStyleTag") } }
    @Published var scrollbackLines: Int { didSet { defaults.set(scrollbackLines, forKey: "scrollbackLines") } }

    // MARK: Panels
    @Published var browserHomepage: String { didSet { defaults.set(browserHomepage, forKey: "browserHomepage") } }
    @Published var showHiddenFiles: Bool { didSet { defaults.set(showHiddenFiles, forKey: "showHiddenFiles") } }
    @Published var followTerminalDirectory: Bool { didSet { defaults.set(followTerminalDirectory, forKey: "followTerminalDirectory") } }
    @Published var composerEnabled: Bool { didSet { defaults.set(composerEnabled, forKey: "composerEnabled") } }

    private init() {
        launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        restoreSession = defaults.object(forKey: "restoreSession") as? Bool ?? true
        shellPath = defaults.string(forKey: "shellPath") ?? ""
        loginShell = defaults.object(forKey: "loginShell") as? Bool ?? true
        defaultDirectory = defaults.string(forKey: "defaultDirectory") ?? ""

        theme = ThemeChoice(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system
        accentID = defaults.string(forKey: "accentID") ?? "green"
        backgroundOpacity = defaults.object(forKey: "backgroundOpacity") as? Double ?? 1.0

        terminalFontName = defaults.string(forKey: "terminalFontName") ?? ""
        terminalFontSize = defaults.object(forKey: "terminalFontSize") as? Double ?? 13
        cursorStyleTag = defaults.string(forKey: "cursorStyleTag") ?? "steadyBlock"
        scrollbackLines = defaults.object(forKey: "scrollbackLines") as? Int ?? 10_000

        browserHomepage = defaults.string(forKey: "browserHomepage") ?? "https://www.google.com"
        showHiddenFiles = defaults.bool(forKey: "showHiddenFiles")
        followTerminalDirectory = defaults.object(forKey: "followTerminalDirectory") as? Bool ?? true
        composerEnabled = defaults.object(forKey: "composerEnabled") as? Bool ?? true
    }

    // MARK: Derived values

    var preferredColorScheme: ColorScheme? {
        switch theme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var accentColor: Color { Accents.color(for: accentID) }

    func resolvedTerminalFont() -> NSFont {
        let size = CGFloat(terminalFontSize)
        if !terminalFontName.isEmpty, let font = NSFont(name: terminalFontName, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// The shell binary, launch args, and argv[0] override for new sessions.
    func resolvedShell() -> (path: String, args: [String], execName: String?) {
        var path = shellPath.trimmingCharacters(in: .whitespaces)
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

    private func applyLaunchAtLogin() {
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
        terminalFontName = ""
        terminalFontSize = 13
        cursorStyleTag = "steadyBlock"
        scrollbackLines = 10_000
        browserHomepage = "https://www.google.com"
        showHiddenFiles = false
        followTerminalDirectory = true
        composerEnabled = true
    }
}
