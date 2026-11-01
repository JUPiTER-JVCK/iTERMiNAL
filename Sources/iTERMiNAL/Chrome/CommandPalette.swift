import SwiftUI
import AppKit

struct PaletteAction: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let shortcut: String?
    let perform: () -> Void

    init(
        id: String,
        title: String,
        subtitle: String = "",
        systemImage: String,
        shortcut: String? = nil,
        perform: @escaping () -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.shortcut = shortcut
        self.perform = perform
    }
}

/// ⌘K palette: type to filter every app action, Enter to run the highlighted
/// one. Matching is a case-insensitive subsequence test, so "sb" finds
/// "Split with Browser".
struct CommandPaletteView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var searchFocused: Bool
    /// The files under the focused terminal's folder, listed once when the
    /// palette opens. Nil until that finishes, or when there is nothing to
    /// search (a remote tab, or a folder `FileSearch` will not walk).
    @State private var fileScan: FileScan?
    @State private var fileHits: [FileHit] = []
    /// The text `fileHits` was ranked for. Rows for any other text are still on
    /// screen for a moment while a keystroke is ranked, and are not run.
    @State private var fileHitsText = ""
    @State private var rankTask: Task<Void, Never>?

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                TextField("Run a command, or / to find a file…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($searchFocused)
                    .onSubmit(runSelected)
                    .onChange(of: query) { _, _ in
                        selectedIndex = 0
                        updateFileHits()
                    }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            FadedDivider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, action in
                            PaletteRow(action: action, isSelected: index == selectedIndex, theme: theme)
                                .id(action.id)
                                .contentShape(Rectangle())
                                .onTapGesture { run(action) }
                                .onHover { hovering in
                                    if hovering { selectedIndex = index }
                                }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selectedIndex) { _, index in
                    guard matches.indices.contains(index) else { return }
                    proxy.scrollTo(matches[index].id, anchor: .center)
                }
            }
            .frame(height: 320)
        }
        .frame(width: 560)
        .background(theme.background)
        .onMoveCommand { direction in
            switch direction {
            case .down: selectedIndex = min(selectedIndex + 1, max(matches.count - 1, 0))
            case .up: selectedIndex = max(selectedIndex - 1, 0)
            default: break
            }
        }
        .onExitCommand { dismiss() }
        .onAppear {
            searchFocused = true
            startFileScan()
        }
        .onDisappear { rankTask?.cancel() }
    }

    private var matches: [PaletteAction] {
        let actions = allActions()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return actions }
        // A leading "/" asks for files alone; otherwise the files follow the
        // actions, which have the first say.
        let found = FileSearch.parse(trimmed).filesOnly
            ? []
            : actions.filter { Self.matches(query: trimmed, in: $0.title + " " + $0.subtitle) }
        return found + fileActions()
    }

    // MARK: Files

    /// Lists the focused terminal's folder, off the main thread. A remote tab
    /// is not searched: the folder its session reports is this Mac's, not the
    /// host's.
    private func startFileScan() {
        guard let session = store.focusedSession, !session.isRemote else { return }
        session.refreshDirectoryFromProcess()
        let root = session.currentDirectory
        guard FileSearch.isSearchable(root: root, home: NSHomeDirectory()) else { return }
        Task.detached(priority: .userInitiated) {
            let scan = FileSearch.scan(root: root)
            await MainActor.run {
                fileScan = scan
                updateFileHits()
            }
        }
    }

    /// Ranks the files for the query as it stands, after a short pause for the
    /// keystrokes still arriving, and off the main thread.
    private func updateFileHits() {
        rankTask?.cancel()
        let text = currentFileText
        guard let files = fileScan?.files, text.count >= FileSearch.minQueryLength else {
            fileHits = []
            fileHitsText = text
            return
        }
        rankTask = Task {
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            let hits = await Task.detached(priority: .userInitiated) {
                FileSearch.rank(query: text, in: files)
            }.value
            guard !Task.isCancelled else { return }
            fileHits = hits
            fileHitsText = text
        }
    }

    /// What is being looked for among the files, as typed now.
    private var currentFileText: String {
        FileSearch.parse(query).text
    }

    private func fileActions() -> [PaletteAction] {
        guard let scan = fileScan, currentFileText.count >= FileSearch.minQueryLength else { return [] }
        var rows = fileHits.map { hit in
            PaletteAction(
                id: "file.\(hit.path)",
                title: hit.name,
                subtitle: hit.folder.isEmpty ? "Edit in terminal" : "Edit in terminal · \(hit.folder)",
                systemImage: "doc.text"
            ) {
                openFile(scan.root + "/" + hit.path)
            }
        }
        if scan.truncated {
            rows.append(PaletteAction(
                id: "files.truncated",
                title: FileSearch.truncationTitle,
                subtitle: FileSearch.truncationSubtitle,
                systemImage: "info.circle"
            ) {})
        }
        return rows
    }

    /// The File pane's "Edit in Terminal": the editor chosen in Settings, in a
    /// new tab beside the file. Only said aloud when it cannot be done.
    private func openFile(_ path: String) {
        guard let problem = store.editFile(at: path) else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn't open the file"
        alert.informativeText = problem
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func runSelected() {
        guard matches.indices.contains(selectedIndex) else { return }
        run(matches[selectedIndex])
    }

    private func run(_ action: PaletteAction) {
        // A file row ranked for what was typed a keystroke ago is not what was
        // asked for; the right ones arrive within a moment.
        if action.id.hasPrefix("file."), fileHitsText != currentFileText { return }
        dismiss()
        // Let the sheet close before the action mutates the window behind it.
        DispatchQueue.main.async { action.perform() }
    }

    /// Case-insensitive subsequence match: every query character appears in
    /// order somewhere in the candidate.
    static func matches(query: String, in candidate: String) -> Bool {
        var remaining = Substring(candidate.lowercased())
        for character in query.lowercased() where character != " " {
            guard let index = remaining.firstIndex(of: character) else { return false }
            remaining = remaining[remaining.index(after: index)...]
        }
        return true
    }

    /// The rest of what the menus can do, so that the palette finds every one of
    /// them — a check in scripts/input-logic-check compares the two, and the keys
    /// printed here with the shortcut list.
    private func moreMenuActions() -> [PaletteAction] {
        var actions: [PaletteAction] = []
        actions.append(PaletteAction(id: "tab.close", title: "Close Tab", systemImage: "xmark", shortcut: "⌃⌘W") {
            store.closeSelectedTab()
        })
        actions.append(PaletteAction(id: "panel.notes", title: "Toggle Notes Panel", systemImage: "sidebar.right", shortcut: "⌥⌘N") {
            store.togglePanel(.notes)
        })
        actions.append(PaletteAction(id: "tool.superfile", title: "Toggle superfile", subtitle: "A terminal file manager", systemImage: "sidebar.right", shortcut: "⌥⌘S") {
            store.togglePanel(.superfile)
        })
        actions.append(PaletteAction(id: "tool.btop", title: "Toggle btop", subtitle: "A resource monitor", systemImage: "sidebar.right", shortcut: "⌥⌘P") {
            store.togglePanel(.btop)
        })

        actions.append(PaletteAction(
            id: "composer.collapse",
            title: settings.composerCollapsed ? "Expand Composer" : "Minimise Composer",
            subtitle: settings.composerCollapsed ? "Bring the command box back" : "Shrink the command box to a pill",
            systemImage: "rectangle.compress.vertical",
            shortcut: "⇧⌘M"
        ) {
            withAnimation(Motion.panel) { settings.composerCollapsed.toggle() }
        })
        actions.append(PaletteAction(
            id: "composer.explain", title: "Explain Last Output",
            subtitle: "Ask the assistant about what the composer's terminal printed",
            systemImage: "questionmark.bubble", shortcut: "⌥⌘E"
        ) {
            store.requestComposerHelp(.explain)
        })
        actions.append(PaletteAction(
            id: "composer.fix", title: "Suggest a Fix", subtitle: "For an error; it is shown, never run",
            systemImage: "wrench.and.screwdriver", shortcut: "⌥⌘X"
        ) {
            store.requestComposerHelp(.fix)
        })

        // The same range the Appearance slider and the Terminal menu use.
        actions.append(PaletteAction(id: "font.bigger", title: "Bigger Text", subtitle: "Terminal text, a point larger", systemImage: "plus.magnifyingglass", shortcut: "⌘+") {
            settings.terminalFontSize = min(24, settings.terminalFontSize + 1)
        })
        actions.append(PaletteAction(id: "font.smaller", title: "Smaller Text", subtitle: "Terminal text, a point smaller", systemImage: "minus.magnifyingglass", shortcut: "⌘-") {
            settings.terminalFontSize = max(9, settings.terminalFontSize - 1)
        })
        actions.append(PaletteAction(id: "font.reset", title: "Actual Size", subtitle: "Terminal text at 13 pt", systemImage: "1.magnifyingglass", shortcut: "⌘0") {
            settings.terminalFontSize = 13
        })

        actions.append(PaletteAction(id: "settings.open", title: "Settings…", subtitle: "Preferences", systemImage: "gearshape", shortcut: "⌘,") {
            openSettings()
        })
        return actions
    }

    private func allActions() -> [PaletteAction] {
        var actions: [PaletteAction] = [
            PaletteAction(id: "tab.new", title: "New Terminal Tab", subtitle: "Open a shell", systemImage: "plus.square", shortcut: "⌘T") {
                store.newTab()
            },
            PaletteAction(id: "workspace.new", title: "New Workspace", subtitle: "Group of tabs", systemImage: "folder.badge.plus", shortcut: "⇧⌘N") {
                store.newWorkspace()
            },
            PaletteAction(id: "split.right", title: "Split Right", subtitle: "Terminal beside this one", systemImage: "rectangle.split.2x1", shortcut: "⌘D") {
                store.splitFocusedPane(.horizontal, kind: .terminal)
            },
            PaletteAction(id: "split.down", title: "Split Down", subtitle: "Terminal below this one", systemImage: "rectangle.split.1x2", shortcut: "⇧⌘D") {
                store.splitFocusedPane(.vertical, kind: .terminal)
            },
            PaletteAction(id: "split.browser", title: "Split with Browser", subtitle: "Preview a web app", systemImage: "globe", shortcut: "⇧⌘B") {
                store.splitFocusedPane(.horizontal, kind: .browser)
            },
            PaletteAction(id: "split.files", title: "Split with Files", subtitle: "Browse alongside", systemImage: "folder") {
                store.splitFocusedPane(.horizontal, kind: .files)
            },
            PaletteAction(id: "split.http", title: "Split with HTTP Client", subtitle: "Send requests alongside", systemImage: "arrow.up.arrow.down") {
                store.splitFocusedPane(.horizontal, kind: .http)
            },
            PaletteAction(id: "pane.close", title: "Close Pane", systemImage: "xmark.square", shortcut: "⇧⌘W") {
                store.closeFocusedPane()
            },
            PaletteAction(id: "panel.browser", title: "Toggle Browser Panel", systemImage: "sidebar.right", shortcut: "⌥⌘B") {
                store.togglePanel(.browser)
            },
            PaletteAction(id: "panel.files", title: "Toggle Files Panel", systemImage: "sidebar.right", shortcut: "⌥⌘F") {
                store.togglePanel(.files)
            },
            PaletteAction(id: "panel.http", title: "Toggle HTTP Client Panel", systemImage: "sidebar.right", shortcut: "⌥⌘R") {
                store.togglePanel(.http)
            },
            PaletteAction(id: "dock.toggle", title: "Toggle Terminal Dock", systemImage: "rectangle.bottomthird.inset.filled", shortcut: "⌘J") {
                store.toggleBottomDock()
            },
            PaletteAction(id: "sidebar.toggle", title: "Toggle Sidebar", subtitle: "Show or hide the workspaces panel", systemImage: "sidebar.left", shortcut: "⌃⌘S") {
                withAnimation(Motion.panel) { settings.railPanelOpen.toggle() }
            },
            PaletteAction(id: "sidebar.pin", title: settings.railPanelPinned ? "Unpin Sidebar" : "Pin Sidebar", subtitle: settings.railPanelPinned ? "Float the panel over the content" : "Keep the panel beside the content", systemImage: settings.railPanelPinned ? "pin.slash" : "pin") {
                withAnimation(Motion.panel) { settings.railPanelPinned.toggle() }
            },
            PaletteAction(id: "composer.focus", title: "Focus Composer", subtitle: "Run a command in its own shell", systemImage: "text.cursor", shortcut: "⇧⌘R") {
                store.focusComposer()
            },
            PaletteAction(id: "tasks.open", title: "Task Manager", subtitle: "Every shell this app is running", systemImage: "list.bullet.rectangle", shortcut: "⌥⌘T") {
                store.detailMode = .tasks
            },
            PaletteAction(id: "shortcuts.open", title: "Keyboard Shortcuts", subtitle: "Every shortcut in the app", systemImage: "keyboard", shortcut: "⌘/") {
                // The palette is still closing as this runs.
                store.showShortcuts(afterPresentation: true)
            },
        ]

        actions.append(contentsOf: moreMenuActions())

        for connection in settings.sshConnections {
            actions.append(PaletteAction(
                id: "connect.\(connection.id.uuidString)",
                title: "Connect to \(connection.name)",
                subtitle: connection.subtitle,
                systemImage: "network"
            ) {
                store.newTab(kind: .remote(connection.id))
            })
        }

        for theme in TerminalTheme.available {
            actions.append(PaletteAction(
                id: "theme.\(theme.id)",
                title: "Terminal Theme: \(theme.name)",
                subtitle: "Change colors",
                systemImage: "paintpalette"
            ) {
                settings.terminalThemeID = theme.id
            })
        }

        actions.append(PaletteAction(
            id: "theme.auto",
            title: "Terminal Theme: Match System",
            subtitle: "Follow light/dark",
            systemImage: "circle.lefthalf.filled"
        ) {
            settings.terminalThemeID = "auto"
        })

        actions.append(PaletteAction(
            id: "gpu.toggle",
            title: settings.useGPURendering ? "Disable GPU Rendering" : "Enable GPU Rendering",
            subtitle: "Experimental Metal renderer",
            systemImage: "bolt"
        ) {
            settings.useGPURendering.toggle()
        })

        actions.append(PaletteAction(
            id: "state.export",
            title: "Export Workspaces…",
            subtitle: "Portable snapshot",
            systemImage: "square.and.arrow.up"
        ) {
            WorkspaceArchiveIO.promptExport(store: store, settings: settings)
        })

        actions.append(PaletteAction(
            id: "state.import",
            title: "Import Workspaces…",
            subtitle: "Replace current layout",
            systemImage: "square.and.arrow.down"
        ) {
            WorkspaceArchiveIO.promptImport(store: store, settings: settings)
        })

        // Jump to a workspace itself, by its first tab: a workspace with no tab
        // has nowhere to go.
        for workspace in store.workspaces {
            guard let first = workspace.tabs.first else { continue }
            let count = workspace.tabs.count
            actions.append(PaletteAction(
                id: "workspace.goto.\(workspace.id.uuidString)",
                title: "Go to Workspace: \(workspace.name)",
                subtitle: count == 1 ? "1 tab" : "\(count) tabs",
                systemImage: "folder"
            ) {
                store.selectedTabID = first.id
            })
        }

        // Jump straight to any open tab.
        for workspace in store.workspaces {
            for tab in workspace.tabs {
                actions.append(PaletteAction(
                    id: "goto.\(tab.id.uuidString)",
                    title: "Go to \(tab.displayName)",
                    subtitle: workspace.name,
                    systemImage: "arrow.right.circle"
                ) {
                    store.selectedTabID = tab.id
                })
            }
        }

        return actions
    }
}

private struct PaletteRow: View {
    let action: PaletteAction
    let isSelected: Bool
    let theme: Theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: action.systemImage)
                .font(.system(size: 13))
                .frame(width: 20)
                .foregroundStyle(theme.textSecondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(action.title)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textPrimary)
                if !action.subtitle.isEmpty {
                    Text(action.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            Spacer()
            if let shortcut = action.shortcut {
                Text(shortcut)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? theme.surfaceHover : Color.clear)
        )
    }
}
