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
        // One reader over the whole column: the trailing handle needs the
        // width and the dock handle needs the height. A second reader nested
        // just for the dock would report zero before first layout.
        GeometryReader { outer in
            detailColumn(in: outer.size)
        }
    }

    private func detailColumn(in size: CGSize) -> some View {
        let theme = Theme.current(for: colorScheme)
        return VStack(spacing: 0) {
            // The strip spans the whole detail column rather than living
            // inside the content VStack: nested there, it narrowed whenever a
            // panel opened and the right-aligned toggles slid with it.
            DetailTopStrip()
            FadedDivider()

            // The trailing panel can never take so much width that the
            // terminal is squeezed to a sliver — clamped against what is
            // actually available.
            HStack(spacing: 0) {
                if !store.rightPanelExpanded {
                    mainSurface
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if store.rightRegionOpen {
                    if !store.rightPanelExpanded {
                        PanelResizeHandle(
                            axis: .horizontal,
                            size: $settings.rightPanelWidth,
                            range: 280...1200,
                            inverted: true,
                            resetTo: 420,
                            available: size.width
                        )
                    }
                    RightPanelView()
                        .frame(width: store.rightPanelExpanded ? nil : panelWidth(in: size.width))
                        .frame(maxWidth: store.rightPanelExpanded ? .infinity : nil)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if store.bottomDockOpen {
                PanelResizeHandle(
                    axis: .vertical,
                    size: $settings.bottomDockHeight,
                    range: 120...620,
                    inverted: true,
                    resetTo: 260,
                    available: size.height
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
        case .tasks:
            TaskManagerView()
        case .skills:
            SectionPageView(
                title: "Skills",
                subtitle: "Reusable command snippets you can run from the composer or the palette.",
                icon: "book",
                emptyTitle: "No skills yet",
                emptyCaption: "Saved snippets are coming soon."
            )
        case .terminal:
            terminalSurface
        }
    }

    /// The terminal — or the landing screen — with the composer floating over
    /// it.
    ///
    /// An overlay rather than a sibling in the stack. As a sibling the
    /// composer reserved layout height even after it was given an offset, so
    /// dragging the card upward left an empty band along the bottom of the
    /// window: the opposite of floating. The reader hands the card the size of
    /// the surface it has to stay inside, which is what keeps a drag from
    /// parking it somewhere unreachable.
    private var terminalSurface: some View {
        Group {
            if let tab = store.selectedTab {
                TabContentView(tab: tab)
            } else {
                LandingView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if settings.composerEnabled {
                GeometryReader { proxy in
                    ComposerBar(bounds: proxy.size)
                        .frame(maxWidth: settings.composerWidth)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
                }
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
    /// Default the handle returns to on a double-click.
    var resetTo: Double
    /// Total extent of the container, used to work out the snap points.
    var available: Double = 0

    @State private var hovering = false
    @State private var baseline: Double?

    /// A third, half and two thirds of the container — the proportions worth
    /// landing on exactly. Within 12pt the drag settles onto one.
    private func snapped(_ value: Double) -> Double {
        guard available > 0 else { return value }
        let targets = [available / 3, available / 2, available * 2 / 3]
        for target in targets where abs(value - target) < 12 {
            return target
        }
        return value
    }

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
                                let raw = start + (inverted ? -moved : moved)
                                size = snapped(raw).clamped(to: range)
                            }
                            .onEnded { _ in baseline = nil }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(Motion.panel) { size = resetTo }
                    }
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
            .elevated(
                cornerRadius: 12,
                radius: hovering ? 14 : 8,
                y: hovering ? 5 : 2,
                fill: hovering ? theme.surfaceHover : theme.surface
            )
            .animation(Motion.disclosure, value: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Every shell the app owns, wherever it lives, with what it is doing and
/// the two things worth doing to it: go to it, or stop it.
private struct TaskManagerView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.colorScheme) private var colorScheme
    /// Uptime has to be recomputed to tick; nothing else here needs a timer.
    @State private var now = Date()
    @State private var filter = ""

    /// Static so it isn't rebuilt — and restarted — every time this struct is
    /// initialised, which SwiftUI does on every render.
    private static let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        let all = store.allTasks()
        let tasks = matching(all)

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Tasks")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)

                    Spacer(minLength: 12)

                    // Only worth the width once there is enough here to lose
                    // something in.
                    if all.count > 3 {
                        TaskFilterField(text: $filter, theme: theme)
                    }
                }
                Text(summary(for: all))
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
            }
            .padding(.horizontal, 28)
            .padding(.top, 26)
            .padding(.bottom, 18)

            if tasks.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: all.isEmpty ? "list.bullet.rectangle" : "magnifyingglass")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(theme.textSecondary)
                    Text(all.isEmpty ? "Nothing running" : "No matches")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                    Text(all.isEmpty
                         ? "Shells you open appear here while they live."
                         : "No task matches \u{201C}\(filter)\u{201D}.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(tasks) { task in
                            TaskRow(task: task, now: now)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onReceive(Self.clock) { now = $0 }
    }

    /// Filters on the things visible in a row — title, where it lives, and
    /// its directory — so what you type matches what you can see.
    private func matching(_ tasks: [RunningTask]) -> [RunningTask] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return tasks }
        return tasks.filter { task in
            let haystack = [
                task.session.displayTitle,
                task.origin.label,
                task.session.abbreviatedDirectory
            ].joined(separator: " ").lowercased()
            return haystack.contains(needle)
        }
    }

    private func summary(for tasks: [RunningTask]) -> String {
        let live = tasks.filter(\.session.isRunning).count
        let stopped = tasks.count - live
        if tasks.isEmpty { return "Shells this app is running." }
        var parts = ["\(live) running"]
        if stopped > 0 { parts.append("\(stopped) stopped") }
        return parts.joined(separator: " · ")
    }
}

/// Search box for the task list. Its own view so the list isn't rebuilt on
/// every keystroke of something that only narrows it.
private struct TaskFilterField: View {
    @Binding var text: String
    let theme: Theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)

            TextField("Filter", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 150)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Clear the filter")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.surfaceBorder)
        )
    }
}

