import SwiftUI
import AppKit

// The composer's two places in the sidebar, under Workspaces.
//
// Neither is there from the start. Each appears once there is something to
// list — the composer's shell once it has run a command, the AI once a message
// has been sent — and goes again when that is gone, so a person who never uses
// the composer is never shown a section for it.

// MARK: - Composer

/// The composer's own shell, and the last few things sent from the composer.
///
/// Choosing the shell points the composer at it and opens its transcript;
/// choosing a command puts it back in the input, for review. Nothing here runs
/// anything: only Return in the input does.
struct SidebarComposerSection: View {
    let query: String
    /// Called after a choice, so a floating panel can put itself away.
    let onDone: () -> Void

    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @AppStorage("sidebarComposerExpanded") private var isExpanded = true

    /// How many recent commands the section lists when it is not searched.
    private static let listed = 3

    var body: some View {
        let commands = visibleCommands()
        let shellShown = shellMatches()
        if store.composerHasRun, let session = store.composerSession, shellShown || !commands.isEmpty {
            SidebarSectionHeader(title: "Composer", isExpanded: $isExpanded, showsDot: false) {
                Button {
                    store.resetComposerSession()
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("End the composer's shell")
            }

            if isExpanded {
                if shellShown {
                    SidebarComposerShellRow(
                        session: session,
                        isActive: settings.composerTarget == .ownShell
                    ) {
                        store.openComposer(on: .ownShell)
                        onDone()
                    }
                }
                ForEach(Array(commands.enumerated()), id: \.offset) { _, command in
                    SidebarCommandRow(command: command) {
                        store.insertIntoComposer(command)
                        onDone()
                    }
                }
            }
        }
    }

    /// The latest commands, newest first. A search looks through more of them
    /// than the section would otherwise list.
    private func visibleCommands() -> [String] {
        let recent: [String] = Array(store.composerHistory.suffix(10).reversed())
        if query.isEmpty { return Array(recent.prefix(Self.listed)) }
        return recent.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private func shellMatches() -> Bool {
        query.isEmpty || "composer shell".localizedCaseInsensitiveContains(query)
    }
}

/// The composer's shell: where it is, lit while it is where commands go.
private struct SidebarComposerShellRow: View {
    @ObservedObject var session: TerminalSession
    let isActive: Bool
    let onOpen: () -> Void

    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID
    @State private var hovering = false

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        ZStack(alignment: .trailing) {
            Button(action: onOpen) {
                HStack(spacing: 6) {
                    Image(systemName: "text.cursor")
                        .font(.system(size: 10))
                        .foregroundStyle(isActive ? theme.textPrimary : theme.textSecondary)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Composer shell")
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Text(session.abbreviatedDirectory)
                            .font(.system(size: 10))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                }
                .padding(.leading, 22)
                .padding(.trailing, 9)
                .frame(height: 38)
                .background(
                    // The accent wash a tab's row has when it is the one open.
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isActive
                              ? settings.accentColor.opacity(colorScheme == .dark ? 0.2 : 0.14)
                              : theme.surface.opacity(hovering ? 0.5 : 0))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if hovering {
                RowIconButton(icon: "xmark", help: "End this shell", theme: theme) {
                    store.resetComposerSession()
                }
                .padding(.trailing, 7)
                .transition(.opacity)
            }
        }
        .animation(Motion.hover, value: hovering)
        .animation(Motion.hover, value: isActive)
        .foregroundStyle(theme.textPrimary)
        .onHover { hovering = $0 }
        .padding(.horizontal, 8)
        .help("Show the composer's shell")
    }
}

/// A command sent from the composer, click to put it back in the input.
private struct SidebarCommandRow: View {
    let command: String
    let onInsert: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID
    @State private var hovering = false

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        Button(action: onInsert) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.left")
                    .font(.system(size: 9))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 14)
                Text(command)
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.leading, 22)
            .padding(.trailing, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(theme.surface.opacity(hovering ? 0.5 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Motion.hover, value: hovering)
        .foregroundStyle(theme.textPrimary)
        .onHover { hovering = $0 }
        .padding(.horizontal, 8)
        .help("Put in the composer's input — not run")
    }
}

// MARK: - AI

/// The AI conversations, one for each space that has one: the history of what
/// was said to the assistant, and where.
///
/// A conversation belongs to its space and is kept on this Mac (see
/// `ComposerChatModel`), so this lists every space's, not only the one in view,
/// newest first. Choosing one opens that space and the composer on its chat.
struct SidebarAISection: View {
    let query: String
    /// Called after a choice, so a floating panel can put itself away.
    let onDone: () -> Void

    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @AppStorage("sidebarAIExpanded") private var isExpanded = true

