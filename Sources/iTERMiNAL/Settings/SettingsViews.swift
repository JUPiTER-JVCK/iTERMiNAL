import SwiftUI
import AppKit

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, terminal, panels, connections, security, sync, shortcuts, advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .terminal: return "Terminal"
        case .panels: return "Panels"
        case .connections: return "Connections"
        case .security: return "Security"
        case .sync: return "Sync"
        case .shortcuts: return "Shortcuts"
        case .advanced: return "Advanced"
        }
    }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .terminal: return "terminal"
        case .panels: return "sidebar.right"
        case .connections: return "network"
        case .security: return "lock.shield"
        case .sync: return "arrow.triangle.2.circlepath"
        case .shortcuts: return "keyboard"
        case .advanced: return "wrench.and.screwdriver"
        }
    }
}

/// Compact settings window: a section list on the left, grouped forms on the
/// right, everything applying live.
struct SettingsRootView: View {
    @State private var selection: SettingsSection? = .general

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .frame(width: 185)

            Divider()

            Group {
                switch selection ?? .general {
                case .general: GeneralSettingsView()
                case .appearance: AppearanceSettingsView()
                case .terminal: TerminalSettingsView()
                case .panels: PanelsSettingsView()
                case .connections: ConnectionsSettingsView()
                case .security: SecuritySettingsView()
                case .sync: SyncSettingsView()
                case .shortcuts: ShortcutsSettingsView()
                case .advanced: AdvancedSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 780, height: 520)
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
                Toggle("Restore workspaces on launch", isOn: $settings.restoreSession)
            }
            Section("Shell") {
                Picker("Shell", selection: $settings.shellPath) {
                    Text("Automatic (login shell)").tag("")
                    Text("zsh").tag("/bin/zsh")
                    Text("bash").tag("/bin/bash")
                    Text("fish (Homebrew)").tag("/opt/homebrew/bin/fish")
                }
                Toggle("Run as login shell", isOn: $settings.loginShell)
                HStack {
                    TextField("Default directory", text: $settings.defaultDirectory, prompt: Text("~"))
                    Button("Choose…") { chooseDirectory() }
                }
                Text("Shell changes apply to new terminals.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            settings.defaultDirectory = url.path
        }
    }
}

