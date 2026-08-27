import SwiftUI

/// Rounded input bar fixed under the panes — the app's command entry point,
/// and later the seam where the AI assistant plugs in. Plain text goes to
/// the focused terminal; "@ai …" is reserved for the assistant.
struct ComposerBar: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    @State private var text = ""
    @State private var assistantNotice = false

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        VStack(spacing: 6) {
            if assistantNotice {
                Text("The AI assistant isn't configured yet — @ai commands will be supported in a future release.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
            }
            HStack(spacing: 10) {
                Menu {
                    Button("New Terminal Tab") { store.newTab() }
                    Divider()
                    Button("Split Right") { store.splitFocusedPane(.horizontal, kind: .terminal) }
                    Button("Split Down") { store.splitFocusedPane(.vertical, kind: .terminal) }
                    Button("Split with Browser") { store.splitFocusedPane(.horizontal, kind: .browser) }
                    Button("Split with Files") { store.splitFocusedPane(.horizontal, kind: .files) }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()

                TextField("Run a command…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...5)
                    .onSubmit(send)

                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                        .frame(width: 26, height: 26)
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
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(theme.surfaceBorder))
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
