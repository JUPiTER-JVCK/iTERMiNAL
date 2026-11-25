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
            // The same size as the card's move grip, so the two handles read
            // as one family.
            .frame(width: 40, height: 4)
            .animation(Motion.hover, value: hovering)
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

/// Preference keys the composer's views share, in one place so the card and the
/// menus and sidebar rows that act on it cannot drift apart on a spelling.
enum ComposerStorage {
    /// Whether the card's transcript — the composer's shell, or the AI chat —
    /// is folded away, leaving the input on its own. The shell and the chat
    /// keep running underneath; only the view of them is put away.
    static let transcriptRetracted = "composerTranscriptRetracted"
}

/// What the tray under the card holds: a switch for where what is typed goes —
/// the terminals in view, the composer's own shell, or the AI — and a chip or
/// two about wherever that is.
///
/// It used to be a menu behind a chip, beside one for the space and a button
/// for the dock. The choice it hides is the one the card is most often wrong
/// about, so it is laid out flat: all three options, one click each, the chosen
/// one lit.
struct ComposerDestinationRow: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        HStack(spacing: 8) {
            ComposerDestinationPicker(
                selection: $settings.composerTarget,
                theme: theme,
                accent: settings.accentColor
            )
            .help(settings.composerTarget.detail)

            detail(theme: theme)

            Spacer(minLength: 0)
        }
    }

    /// About where input is going now. Read from the destination rather than
    /// the setting: with "Terminals" chosen, what that means is whichever
    /// terminal has focus.
    @ViewBuilder
    private func detail(theme: Theme) -> some View {
        switch store.composerDestination {
        case .terminal(let session):
            if session.isRemote {
                ComposerChip(icon: "network", text: session.connection?.name ?? "Remote", theme: theme)
            }
            BranchChip(session: session, theme: theme)
        case .ownShell:
            if let session = store.composerSession {
                DirectoryChip(session: session, theme: theme)
                BranchChip(session: session, theme: theme)
            } else {
                Text("Starts with the first command")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
            }
        case .assistant:
            ComposerChip(icon: "sparkles", text: modelName, theme: theme)
        }
    }

    private var modelName: String {
        let name = settings.assistantModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "AI assistant" : name
    }
}

/// The three-way switch itself: a capsule track with the chosen option lit in
/// the accent, drawn like the settings pages' `PillSegmentedPicker` but
/// compact, and without a form row around it.
struct ComposerDestinationPicker: View {
    @Binding var selection: ComposerTarget
    let theme: Theme
    let accent: Color

    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ComposerTarget.allCases) { target in
                segment(target)
            }
        }
        .padding(2)
        .background(Capsule().fill(theme.surfaceHover.opacity(0.6)))
        .overlay(Capsule().strokeBorder(theme.surfaceBorder).allowsHitTesting(false))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Where the composer runs what you type")
    }

    private func segment(_ target: ComposerTarget) -> some View {
        let isSelected = target == selection
        return Button {
            // Under Reduce Motion the pill changes place without travelling.
            withAnimation(reduceMotion ? nil : Motion.suggestion) {
                selection = target
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: target.icon)
                    .font(.system(size: 9))
                Text(target.shortLabel)
                    .font(.system(size: 10.5, weight: isSelected ? .medium : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
            .padding(.horizontal, 9)
            .frame(height: 20)
            .background {
                if isSelected {
                    Capsule()
                        .fill(accent.opacity(0.24))
                        .matchedGeometryEffect(id: "selection", in: pill)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(target.detail)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The destination's git branch, observed separately so it refreshes as the
/// shell moves around without the whole chip row depending on one session.
struct BranchChip: View {
    @ObservedObject var session: TerminalSession
    let theme: Theme

    var body: some View {
        if let branch = session.gitBranch {
            ComposerChip(icon: "arrow.triangle.branch", text: branch, theme: theme)
        }
    }
}

/// Where the shell is, observed so it follows a `cd`.
struct DirectoryChip: View {
    @ObservedObject var session: TerminalSession
    let theme: Theme

    var body: some View {
        ComposerChip(icon: "folder", text: session.abbreviatedDirectory, theme: theme)
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

/// The shell the composer is typing into, shown only while that is worth
/// saying: the composer's own shell once it is running, or a remote host.
///
/// It used to sit beside the send button all the time, naming a shell nothing
/// was using — "zsh" next to a chat with the AI, or next to a local terminal
/// that is plainly in view. Absent now unless it tells you something.
struct SessionChip: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        if let label {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .help("Input goes to this session")
                .transition(.opacity)
        }
    }

    /// Nil when there is nothing worth naming.
    private var label: String? {
        switch store.composerDestination {
        case .assistant:
            return nil
        case .ownShell:
            // Before the first command there is no shell yet, only the
            // intention of one.
            guard store.composerHasRun else { return nil }
            // The composer's own override, not the global setting: this chip
            // sits on the composer and its tooltip says input goes to this
            // session, so naming the app-wide default while the composer runs
            // bash would be pointing at the wrong shell.
            let override = settings.composerShell
            let shell = settings.resolvedShell(override: override.isEmpty ? nil : override)
            return (shell.path as NSString).lastPathComponent
        case .terminal(let session):
            // A local terminal is in front of you; a remote one is the case
            // where it is easy to forget the command is not running here.
            return session.isRemote ? (session.connection?.name ?? "remote") : nil
        }
    }
}
