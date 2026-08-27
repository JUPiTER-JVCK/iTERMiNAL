import SwiftUI
import AppKit

struct MainWindowView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 285, max: 360)
        } detail: {
            DetailView()
        }
        .frame(minWidth: 900, minHeight: 560)
        .sheet(isPresented: $store.showCommandPalette) {
            CommandPaletteView()
                .environmentObject(store)
                .environmentObject(settings)
        }
    }
}

/// The detail column: a top strip with the panel toggles, the main surface,
/// an optional right panel beside it, and an optional terminal dock beneath
/// them both. The dock sits inside this column, so it spans the content and
/// the right panel but stops at the sidebar — matching the reference app.
struct DetailView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        VStack(spacing: 0) {
            // GeometryReader so the trailing panel can never take so much
            // width that the terminal is squeezed to a sliver — its width is
            // clamped against what's actually available.
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    if !store.rightPanelExpanded {
                        VStack(spacing: 0) {
                            DetailTopStrip()
                            mainSurface
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    if store.rightRegionOpen {
                        if !store.rightPanelExpanded {
                            PanelResizeHandle(
                                axis: .horizontal,
                                size: $settings.rightPanelWidth,
                                range: 280...1200,
                                inverted: true
                            )
                        }
                        RightPanelView()
                            .frame(width: store.rightPanelExpanded ? nil : panelWidth(in: proxy.size.width))
                            .frame(maxWidth: store.rightPanelExpanded ? .infinity : nil)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if store.bottomDockOpen {
                PanelResizeHandle(
                    axis: .vertical,
                    size: $settings.bottomDockHeight,
                    range: 120...620,
                    inverted: true
                )
                TerminalDockView()
                    .frame(height: settings.bottomDockHeight)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }

    /// Width for the trailing panel against the space actually available.
    private func panelWidth(in available: Double) -> Double {
        let minMain: Double = 360
        let minPanel: Double = 280
        if available >= minMain + minPanel {
            // Room for both: honour the stored width, capped so the main
            // surface keeps its minimum.
            return min(settings.rightPanelWidth, available - minMain)
        }
        // Too narrow for both minimums, so neither gets one. Split what
        // there is and leave the larger share to the main surface — it
        // holds the terminal, which is what the window is for.
        return max(0, available * 0.4)
    }

    @ViewBuilder
    private var mainSurface: some View {
        switch store.detailMode {
        case .automations:
            SectionPageView(
                title: "Automations",
                subtitle: "Run commands on a schedule, or when something in a session changes.",
                icon: "clock",
                emptyTitle: "No automations yet",
                emptyCaption: "Scheduled commands and triggers are coming soon."
            )
        case .skills:
            SectionPageView(
                title: "Skills",
                subtitle: "Reusable command snippets you can run from the composer or the palette.",
                icon: "book",
                emptyTitle: "No skills yet",
                emptyCaption: "Saved snippets are coming soon."
            )
        case .terminal:
            if let tab = store.selectedTab {
                TabContentView(tab: tab)
            } else {
                LandingView()
            }
            if settings.composerEnabled {
                ComposerBar()
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
            }
        }
    }
}

/// Title on the left, panel toggles on the right. Each toggle fills in when
/// its panel is open, the way the reference app marks an active panel.
private struct DetailTopStrip: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        HStack(spacing: 6) {
            Text(store.selectedTab?.displayName ?? "iTERMiNAL")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 12)

            StripToggle(
                icon: "rectangle.bottomthird.inset.filled",
                help: "Toggle terminal dock",
                isActive: store.bottomDockOpen
            ) {
                store.toggleBottomDock()
            }

            ForEach(SidePanel.allCases) { panel in
                StripToggle(
                    icon: panel.icon,
                    help: "Toggle \(panel.title) panel",
                    isActive: store.rightRegionOpen && store.openPanels.contains(panel)
                ) {
                    store.togglePanel(panel)
                }
            }

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
    }
}

private struct StripToggle: View {
    let icon: String
    let help: String
    let isActive: Bool
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(isActive ? theme.textPrimary : theme.textSecondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isActive ? theme.surface : (hovering ? theme.surface.opacity(0.5) : Color.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// A draggable hairline between two panels.
///
/// `DragGesture.translation` is measured from where the drag began, not from
/// the previous callback, so the size is recomputed from a baseline captured
/// at drag start rather than accumulated. `inverted` is for panels that grow
/// as the handle moves toward the window's origin — the trailing panel and
/// the bottom dock both do.
private struct PanelResizeHandle: View {
    enum Axis { case horizontal, vertical }

    let axis: Axis
    @Binding var size: Double
    let range: ClosedRange<Double>
    var inverted = false

    @State private var hovering = false
    @State private var baseline: Double?

    var body: some View {
        Rectangle()
            .fill(hovering ? Color.secondary.opacity(0.35) : Color.secondary.opacity(0.14))
            .frame(
                width: axis == .horizontal ? 1 : nil,
                height: axis == .vertical ? 1 : nil
            )
            .frame(
                maxWidth: axis == .vertical ? .infinity : nil,
                maxHeight: axis == .horizontal ? .infinity : nil
            )
            // A one-pixel line is impossible to grab, so widen the hit area
            // without widening what's drawn.
            .overlay {
                Rectangle()
                    .fill(Color.clear)
                    .frame(
                        width: axis == .horizontal ? 9 : nil,
                        height: axis == .vertical ? 9 : nil
                    )
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hovering = inside
                        // set() rather than push()/pop(): the view can vanish
                        // mid-hover when a panel closes, which would strand a
                        // resize cursor on the stack forever.
                        if inside {
                            (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
                        } else {
                            NSCursor.arrow.set()
                        }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                let start = baseline ?? size
                                if baseline == nil { baseline = start }
                                let moved = Double(
                                    axis == .horizontal
                                        ? value.translation.width
                                        : value.translation.height
                                )
                                size = (start + (inverted ? -moved : moved)).clamped(to: range)
                            }
                            .onEnded { _ in baseline = nil }
                    )
            }
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private struct TabContentView: View {
    @ObservedObject var tab: WorkspaceTab

    var body: some View {
        PaneTreeView(node: tab.root)
    }
}

/// The "no tab open" landing: centered glyph, a heading naming the current
/// workspace, recent commands pulled from the user's shell history, and
/// quick-start cards.
private struct LandingView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    @State private var recentCommands: [String] = []

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "apple.terminal")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(theme.textPrimary)

            Text(heading)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.center)

            Menu {
                ForEach(store.workspaces) { workspace in
                    Button(workspace.name) { store.newTab(in: workspace) }
                }
                Divider()
                Button("New Workspace") { store.newWorkspace() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                    Text(store.currentWorkspace?.name ?? "Workspace")
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(theme.surface))
                .overlay(Capsule().strokeBorder(theme.surfaceBorder))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            if !recentCommands.isEmpty {
                VStack(spacing: 4) {
                    ForEach(recentCommands, id: \.self) { command in
                        RecentCommandRow(command: command, theme: theme) {
                            run(command)
                        }
                    }
                }
                .frame(maxWidth: 520)
                .padding(.top, 6)
            }

            // An adaptive grid so the cards reflow from four across to two
            // when the dock and the right panel take the width, the way the
            // reference app does.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 12)],
                spacing: 12
            ) {
                SuggestionCard(icon: "terminal", tint: settings.accentColor, title: "Open a new terminal") {
                    store.newTab()
                }
                SuggestionCard(icon: "rectangle.split.2x1", tint: Color(hex: 0x3B82F6), title: "Start with split panes") {
                    store.newTab()
                    store.splitFocusedPane(.horizontal, kind: .terminal)
                }
                SuggestionCard(icon: "globe", tint: Color(hex: 0x8B5CF6), title: "Browse the web") {
                    store.togglePanel(.browser)
                }
                SuggestionCard(icon: "folder", tint: Color(hex: 0xF97316), title: "Explore your files") {
                    store.togglePanel(.files)
                }
            }
            .frame(maxWidth: 940)
            .padding(.horizontal, 24)
            .padding(.top, 6)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // Read once per appearance; the file rarely changes mid-session.
            if recentCommands.isEmpty {
                recentCommands = ShellHistory.recentCommands(limit: 3)
            }
        }
    }