struct AppearanceSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $settings.theme) {
                    ForEach(AppSettings.ThemeChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section("Accent") {
                HStack(spacing: 12) {
                    ForEach(Accents.all) { option in
                        Button {
                            settings.accentID = option.id
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(option.color)
                                    .frame(width: 22, height: 22)
                                if settings.accentID == option.id {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .help(option.name)
                    }
                }
                .padding(.vertical, 2)
            }
            Section("Window") {
                HStack {
                    Slider(value: $settings.backgroundOpacity, in: 0.5...1.0)
                    Text("\(Int(settings.backgroundOpacity * 100))%")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
                Text("Terminal background opacity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct TerminalSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    private static let monospacedFamilies: [String] = {
        NSFontManager.shared.availableFontFamilies.filter { family in
            NSFont(name: family, size: 12)?.isFixedPitch == true
        }
        .sorted()
    }()

    private let cursorStyles: [(tag: String, label: String)] = [
        ("steadyBlock", "Block"),
        ("blinkBlock", "Blinking Block"),
        ("steadyBar", "Bar"),
        ("blinkBar", "Blinking Bar"),
        ("steadyUnderline", "Underline"),
        ("blinkUnderline", "Blinking Underline"),
    ]

    var body: some View {
        Form {
            Section("Colors") {
                Picker("Terminal theme", selection: $settings.terminalThemeID) {
                    Text("Match system appearance").tag("auto")
                    Divider()
                    ForEach(TerminalTheme.all) { theme in
                        Text(theme.name).tag(theme.id)
                    }
                }
            }
            Section("Font") {
                Picker("Font", selection: $settings.terminalFontName) {
                    Text("System monospace (SF Mono)").tag("")
                    ForEach(Self.monospacedFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                HStack {
                    Slider(value: $settings.terminalFontSize, in: 9...24, step: 1)
                    Text("\(Int(settings.terminalFontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }
            }
            Section("Cursor") {
                Picker("Cursor style", selection: $settings.cursorStyleTag) {
                    ForEach(cursorStyles, id: \.tag) { style in
                        Text(style.label).tag(style.tag)
                    }
                }
                Text("Applies to new terminals.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Scrollback") {
                Stepper(value: $settings.scrollbackLines, in: 500...200_000, step: 500) {
                    Text("\(settings.scrollbackLines) lines")
                        .monospacedDigit()
                }
                Text("Applies to new terminals.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Performance") {
                Toggle("GPU rendering (experimental)", isOn: $settings.useGPURendering)
                Text("Draws the terminal with Metal for smoother scrolling. The renderer is still experimental upstream; if it can't start, terminals silently keep using the CPU renderer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct PanelsSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Composer") {
                Toggle("Show composer bar", isOn: $settings.composerEnabled)
            }
            Section("Browser") {
                TextField("Homepage", text: $settings.browserHomepage)
            }
            Section("Files") {
                Toggle("Show hidden files", isOn: $settings.showHiddenFiles)
                Toggle("Follow the focused terminal's directory", isOn: $settings.followTerminalDirectory)
            }
        }
        .formStyle(.grouped)
    }
}

/// SSH hosts for the file panel's remote mode.
struct ConnectionsSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var selectedID: UUID?

    var body: some View {
        Form {
            Section("Saved hosts") {
                if settings.sshConnections.isEmpty {
                    Text("No hosts yet. Add one to browse it in the Files panel over SFTP.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Host", selection: $selectedID) {
                        Text("None").tag(UUID?.none)
                        ForEach(settings.sshConnections) { connection in
                            Text("\(connection.name) — \(connection.subtitle)").tag(UUID?.some(connection.id))
                        }
                    }
                }
                HStack {
                    Button("Add Host") { addConnection() }
                    if let selectedID {
                        Button("Remove", role: .destructive) { remove(selectedID) }
                    }
                }
            }

            if let selectedID, let binding = connectionBinding(selectedID) {
                Section("Details") {
                    TextField("Name", text: binding.name)
                    Picker("Transport", selection: binding.transport) {
                        ForEach(SSHTransport.allCases) { transport in
                            Text(transport.label).tag(transport)
                        }
                    }
                    TextField("Host", text: binding.host)
                    TextField("Username", text: binding.username)
                    TextField("Port", value: binding.port, format: .number)
                    TextField("Identity file (optional)", text: Binding(
                        get: { binding.wrappedValue.identityFile ?? "" },
                        set: { binding.wrappedValue.identityFile = $0.isEmpty ? nil : $0 }
                    ), prompt: Text("~/.ssh/id_ed25519"))
                    TextField("Start directory (optional)", text: Binding(
                        get: { binding.wrappedValue.initialPath ?? "" },
                        set: { binding.wrappedValue.initialPath = $0.isEmpty ? nil : $0 }
                    ), prompt: Text("~"))

                    if binding.wrappedValue.transport == .custom {
                        TextField("Command", text: binding.customCommand,
                                  prompt: Text("tailscale ssh %u@%h"))
                        Text("Runs in the terminal as written. %h, %p, %u, and %d expand to host, port, username, and user@host.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        TextField("Extra arguments (optional)", text: binding.extraArguments,
                                  prompt: Text("-A -J bastion"))
                    }
                }
            }

            Section("Authentication") {
                Text("""
                iTERMiNAL never stores SSH passwords. Both remote features run the system's own clients, reusing your ssh-agent, keys, and known_hosts.

                Terminal sessions get a real TTY, so ssh can prompt you for a password or 2FA code itself. The file browser runs sftp non-interactively (it has no TTY to prompt on), so browsing a host requires key-based authentication.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func addConnection() {
        let connection = SSHConnection(name: "New Host", host: "", username: NSUserName())
        settings.sshConnections.append(connection)
        selectedID = connection.id
    }

    private func remove(_ id: UUID) {
        settings.sshConnections.removeAll { $0.id == id }
        selectedID = nil
    }

    /// Looks the element up by id on every access, so the binding stays valid
    /// even when the list is reordered or edited underneath it.
    private func connectionBinding(_ id: UUID) -> Binding<SSHConnection>? {
        guard settings.sshConnections.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: {
                settings.sshConnections.first { $0.id == id }
                    ?? SSHConnection(name: "", host: "", username: "")
            },
            set: { newValue in
                guard let index = settings.sshConnections.firstIndex(where: { $0.id == id }) else { return }
                settings.sshConnections[index] = newValue
            }
        )
    }
}

/// The local scripting API's controls, plus a plain statement of what the app
/// does and doesn't do with the user's data.
struct SecuritySettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var installMessage: String?
    @State private var tokenMessage: String?

    var body: some View {
        Form {
            Section("Local scripting API") {
                Toggle("Enable local API", isOn: $settings.localAPIEnabled)
                Text("Lets scripts, the iterminalctl command, and AI agents drive this app over a Unix socket. It can type into live shells, so it stays off until you turn it on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.localAPIEnabled {
                    Toggle("Allow sending input to terminals", isOn: $settings.apiAllowTerminalInput)
                    Toggle("Allow controlling the browser pane", isOn: $settings.apiAllowBrowserControl)

                    LabeledContent("Socket") {
                        Text(LocalAPIServer.shared.socketPath)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }

                    HStack {
                        Button("Copy Token") {
                            // A nil token means the keychain refused or the
                            // RNG failed; say so rather than copying nothing.
                            guard let token = LocalAPIServer.shared.ensureToken() else {
                                tokenMessage = "Couldn't read or create a token in your keychain."
                                return
                            }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(token, forType: .string)
                            tokenMessage = "Token copied to the clipboard."
                        }
                        Button("Regenerate Token") {
                            tokenMessage = LocalAPIServer.shared.regenerateToken() == nil
                                ? "Couldn't create a new token in your keychain."
                                : "New token created. The old one no longer works."
                        }
                    }

                    if let tokenMessage {
                        Text(tokenMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if settings.localAPIEnabled {
                Section("Command line tool") {
                    Button("Install iterminalctl…") { installCLI() }
                    if let installMessage {
                        Text(installMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Copies the bundled iterminalctl into ~/.local/bin.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("How your data is handled") {
                Text("""
                • The API socket is created with owner-only permissions inside a private folder, and every request must present a token kept in your keychain.
                • Secrets live only in the keychain — never in preferences, the saved layout, or exported snapshots.
                • SSH authentication is delegated to the system; this app cannot prompt for or store a password.
                • App Transport Security stays enabled; only the embedded web view may load plain HTTP, so you can preview a local dev server.
                • A terminal can't run inside the macOS sandbox — it exists to launch your programs — so capabilities are narrowed individually instead.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func installCLI() {
        guard let source = Bundle.main.url(forResource: "iterminalctl", withExtension: nil) else {
            installMessage = "The bundled tool wasn't found in the app bundle."
            return
        }
        let destinationDirectory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/bin", isDirectory: true)
        let destination = destinationDirectory.appendingPathComponent("iterminalctl")
        do {
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            installMessage = "Installed to \(destination.path). Add ~/.local/bin to your PATH if it isn't already."
        } catch {
            installMessage = "Install failed: \(error.localizedDescription)"
        }
    }
}

struct SyncSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("Mode", value: LocalOnlySyncEngine.shared.displayName)
                Text(LocalOnlySyncEngine.shared.statusDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("State file") {
                    Text(store.stateFileURL.path)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.stateFileURL])
                }
            }

            Section("Snapshots") {
                HStack {
                    Button("Export Workspaces…") {
                        WorkspaceArchiveIO.promptExport(store: store, settings: settings)
                    }
                    Button("Import Workspaces…") {
                        WorkspaceArchiveIO.promptImport(store: store, settings: settings)
                    }
                }
                Text("A snapshot carries your workspaces, tabs, split layout, and preferences — but no secrets. Importing replaces the current layout.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("iCloud") {
                Text("Cross-device sync over iCloud isn't wired up yet: it needs a paid Apple Developer account, the iCloud entitlement, and a signed build, which a source build doesn't have. The sync layer is written as a seam so it can be added without changing the rest of the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ShortcutsSettingsView: View {
    private let shortcuts: [(action: String, keys: String)] = [
        ("Command palette", "⌘K"),
        ("New terminal tab", "⌘T"),
        ("New workspace", "⇧⌘N"),
        ("Split right", "⌘D"),
        ("Split down", "⇧⌘D"),
        ("Split with browser", "⇧⌘B"),
        ("Close pane", "⇧⌘W"),
        ("Close tab", "⌥⌘W"),
        ("Toggle browser panel", "⌥⌘B"),
        ("Toggle files panel", "⌥⌘F"),
        ("Settings", "⌘,"),
    ]

    var body: some View {
        Form {
            Section("Keyboard shortcuts") {
                ForEach(shortcuts, id: \.action) { shortcut in
                    HStack {
                        Text(shortcut.action)
                        Spacer()
                        Text(shortcut.keys)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Custom key bindings are on the roadmap.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct AdvancedSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        Form {
            Section("Session state") {
                Button("Save Session Now") { store.saveNow() }
                Button("Reveal State File in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.stateFileURL])
                }
            }
            Section("Reset") {
                Button("Reset All Settings", role: .destructive) {
                    settings.resetToDefaults()
                }
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
            }
        }
        .formStyle(.grouped)
    }
}
