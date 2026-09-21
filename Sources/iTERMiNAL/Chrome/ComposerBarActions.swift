import SwiftUI
import AppKit

// Composer + actions popover helpers.

// MARK: - Actions popover

/// The composer's "+" surface: grouped rows with a title, a line of
/// explanation and the shortcut that does the same thing.
///
/// A `Menu` can render none of that — no section headings, no secondary text —
/// which is why this is a popover over hand-built rows.
struct ComposerActionsPopover: View {
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
