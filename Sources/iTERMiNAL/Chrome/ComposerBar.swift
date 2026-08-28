import SwiftUI

/// Rounded composer matching the reference: a context chip row and the input
/// stacked inside one card, with a "+" menu bottom-left and the send button
/// bottom-right. Plain text goes to the focused terminal; "@ai …" is reserved
/// for the assistant.
struct ComposerBar: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    @State private var text = ""
    @State private var assistantNotice = false
    @State private var showActions = false

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        VStack(spacing: 8) {
            if assistantNotice {
                Text("The AI assistant isn't configured yet — @ai commands will be supported in a future release.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                    .transition(Motion.bannerTransition)
            }

            VStack(alignment: .leading, spacing: 10) {
                ContextChipRow()

                TextField("Run anything", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...6)
                    .onSubmit(send)

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
            .elevated(cornerRadius: 22, radius: 18, y: 6)
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
        store.sendToFocusedTerminal(command + "\n")
        text = ""
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
        return (settings.resolvedShell().path as NSString).lastPathComponent
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