private struct TaskRow: View {
    let task: RunningTask
    let now: Date

    @ObservedObject private var session: TerminalSession
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    init(task: RunningTask, now: Date) {
        self.task = task
        self.now = now
        _session = ObservedObject(wrappedValue: task.session)
    }

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        HStack(spacing: 12) {
            Circle()
                .fill(session.isRunning ? Color(p3: 0x3FB68B) : theme.textSecondary.opacity(0.4))
                .frame(width: 7, height: 7)

            Image(systemName: session.isRemote ? "network" : "terminal")
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Text("\(task.origin.label) · \(session.abbreviatedDirectory)")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Text(status)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(theme.textSecondary)

            // Faded rather than absent when not hovering: removing them
            // entirely takes them out of the keyboard and VoiceOver order,
            // and makes the row's layout jump under the pointer.
            HStack(spacing: 10) {
                Button("Go to") { store.reveal(task) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .help("Show this session")

                if session.isRunning {
                    Button("Stop") { store.stopTask(task) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(p3: 0xE0605C))
                        .help("End this session and move it to Recents")
                }
            }
            .opacity(hovering ? 1 : 0.35)
            .animation(Motion.disclosure, value: hovering)
        }
        .padding(.horizontal, 12)
        .frame(height: 46)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(hovering ? theme.surface : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { store.reveal(task) }
        .contextMenu {
            Button("Go to") { store.reveal(task) }
            Button("Copy Working Directory") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.currentDirectory, forType: .string)
            }
            if session.isRunning {
                Divider()
                Button("Stop") { store.stopTask(task) }
            }
        }
    }

    /// Uptime while alive; why it ended once it isn't.
    private var status: String {
        if !session.isRunning {
            if let code = session.lastExitCode { return "exited \(code)" }
            return session.statusNote ?? "stopped"
        }
        guard let startedAt = session.startedAt else { return "starting" }
        let seconds = Int(now.timeIntervalSince(startedAt))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
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
            FadedDivider()
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
                // Identity must follow the session. Without it SwiftUI sees
                // the same view in the same slot when you switch dock tabs,
                // calls updateNSView, and the container keeps hosting the
                // previous terminal — the visible shell never changes.
                TerminalHostView(session: session)
                    .id(session.id)
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
