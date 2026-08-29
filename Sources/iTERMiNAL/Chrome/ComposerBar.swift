import SwiftUI
import AppKit

/// A floating, self-contained terminal.
///
/// It owns its own shell rather than typing into whichever pane happens to
/// have focus, so nothing entered here can land in the window behind it — the
/// transcript below the input is that shell, not a copy of anything else.
///
/// It can be dragged anywhere in the content area and collapsed to a pill;
/// both survive relaunch.
struct ComposerBar: View {
    /// The surface this card floats over. Its offset is clamped against these
    /// bounds, so shrinking the window can never strand the card off-screen.
    let bounds: CGSize

    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    @State private var text = ""
    @State private var assistantNotice = false
    @State private var showActions = false
    /// Live drag delta, folded into the persisted offset when the drag ends.
    @State private var dragDelta: CGSize = .zero
    /// Where arrow-key recall currently sits in the history, and the
    /// half-typed line it interrupted.
    @State private var historyIndex: Int?
    @State private var draft = ""
    /// The card's rendered size, measured so the drag clamp can keep the whole
    /// card on screen rather than guessing from the container alone.
    @State private var cardSize: CGSize = .zero
    /// Darkens the grip while a drag is in flight, so it is obvious the card
    /// has been picked up.
    @State private var dragging = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        Group {
            if settings.composerCollapsed {
                collapsedPill
            } else {
                expandedCard
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ComposerSizeKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(ComposerSizeKey.self) { size in
            guard size != cardSize else { return }
            cardSize = size
            clampToBounds()
        }
        .offset(
            x: settings.composerOffsetX + dragDelta.width,
            y: settings.composerOffsetY + dragDelta.height
        )
        .animation(Motion.panel, value: settings.composerCollapsed)
        .onChange(of: bounds) { _, _ in clampToBounds() }
        .onChange(of: store.composerFocusRequest) { _, _ in inputFocused = true }
    }

    /// How far the card may travel from home while staying fully on the
    /// surface, with a margin so it never sits flush against an edge.
    ///
    /// This used to guess from the container alone, which let a wide card hang
    /// off the side — the limits have to account for how big the card actually
    /// is. Home is horizontally centred and bottom-aligned, so the horizontal
    /// room is the slack either side and the vertical room is upward only.
    private var offsetLimits: (x: ClosedRange<Double>, y: ClosedRange<Double>) {
        let margin: Double = 12
        let horizontal = max(0, (bounds.width - cardSize.width) / 2 - margin)
        let vertical = max(0, bounds.height - cardSize.height - margin * 2)
        return (-horizontal...horizontal, -vertical...0)
    }

    /// The card's fill, honouring the opacity and vibrancy settings.
    ///
    /// Vibrancy is expressed by letting the fill go translucent so the terminal
    /// shows through, rather than by adding an NSVisualEffectView: the card
    /// floats over app content, not over the desktop, so a material would
    /// sample the wrong thing.
    private func cardFill(_ theme: Theme) -> Color {
        let base = theme.floatingSurface
        let opacity = settings.composerVibrancy
            ? min(settings.composerOpacity, 0.85)
            : settings.composerOpacity
        return base.opacity(opacity)
    }

    /// Re-anchors the card when the window shrinks under it. Writes only on a
    /// real change — this runs on every frame of a live window resize.
    private func clampToBounds() {
        let limits = offsetLimits
        let x = settings.composerOffsetX.clamped(to: limits.x)
        let y = settings.composerOffsetY.clamped(to: limits.y)
        if x != settings.composerOffsetX { settings.composerOffsetX = x }
        if y != settings.composerOffsetY { settings.composerOffsetY = y }
    }

    // MARK: Collapsed

    private var collapsedPill: some View {
        let theme = Theme.current(for: colorScheme)
        return Button {
            settings.composerCollapsed = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                Text("Run anything")
                    .font(.system(size: 12))
                if store.composerHasRun {
                    // A quiet reminder that a shell is still alive down here.
                    Circle()
                        .fill(settings.accentColor)
                        .frame(width: 5, height: 5)
                }
            }
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .elevated(cornerRadius: 16, radius: 14, y: 4, fill: cardFill(theme))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show the composer")
    }

    // MARK: Expanded

    private var expandedCard: some View {
        let theme = Theme.current(for: colorScheme)
        return VStack(spacing: 8) {
            if assistantNotice {
                Text("The AI assistant isn't configured yet — @ai commands will be supported in a future release.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .transition(Motion.bannerTransition)
            }

            VStack(alignment: .leading, spacing: 10) {
                gripBar(theme: theme)
                ContextChipRow()

                if store.composerHasRun, let session = store.composerSession {
                    // The composer's own shell. Identity is tied to the
                    // session so a reset swaps the view rather than reusing
                    // a container still hosting the old terminal.
                    TerminalHostView(session: session)
                        .id(session.id)
                        .frame(height: settings.composerTranscriptHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(theme.surfaceBorder)
                        )

                    TranscriptResizeHandle(
                        height: $settings.composerTranscriptHeight,
                        theme: theme
                    )
                }

                TextField("Run anything", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .onSubmit(send)
                    .onKeyPress(.upArrow) { recallEarlier() }
                    .onKeyPress(.downArrow) { recallLater() }

                HStack(spacing: 8) {
                    // A popover rather than a Menu: the reference app groups
                    // these under headings and gives each row a line of
                    // explanation, neither of which a Menu can render.
                    Button {
                        showActions = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Add a terminal, split, or panel")
                    .popover(isPresented: $showActions, arrowEdge: .top) {
                        ComposerActionsPopover(isPresented: $showActions)
                            .environmentObject(store)
                            .environmentObject(settings)
                    }

                    Spacer()

                    SessionChip()

                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                            .frame(width: 28, height: 28)
                            .background(
                                Circle().fill(
                                    trimmedText.isEmpty
                                        ? Color.secondary.opacity(0.35)
                                        : (colorScheme == .dark ? Color.white : Color.black)
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(trimmedText.isEmpty)
                }
            }
            .padding(14)
            // A distinctly lighter surface and a deeper shadow, so this reads
            // as floating above the terminal rather than painted onto it.
            .elevated(cornerRadius: 22, radius: 22, y: 8, fill: cardFill(theme))
        }
    }

    /// The card's drag handle: a grip in the middle, window controls on the
    /// right.
    ///
    /// Deliberately its own row rather than sharing one with the context
    /// chips. Those chips are menus, and with them in the handle the only
    /// actually grabbable part of it was the gaps between them.
    private func gripBar(theme: Theme) -> some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)

            Capsule()
                .fill(theme.textSecondary.opacity(dragging ? 0.5 : 0.28))
                .frame(width: 40, height: 4)

            Spacer(minLength: 0)
        }
        // Taller than it looks: the capsule is 4pt, but the grabbable strip
        // around it needs to be big enough to hit without aiming.
        .frame(height: 24)
        .overlay(alignment: .trailing) { headerControls(theme: theme) }
        .contentShape(Rectangle())
        .onHover { NSCursor.openHand.set(); if !$0 { NSCursor.arrow.set() } }
        .gesture(
            // The default 10pt threshold swallowed short drags, which is what
            // made the card feel stuck — it only moved once you had committed
            // to a big gesture.
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    // Clamp while dragging, not only on release. Assigning the
                    // raw translation let the card follow the pointer clean off
                    // the surface and then snap back when let go, which is not
                    // what "stays inside" should feel like.
                    let limits = offsetLimits
                    let x = (settings.composerOffsetX + value.translation.width)
                        .clamped(to: limits.x)
                    let y = (settings.composerOffsetY + value.translation.height)
                        .clamped(to: limits.y)
                    dragDelta = CGSize(
                        width: x - settings.composerOffsetX,
                        height: y - settings.composerOffsetY
                    )
                    if !dragging { dragging = true }
                }
                .onEnded { value in
                    let limits = offsetLimits
                    settings.composerOffsetX = (settings.composerOffsetX + value.translation.width)
                        .clamped(to: limits.x)
                    settings.composerOffsetY = (settings.composerOffsetY + value.translation.height)
                        .clamped(to: limits.y)
                    dragDelta = .zero
                    dragging = false
                }
        )
        // Double-click the handle to put it back where it started.
        .onTapGesture(count: 2) {
            withAnimation(Motion.panel) {
                settings.composerOffsetX = 0
                settings.composerOffsetY = 0
            }
        }
        .help("Drag to move the composer · double-click to reset")
    }

    private func headerControls(theme: Theme) -> some View {
        HStack(spacing: 6) {
            if store.composerHasRun {
                Button {
                    store.resetComposerSession()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Restart this shell and clear the transcript")
            }

            Button {
                settings.composerCollapsed = true
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Minimise the composer")
        }
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send() {
        let command = trimmedText
        guard !command.isEmpty else { return }
        if command.lowercased().hasPrefix("@ai") {
            withAnimation(Motion.banner) {
                assistantNotice = !NullAssistantService.shared.isConfigured
            }
            text = ""
            return
        }
        assistantNotice = false
        // Its own shell — never the pane behind it.
        withAnimation(Motion.panel) {
            store.sendToComposer(command + "\n")
        }
        text = ""
        historyIndex = nil
        draft = ""
    }

    // MARK: Arrow-key recall

    /// Walks back through commands this composer has run, the way a shell
    /// does. Multi-line input is left alone: there the arrows have to move
    /// the caret, and stealing them would make the field unusable.
    private func recallEarlier() -> KeyPress.Result {
        let history = store.composerHistory
        guard !text.contains("\n"), !history.isEmpty else { return .ignored }
        if let historyIndex {
            guard historyIndex > 0 else { return .handled }
            self.historyIndex = historyIndex - 1
            text = history[historyIndex - 1]
        } else {
            // Remember the half-typed line so walking back down restores it.
            draft = text
            historyIndex = history.count - 1
            text = history[history.count - 1]
        }
        return .handled
    }

    private func recallLater() -> KeyPress.Result {
        let history = store.composerHistory
        guard !text.contains("\n"), let historyIndex else { return .ignored }
        if historyIndex + 1 < history.count {
            self.historyIndex = historyIndex + 1
            text = history[historyIndex + 1]
        } else {
            self.historyIndex = nil
            text = draft
        }
        return .handled
    }
}

/// Drag to change how much of the composer's shell is visible; double-click
/// for the default height.
private struct TranscriptResizeHandle: View {
    @Binding var height: Double
    let theme: Theme

    /// Height when the drag began. `DragGesture` reports translation from the
    /// start of the gesture, not since the last event, so it has to be added
    /// to a fixed starting height rather than to the live one.
    @State private var startHeight: Double?
    @State private var hovering = false

    var body: some View {
        Capsule()
            .fill(theme.textSecondary.opacity(hovering ? 0.45 : 0.2))
            .frame(width: 44, height: 4)
            .frame(maxWidth: .infinity)
            .frame(height: 12)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let start = startHeight ?? height
                        if startHeight == nil { startHeight = start }
                        height = (start + value.translation.height).clamped(to: 100...560)
                    }
                    .onEnded { _ in startHeight = nil }
            )
            .onTapGesture(count: 2) {
                withAnimation(Motion.panel) { height = 200 }
            }
            .help("Drag to resize the transcript · double-click to reset")
    }
}

/// `workspace · Local|host · branch`, sitting above the input the way the
/// reference app shows a project, its environment, and its git branch.
private struct ContextChipRow: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        HStack(spacing: 6) {
            Menu {
                ForEach(store.workspaces) { workspace in
                    Button(workspace.name) { store.newTab(in: workspace) }
                }
                Divider()
                Button("New Workspace") { store.newWorkspace() }
            } label: {
                ComposerChip(
                    icon: "folder",
                    text: store.currentWorkspace?.name ?? "Workspace",
                    theme: theme
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            if let session = store.focusedSession {
                LocationChip(session: session, theme: theme)
            } else {
                ComposerChip(icon: "desktopcomputer", text: "Local", theme: theme)
            }

            Spacer(minLength: 0)
        }
    }
}

private struct LocationChip: View {
    @ObservedObject var session: TerminalSession
    let theme: Theme

    var body: some View {
        HStack(spacing: 6) {
            ComposerChip(
                icon: session.isRemote ? "network" : "desktopcomputer",
                text: session.isRemote ? (session.connection?.name ?? "Remote") : "Local",
                theme: theme
            )
            if let branch = session.gitBranch {
                ComposerChip(icon: "arrow.triangle.branch", text: branch, theme: theme)
            }
        }
    }
}

private struct ComposerChip: View {
    let icon: String
    let text: String
    let theme: Theme

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 11))
                .lineLimit(1)
        }
        .foregroundStyle(theme.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(theme.surfaceHover.opacity(0.6)))
    }
}

