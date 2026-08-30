import AppKit
import Foundation

/// A portable snapshot of workspaces plus preferences.
///
/// Secrets are deliberately absent: the local API token stays in the keychain
/// and never leaves this Mac, and SSH connections carry no password because
/// the app never has one (authentication is delegated to ssh-agent and key
/// files). Machine-specific settings such as launch-at-login are also skipped.
struct WorkspaceArchive: Codable {
    static let currentVersion = 1

    var version: Int
    var exportedAt: Date
    var state: AppStateSnapshot
    var preferences: PreferencesArchive
}

struct PreferencesArchive: Codable {
    var theme: String
    var accentID: String
    var backgroundOpacity: Double
    var shellPath: String
    var loginShell: Bool
    var defaultDirectory: String
    var terminalFontName: String
    var terminalFontSize: Double
    var cursorStyleTag: String
    var scrollbackLines: Int
    var terminalThemeID: String
    var useGPURendering: Bool
    var browserHomepage: String
    var showHiddenFiles: Bool
    var followTerminalDirectory: Bool
    var composerEnabled: Bool
    /// Composer look and geometry. Optional so archives written before these
    /// existed still decode.
    ///
    /// `composerShell` is deliberately absent: it is an absolute path to a
    /// binary on one machine, and carrying it to another would either point at
    /// nothing or — worse — at a different program with the same name.
    var composerWidth: Double?
    var composerOpacity: Double?
    var composerVibrancy: Bool?
    var composerTranscriptHeight: Double?
    var connections: [SSHConnection]

    init(settings: AppSettings) {
        theme = settings.theme.rawValue
        accentID = settings.accentID
        backgroundOpacity = settings.backgroundOpacity
        shellPath = settings.shellPath
        loginShell = settings.loginShell
        defaultDirectory = settings.defaultDirectory
        terminalFontName = settings.terminalFontName
        terminalFontSize = settings.terminalFontSize
        cursorStyleTag = settings.cursorStyleTag
        scrollbackLines = settings.scrollbackLines
        terminalThemeID = settings.terminalThemeID
        useGPURendering = settings.useGPURendering
        browserHomepage = settings.browserHomepage
        showHiddenFiles = settings.showHiddenFiles
        followTerminalDirectory = settings.followTerminalDirectory
        composerEnabled = settings.composerEnabled
        composerWidth = settings.composerWidth
        composerOpacity = settings.composerOpacity
        composerVibrancy = settings.composerVibrancy
        composerTranscriptHeight = settings.composerTranscriptHeight
        connections = settings.sshConnections
    }

    func apply(to settings: AppSettings) {
        settings.theme = AppSettings.ThemeChoice(rawValue: theme) ?? .system
        settings.accentID = accentID
        settings.backgroundOpacity = backgroundOpacity
        settings.shellPath = shellPath
        settings.loginShell = loginShell
        settings.defaultDirectory = defaultDirectory
        settings.terminalFontName = terminalFontName
        settings.terminalFontSize = terminalFontSize
        settings.cursorStyleTag = cursorStyleTag
        settings.scrollbackLines = scrollbackLines
        settings.terminalThemeID = terminalThemeID
        settings.useGPURendering = useGPURendering
        settings.browserHomepage = browserHomepage
        settings.showHiddenFiles = showHiddenFiles
        settings.followTerminalDirectory = followTerminalDirectory
        settings.composerEnabled = composerEnabled
        // Only overwrite when the archive carried a value: an older export
        // should leave the current settings alone rather than reset them.
        if let composerWidth { settings.composerWidth = composerWidth }
        if let composerOpacity { settings.composerOpacity = composerOpacity }
        if let composerVibrancy { settings.composerVibrancy = composerVibrancy }
        if let composerTranscriptHeight {
            settings.composerTranscriptHeight = composerTranscriptHeight
        }
        settings.sshConnections = connections
    }
}

enum ArchiveError: LocalizedError {
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "This snapshot was written by a newer version of iTERMiNAL (format \(version))."
        }
    }
}

enum WorkspaceArchiveIO {
    static let fileExtension = "iterminal"

    /// Prompts for a destination and writes the snapshot.
    static func promptExport(store: WorkspaceStore, settings: AppSettings) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "iTERMiNAL-workspaces.\(fileExtension)"
        panel.prompt = "Export"
        panel.message = "Workspaces and preferences. Secrets are not included."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let archive = WorkspaceArchive(
            version: WorkspaceArchive.currentVersion,
            exportedAt: Date(),
            state: store.currentSnapshot(),
            preferences: PreferencesArchive(settings: settings)
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(archive).write(to: url, options: .atomic)
        } catch {
            presentError(error)
        }
    }

    /// Prompts for a snapshot and restores it, replacing current workspaces.
    static func promptImport(store: WorkspaceStore, settings: AppSettings) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let archive = try decoder.decode(WorkspaceArchive.self, from: Data(contentsOf: url))
            guard archive.version <= WorkspaceArchive.currentVersion else {
                throw ArchiveError.unsupportedVersion(archive.version)
            }
            archive.preferences.apply(to: settings)
            store.applySnapshot(archive.state)
        } catch {
            presentError(error)
        }
    }

    private static func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Snapshot failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
