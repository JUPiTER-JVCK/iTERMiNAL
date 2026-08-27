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
                    Menu {
                        Button("New Terminal Tab") { store.newTab() }
                        if !settings.sshConnections.isEmpty {
                            Menu("Connect to") {
                                ForEach(settings.sshConnections) { connection in
                                    Button(connection.name) {
                                        store.newTab(kind: .remote(connection.id))
                                    }
                                }
                            }
                        }
                        Divider()
                        Button("Split Right") { store.splitFocusedPane(.horizontal, kind: .terminal) }
                        Button("Split Down") { store.splitFocusedPane(.vertical, kind: .terminal) }
                        Button("Split with Browser") { store.splitFocusedPane(.horizontal, kind: .browser) }
                        Button("Split with Files") { store.splitFocusedPane(.horizontal, kind: .files) }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()

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