    private var heading: String {
        if let name = store.currentWorkspace?.name, !name.isEmpty {
            return "What should we build in \(name)?"
        }
        return "What should we build?"
    }

    private func run(_ command: String) {
        let tab = store.newTab()
        tab.primarySession?.send(text: command + "\n")
    }
}

/// One recent command from shell history.
private struct RecentCommandRow: View {
    let command: String
    let theme: Theme
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textSecondary)
                Text(command)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(hovering ? theme.surfaceHover : theme.surface.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(theme.surfaceBorder)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Run in a new terminal")
    }
}

private struct SuggestionCard: View {
    let icon: String
    let tint: Color
    let title: String
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        Button(action: action) {
            // Icon pinned to the top, title to the bottom — the reference
            // app's card anatomy, and the inverse of what this used to do.
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .foregroundStyle(tint)
                Spacer(minLength: 8)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 95, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(hovering ? theme.surfaceHover : theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.surfaceBorder)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A sidebar section rendered as a real page: left-aligned title and
/// subtitle at the top, content below — the shape the reference app uses for
/// its own sections rather than a centred placeholder.
private struct SectionPageView: View {
    let title: String
    let subtitle: String
    let icon: String
    let emptyTitle: String
    let emptyCaption: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)
            .padding(.bottom, 22)

            VStack(spacing: 8) {
                Spacer()
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(theme.textSecondary)
                Text(emptyTitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                Text(emptyCaption)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The trailing region. It holds every open panel at once: a small tab strip
/// appears when more than one is in there, so opening Files no longer pushes
/// the browser out of the way.
struct RightPanelView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        VStack(spacing: 0) {
            header(theme: theme)
            Divider()
            content
        }
        .background(theme.background)
    }

    @ViewBuilder
    private var content: some View {
        switch store.visiblePanel {
        case .browser:
            BrowserPanelView(model: store.panelBrowserTabs)
        case .files:
            FilePaneView(model: store.panelFiles)
        case nil:
            PanelPicker()
        }
    }

    private func header(theme: Theme) -> some View {
        HStack(spacing: 6) {
            ForEach(store.orderedOpenPanels) { panel in
                PanelTabChip(
                    panel: panel,
                    isSelected: store.visiblePanel == panel,
                    onSelect: { store.frontPanel = panel },
                    onClose: { store.closePanel(panel) }
                )
            }

            Spacer(minLength: 0)

            Button {
                store.toggleRightPanelExpanded()
            } label: {
                Image(systemName: store.rightPanelExpanded
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(store.rightPanelExpanded ? "Collapse panel" : "Expand panel")

            Button {
                store.closeRightRegion()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close panel")
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
    }
}

/// One panel tab in the trailing region's strip.
private struct PanelTabChip: View {
    let panel: SidePanel
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        HStack(spacing: 6) {
            Image(systemName: panel.icon)
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
            Text(panel.title)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close \(panel.title)")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? theme.surface : (hovering ? theme.surface.opacity(0.5) : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }
}

/// Shown when the trailing region is open but empty — the reference app
/// offers the same choice rather than a blank panel.
private struct PanelPicker: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        VStack(spacing: 4) {
            Spacer()
            ForEach(SidePanel.allCases) { panel in
                PickerRow(
                    icon: panel.icon,
                    title: panel.title,
                    shortcut: panel == .browser ? "⌥⌘B" : "⌥⌘F",
                    theme: theme
                ) {
                    store.openPanel(panel)
                }
            }
            PickerRow(icon: "apple.terminal", title: "Terminal", shortcut: "⌘J", theme: theme) {
                store.toggleBottomDock()
            }
            Spacer()
        }
        .frame(maxWidth: 260)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PickerRow: View {
    let icon: String
    let title: String
    let shortcut: String
    let theme: Theme
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textPrimary)
                Spacer()
                Text(shortcut)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? theme.surface : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The bottom terminal dock: a tab strip of working directories over a live
/// shell. Separate from the tab's own panes, so it stays put while you move
/// between tabs.
struct TerminalDockView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(store.dockSessions) { session in
                            DockTabChip(
                                session: session,
                                isSelected: store.selectedDockSession?.id == session.id,
                                onSelect: { store.selectedDockSessionID = session.id },
                                onClose: { store.closeDockSession(session.id) }
                            )
                        }
                    }
                }

                Button {
                    store.newDockSession()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New dock terminal")

                Spacer(minLength: 0)

                Button {
                    store.closeBottomDock()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close terminal dock")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if let session = store.selectedDockSession {
                TerminalHostView(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer()
            }
        }
        .background(theme.background)
    }
}

/// One dock tab, labelled with the shell's working directory.
private struct DockTabChip: View {
    @ObservedObject var session: TerminalSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        HStack(spacing: 6) {
            Image(systemName: "apple.terminal")
                .font(.system(size: 10))
                .foregroundStyle(theme.textSecondary)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close this terminal")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(maxWidth: 190)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? theme.surface : (hovering ? theme.surface.opacity(0.5) : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }
}

/// Working directory, shortened the way a shell prompt would show it.
private extension DockTabChip {
    var label: String {
        let directory = session.abbreviatedDirectory
        if directory.isEmpty { return session.displayTitle }
        if directory == "/" || directory == "~" { return directory }
        return (directory as NSString).lastPathComponent
    }
}