/// Where input is going — the shell name, or the host for a remote session.
private struct SessionChip: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        Text(label)
            .font(.system(size: 11))
            .foregroundStyle(theme.textSecondary)
            .lineLimit(1)
            .help("Input goes to this session")
    }

    private var label: String {
        if let session = store.focusedSession {
            if session.isRemote {
                return session.connection?.name ?? "remote"
            }
        }
        // The composer's own override, not the global setting: this chip sits
        // on the composer and its tooltip says input goes to this session, so
        // naming the app-wide default while the composer runs bash would be
        // pointing at the wrong shell.
        let override = settings.composerShell
        let shell = settings.resolvedShell(override: override.isEmpty ? nil : override)
        return (shell.path as NSString).lastPathComponent
    }
}

// MARK: - Actions popover

/// The composer's "+" surface: grouped rows with a title, a line of
/// explanation and the shortcut that does the same thing.
///
/// A `Menu` can render none of that — no section headings, no secondary text —
/// which is why this is a popover over hand-built rows.
private struct ComposerActionsPopover: View {
    @Binding var isPresented: Bool

    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        VStack(alignment: .leading, spacing: 2) {
            sectionHeader("This composer", theme: theme)

            ComposerShellPicker(theme: theme)

            sectionHeader("Terminal", theme: theme)

            ComposerActionRow(
                icon: "plus.square",
                title: "New terminal",
                detail: "A shell in the current workspace",
                shortcut: "⌘T"
            ) {
                store.newTab()
            }

            ComposerActionRow(
                icon: "rectangle.split.2x1",
                title: "Split right",
                detail: "Another shell beside this one",
                shortcut: "⌘D"
            ) {
                store.splitFocusedPane(.horizontal, kind: .terminal)
            }

            ComposerActionRow(
                icon: "rectangle.split.1x2",
                title: "Split down",
                detail: "Another shell below this one",
                shortcut: "⇧⌘D"
            ) {
                store.splitFocusedPane(.vertical, kind: .terminal)
            }

            ComposerActionRow(
                icon: "rectangle.bottomthird.inset.filled",
                title: "Terminal dock",
                detail: "A scratch shell along the bottom",
                shortcut: "⌘J"
            ) {
                store.toggleBottomDock()
            }

            sectionHeader("Panels", theme: theme)

            ComposerActionRow(
                icon: "globe",
                title: "Browser",
                detail: "Open a web view beside the terminal",
                shortcut: "⌥⌘B"
            ) {
                store.openPanel(.browser)
            }

            ComposerActionRow(
                icon: "folder",
                title: "Files",
                detail: "Browse this Mac or a saved host",
                shortcut: "⌥⌘F"
            ) {
                store.openPanel(.files)
            }

            sectionHeader("Connect", theme: theme)

            if settings.sshConnections.isEmpty {
                // An empty state that says where to fix it beats a disabled
                // row that says nothing.
                Text("No saved hosts. Add one in Settings → Connections.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            } else {
                ForEach(settings.sshConnections) { connection in
                    ComposerActionRow(
                        icon: "network",
                        title: connection.name.isEmpty ? connection.destination : connection.name,
                        detail: connection.subtitle,
                        shortcut: nil
                    ) {
                        store.newTab(kind: .remote(connection.id))
                    }
                }
            }
        }
        .padding(6)
        .frame(width: 330)
        .environment(\.composerActionDismiss) { isPresented = false }
    }

