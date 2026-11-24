import SwiftUI
import AppKit

// Composer + actions popover helpers.

// MARK: - Actions popover

/// The composer's "+" surface: what is worth reaching for from the input, in
/// grouped rows with a title, a line of explanation and, where there is one,
/// the shortcut that does the same thing.
///
/// What it offers follows what the composer is doing. It used to be a fixed
/// list that included opening terminals, splits, panels and saved hosts — all
/// of which have a home elsewhere (the rail, the sidebar, the dock's own "+")
/// and none of which has anything to do with the line being typed. Now it is
/// about the line and the transcript: put a recent command or a skill back in
/// the input, copy or clear what is on screen, ask the assistant about it.
///
/// A `Menu` can render none of that — no section headings, no secondary text —
/// which is why this is a popover over hand-built rows.
struct ComposerActionsPopover: View {
    @Binding var isPresented: Bool
    /// What is typed in the composer, and what to do to explain it. The row is
    /// off while nothing is typed.
    var typedCommand: String = ""
    var explainTyped: () -> Void = {}

    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID
    @AppStorage(ComposerStorage.transcriptRetracted) private var transcriptRetracted = false

    /// How many recent commands and skills to offer. Enough to be a shortcut;
    /// a longer list is what the input's own history search is for.
    private static let recentLimit = 3
    private static let skillLimit = 4

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        VStack(alignment: .leading, spacing: 2) {
            if hasTranscript {
                transcriptRows(theme: theme)
            }

            if !chatting, !recentCommands.isEmpty {
                sectionHeader("Recent", theme: theme)
                ForEach(Array(recentCommands.enumerated()), id: \.offset) { _, command in
                    ComposerActionRow(
                        icon: "clock.arrow.circlepath",
                        title: command,
                        detail: "Put it in the input — not run",
                        shortcut: nil
                    ) {
                        store.insertIntoComposer(command)
                    }
                }
            }

            sectionHeader("History", theme: theme)
            ComposerActionRow(
                icon: "clock.arrow.circlepath",
                title: "Session history",
                detail: "Shells, terminals and AI chats, once they have ended",
                shortcut: nil
            ) {
                store.openComposerHistory(afterPresentation: true)
            }

            if !usableSkills.isEmpty {
                sectionHeader("Skills", theme: theme)
                ForEach(usableSkills) { offer in
                    ComposerActionRow(
                        icon: "book",
                        title: offer.skill.displayName,
                        detail: offer.skill.summary,
                        shortcut: nil
                    ) {
                        store.insertIntoComposer(offer.text)
                    }
                }
            }

            if !chatting {
                assistantRows(theme: theme)

                sectionHeader("Shell", theme: theme)
                ComposerShellPicker(theme: theme)
            }
        }
        .padding(6)
        .frame(width: 330)
        .environment(\.composerActionDismiss) { isPresented = false }
    }

    // MARK: What there is

    /// Whether what is typed is a message to the AI, not a command.
    private var chatting: Bool {
        if case .assistant = store.composerDestination { return true }
        return false
    }

    /// Whether the card has a transcript to act on: the chat, or the
    /// composer's own shell while the composer is pointed at it.
    private var hasTranscript: Bool {
        chatting || store.composerShellTranscriptVisible
    }

    /// The latest commands, newest first.
    private var recentCommands: [String] {
        Array(store.composerHistory.suffix(Self.recentLimit).reversed())
    }

    /// A skill with text that can be put in an input, and that text.
    private struct SkillOffer: Identifiable {
        let skill: Skill
        let text: String
        var id: UUID { skill.id }
    }

    /// The first few skills that have text to put in an input.
    private var usableSkills: [SkillOffer] {
        let offers = settings.skills.compactMap { skill -> SkillOffer? in
            guard let text = skill.inputText else { return nil }
            return SkillOffer(skill: skill, text: text)
        }
        return Array(offers.prefix(Self.skillLimit))
    }

    // MARK: Rows

    /// Fold, copy and clear for whatever the transcript is — the shell's
    /// output, or the AI conversation.
    @ViewBuilder
    private func transcriptRows(theme: Theme) -> some View {
        sectionHeader("Transcript", theme: theme)

        ComposerActionRow(
            icon: transcriptRetracted ? "chevron.up" : "chevron.down",
            title: transcriptRetracted ? "Show transcript" : "Retract transcript",
            detail: transcriptRetracted ? "Bring the output back above the input" : "Keep the input, put the output away",
            shortcut: nil
        ) {
            withAnimation(Motion.panel) { transcriptRetracted.toggle() }
        }

        if chatting {
            ComposerActionRow(
                icon: "doc.on.doc",
                title: "Copy last reply",
                detail: lastReply == nil ? "No reply yet" : "The assistant's latest answer",
                shortcut: nil
            ) {
                if let lastReply { copy(lastReply) }
            }
            .disabled(lastReply == nil)

            ComposerActionRow(
                icon: "trash",
                title: "Clear conversation",
                detail: "Delete this space's chat from this Mac",
                shortcut: nil
            ) {
                store.composerChat.clear()
            }
            .disabled(store.composerChat.messages.isEmpty)
        } else {
            ComposerActionRow(
                icon: "doc.on.doc",
                title: "Copy output",
                detail: "Everything this shell has printed",
                shortcut: nil
            ) {
                if let session = store.composerSession {
                    copy(session.captureScrollback(maxBytes: 128 * 1024))
                }
            }

            ComposerActionRow(
                icon: "arrow.counterclockwise",
                title: "Restart shell",
                detail: "End it and clear the transcript",
                shortcut: nil
            ) {
                store.resetComposerSession()
            }
        }
    }

    /// Explain and fix, which read what a terminal last printed — so they are
    /// for the shell, and left out while the composer is a chat.
    @ViewBuilder
    private func assistantRows(theme: Theme) -> some View {
        sectionHeader("Assistant", theme: theme)

        ComposerActionRow(
            icon: "questionmark.bubble",
            title: "Explain last output",
            detail: "Ask what this terminal printed",
            shortcut: "⌥⌘E"
        ) {
            store.requestComposerHelp(.explain)
        }

        ComposerActionRow(
            icon: "text.magnifyingglass",
            title: "Explain what I typed",
            detail: typedCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Type a command first — it is not run"
                : "Ask what this command would do — it is not run",
            shortcut: nil
        ) {
            explainTyped()
        }
        .disabled(typedCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        ComposerActionRow(
            icon: "wrench.and.screwdriver",
            title: "Suggest a fix",
            detail: "A command to review — it won't run itself",
            shortcut: "⌥⌘X"
        ) {
            store.requestComposerHelp(.fix)
        }
    }

    /// The assistant's latest answer in this space's conversation.
    private var lastReply: String? {
        store.composerChat.messages.last(where: { $0.role == .assistant })?.text
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
struct ComposerActionDismissKey: EnvironmentKey {
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
struct ComposerActionRow: View {
    let icon: String
    let title: String
    let detail: String
    let shortcut: String?
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID
    @Environment(\.composerActionDismiss) private var dismiss

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
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
                        // A recent command can be as long as a line.
                        .lineLimit(1)
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
