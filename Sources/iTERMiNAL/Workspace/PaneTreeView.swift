import SwiftUI

/// Renders a tab's layout tree: splits become HSplitView/VSplitView, leaves
/// host a terminal, browser, or file pane.
///
/// A tab with a single pane draws no card and no focus ring — there is
/// nothing to disambiguate, and the reference app keeps its content flush to
/// the window. Card and ring treatment appears only once the tab is split.
struct PaneTreeView: View {
    @ObservedObject var node: PaneNode
    /// False once this node sits inside a split.
    var isSolo = true

    var body: some View {
        switch node.content {
        case .terminal(let session):
            TerminalPaneView(session: session, isSolo: isSolo)
        case .browser(let model):
            PaneCard(isSolo: isSolo) {
                BrowserPaneView(model: model)
            }
        case .files(let model):
            PaneCard(isSolo: isSolo) {
                FilePaneView(model: model)
            }
        case .split(let direction, let children):
            if direction == .horizontal {
                HSplitView {
                    ForEach(children) { child in
                        PaneTreeView(node: child, isSolo: false)
                            .frame(minWidth: 160, maxWidth: .infinity, minHeight: 100, maxHeight: .infinity)
                    }
                }
            } else {
                VSplitView {
                    ForEach(children) { child in
                        PaneTreeView(node: child, isSolo: false)
                            .frame(minWidth: 160, maxWidth: .infinity, minHeight: 100, maxHeight: .infinity)
                    }
                }
            }
        }
    }
}

/// Shared card treatment for non-terminal leaf panes. Flush when solo.
struct PaneCard<Content: View>: View {
    var isSolo = true
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder let content: Content

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        if isSolo {
            content
        } else {
            content
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(theme.surfaceBorder)
                )
                .padding(3)
        }
    }
}

/// Terminal leaf. Flush when it is the tab's only pane; inside a split it
/// gets a hairline card and a restrained focus tint on the pane the keyboard
/// currently drives.
struct TerminalPaneView: View {
    @ObservedObject var session: TerminalSession
    var isSolo = true
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        let isFocused = store.focusedSessionID == session.id
        let host = TerminalHostView(session: session)
            .overlay(alignment: .top) {
                if let note = session.statusNote {
                    SessionStatusBanner(session: session, note: note, theme: theme)
                }
            }

        if isSolo {
            host
        } else {
            host
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            isFocused ? settings.accentColor.opacity(0.30) : theme.surfaceBorder,
                            lineWidth: 1
                        )
                )
                .padding(3)
        }
    }
}

/// Shown when a session has exited, dropped, or failed to launch, with the
/// one action that matters: try again.
private struct SessionStatusBanner: View {
    @ObservedObject var session: TerminalSession
    let note: String
    let theme: Theme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 11))
            Text(session.launchError ?? "Session \(note).")
                .font(.system(size: 11))
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(session.isRemote ? "Reconnect" : "Restart") {
                session.reconnect()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(theme.textPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(theme.surface.opacity(0.96))
        .overlay(alignment: .bottom) { Divider() }
    }
}
