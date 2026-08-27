import SwiftUI

/// Tall rounded composer matching the reference layout: multi-line input on
/// top, a "+" menu bottom-left and circular send button bottom-right, with a
/// footer row underneath — context tabs on the left, the focused session's
/// git branch on the right. Plain text goes to the focused terminal; "@ai …"
/// is reserved for the assistant.
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
            }

            VStack(alignment: .leading, spacing: 12) {
                TextField("Run anything", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...6)
                    .onSubmit(send)

                HStack {
                    Menu {
                        Button("New Terminal Tab") { store.newTab() }
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
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(theme.surfaceBorder))

            ComposerFooter()
        }
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send() {
        let command = trimmedText
        guard !command.isEmpty else { return }
        if command.lowercased().hasPrefix("@ai") {
            assistantNotice = !NullAssistantService.shared.isConfigured
            text = ""
            return
        }
        assistantNotice = false
        store.sendToFocusedTerminal(command + "\n")
        text = ""
    }
}

/// "Local | Worktree | Cloud" context tabs (only Local is live today) and
/// the focused session's git branch.
private struct ComposerFooter: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        HStack(spacing: 14) {
            Text("Local")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textPrimary)
            Text("Worktree")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary.opacity(0.6))
                .help("Git-worktree sessions are coming soon")
            Text("Cloud")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary.opacity(0.6))
                .help("Remote sessions are coming soon")
            Spacer()
            if let session = store.focusedSession {
                BranchLabel(session: session)
            }
        }
        .padding(.horizontal, 8)
    }
}

private struct BranchLabel: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        if let branch = session.gitBranch {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10))
                Text(branch)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .help("Git branch in \(session.abbreviatedDirectory)")
        }
    }
}