    /// A space and what has been said in it, for the list.
    private struct Entry: Identifiable {
        let workspace: Workspace
        let chat: ComposerChatModel
        let lastDate: Date
        var id: UUID { workspace.id }
    }

    var body: some View {
        // The store announces every message added or cleared anywhere
        // (`chatRevision`), so this list follows spaces other than the one in
        // view without watching each space's conversation.
        let entries = conversations()
        if !entries.isEmpty {
            SidebarSectionHeader(title: "AI", isExpanded: $isExpanded, showsDot: false) {
                Button {
                    store.openComposer(on: .assistant)
                    onDone()
                } label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help("Ask the AI in this space")
            }

            if isExpanded {
                ForEach(entries) { entry in
                    SidebarConversationRow(
                        workspace: entry.workspace,
                        chat: entry.chat,
                        isActive: store.currentWorkspace?.id == entry.workspace.id
                            && settings.composerTarget == .assistant,
                        onOpen: {
                            store.openConversation(in: entry.workspace)
                            onDone()
                        },
                        onDelete: { entry.chat.clear() }
                    )
                }
            }
        }
    }

    /// Spaces with something said in them, most recent first, narrowed by the
    /// sidebar's search to those whose name or any message matches.
    private func conversations() -> [Entry] {
        var found: [Entry] = []
        for workspace in store.workspaces {
            let chat = store.chat(for: workspace.id)
            guard let last = chat.lastSaid else { continue }
            if !query.isEmpty {
                let nameMatches = workspace.name.localizedCaseInsensitiveContains(query)
                let said = chat.messages.contains { $0.text.localizedCaseInsensitiveContains(query) }
                guard nameMatches || said else { continue }
            }
            found.append(Entry(workspace: workspace, chat: chat, lastDate: last.date))
        }
        return found.sorted { $0.lastDate > $1.lastDate }
    }
}

/// One conversation: the space it is in, the last thing said, and when. Watches
/// its own chat, so the line and the spinner follow a reply as it arrives.
private struct SidebarConversationRow: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var chat: ComposerChatModel
    let isActive: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID
    @State private var hovering = false

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        Button(action: onOpen) {
            HStack(spacing: 8) {
                ZStack {
                    if chat.isReplying {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10))
                            .foregroundStyle(isActive ? theme.textPrimary : theme.textSecondary)
                    }
                }
                .frame(width: 14)

                VStack(alignment: .leading, spacing: 1) {
                    Text(workspace.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(preview)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if let last = chat.lastSaid {
                    Text(RelativeTime.short(since: last.date))
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textSecondary)
                        .monospacedDigit()
                }
            }
            .padding(.leading, 22)
            .padding(.trailing, 9)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isActive
                          ? settings.accentColor.opacity(colorScheme == .dark ? 0.2 : 0.14)
                          : theme.surface.opacity(hovering ? 0.5 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Motion.hover, value: hovering)
        .animation(Motion.hover, value: isActive)
        .foregroundStyle(theme.textPrimary)
        .onHover { hovering = $0 }
        .padding(.horizontal, 8)
        .help("Open this conversation")
        .contextMenu {
            Button("Open", action: onOpen)
            Divider()
            Button("Delete Conversation", role: .destructive, action: onDelete)
        }
    }

    /// The first line of the last message, marked when it is yours.
    private var preview: String {
        guard let last = chat.lastSaid else { return "" }
        let firstLine = last.text
            .split(whereSeparator: \.isNewline)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return last.role == .user ? "You: " + firstLine : firstLine
    }
}