    private func sectionHeader(_ title: String, theme: Theme) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

/// Lets a row close the popover without every row taking a binding.
private struct ComposerActionDismissKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

private extension EnvironmentValues {
    var composerActionDismiss: () -> Void {
        get { self[ComposerActionDismissKey.self] }
        set { self[ComposerActionDismissKey.self] = newValue }
    }
}

/// Icon, title, a muted line of explanation, and the shortcut for the same
/// action — the reference app's row anatomy.
private struct ComposerActionRow: View {
    let icon: String
    let title: String
    let detail: String
    let shortcut: String?
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.composerActionDismiss) private var dismiss

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        Button {
            action()
            dismiss()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textPrimary)
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? theme.surfaceHover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Carries the composer card's rendered size up to the view that clamps its
/// drag, so the clamp knows how much card it is keeping on screen.
private struct ComposerSizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// Chooses which shell the composer's own session runs.
///
/// Scoped to the composer on purpose: this is where you try a one-off command,
/// and wanting it in bash shouldn't change what every new tab opens as. Only
/// shells that exist on this Mac are offered — listing one that isn't
/// installed would just produce a session that fails to launch.
private struct ComposerShellPicker: View {
    let theme: Theme

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: WorkspaceStore


    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text("Shell")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                Text("Applies to the composer only")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textSecondary)
            }

            Spacer(minLength: 8)

            // A real label, hidden visually: the "Shell" text beside this is
            // decoration as far as assistive technology is concerned, so an
            // empty label would leave the control unnamed.
            Picker("Shell", selection: shellBinding) {
                Text("Default").tag("")
                ForEach(ComposerShells.available, id: \.path) { shell in
                    Text(shell.name).tag(shell.path)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Changing the shell restarts the composer's session — the running one
    /// is still the old shell, and leaving it would make the picker a lie.
    private var shellBinding: Binding<String> {
        Binding(
            get: { settings.composerShell },
            set: { newValue in
                guard newValue != settings.composerShell else { return }
                settings.composerShell = newValue
                store.resetComposerSession()
            }
        )
    }
}

/// The shells the composer offers, resolved once.
///
/// Shared by the composer's own popover and the Composer settings pane so the
/// two can never disagree about what is installed.
enum ComposerShells {
    /// Checked once: the set of installed shells does not change while the
    /// app is running.
    ///
    /// Resolved through the user's own PATH rather than a list of guessed
    /// locations. Hardcoding the two Homebrew prefixes missed MacPorts, Nix,
    /// and anything else on PATH, so a shell could be installed and still not
    /// be offered.
    static let available: [(path: String, name: String)] = {
        let names = ["zsh", "bash", "sh", "fish"]
        let searchPath = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        // /bin last so a user's preferred build shadows the system copy, and
        // present even when PATH is empty (a GUI app can inherit very little).
        let directories = searchPath + ["/bin", "/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"]

        var seen = Set<String>()
        var found: [(path: String, name: String)] = []
        for name in names {
            for directory in directories {
                let path = (directory as NSString).appendingPathComponent(name)
                guard FileManager.default.isExecutableFile(atPath: path) else { continue }
                // Resolve symlinks so /usr/local/bin/fish and its real target
                // are not offered as two separate choices.
                let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                guard seen.insert(resolved).inserted else { continue }
                found.append((path, name))
                break
            }
        }
        return found
    }()
}
