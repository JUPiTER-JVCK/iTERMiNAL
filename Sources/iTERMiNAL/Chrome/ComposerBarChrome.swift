import SwiftUI
import AppKit

// Shared chrome helpers for ComposerBar (same module).

/// Drag to change how much of the composer's shell is visible; double-click
/// for the default height.
struct TranscriptResizeHandle: View {
    @Binding var height: Double
    /// The tallest the transcript can be and still leave the input reachable
    /// in the current window. Dragging stops here for the same reason the
    /// rendered height is capped there.
    let maxHeight: Double
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
                        height = (start + value.translation.height)
                            .clamped(to: 100...max(100, maxHeight))
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
struct ContextChipRow: View {
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

struct LocationChip: View {
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

struct ComposerChip: View {
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
struct SessionChip: View {
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
