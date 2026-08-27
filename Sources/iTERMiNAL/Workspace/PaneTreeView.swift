import SwiftUI

/// Renders a tab's layout tree: splits become HSplitView/VSplitView, leaves
/// become rounded cards hosting a terminal, browser, or file pane.
struct PaneTreeView: View {
    @ObservedObject var node: PaneNode

    var body: some View {
        switch node.content {
        case .terminal(let session):
            TerminalPaneView(session: session)
        case .browser(let model):
            PaneCard {
                BrowserPaneView(model: model)
            }
        case .files(let model):
            PaneCard {
                FilePaneView(model: model)
            }
        case .split(let direction, let children):
            if direction == .horizontal {
                HSplitView {
                    ForEach(children) { child in
                        PaneTreeView(node: child)
                            .frame(minWidth: 160, maxWidth: .infinity, minHeight: 100, maxHeight: .infinity)
                    }
                }
            } else {
                VSplitView {
                    ForEach(children) { child in
                        PaneTreeView(node: child)
                            .frame(minWidth: 160, maxWidth: .infinity, minHeight: 100, maxHeight: .infinity)
                    }
                }
            }
        }
    }
}

/// Shared rounded-card treatment for non-terminal leaf panes.
struct PaneCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder let content: Content

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        content
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.surfaceBorder)
            )
            .padding(3)
    }
}

/// Terminal leaf: rounded card plus an accent focus ring on the pane the
/// keyboard currently drives.
struct TerminalPaneView: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        let isFocused = store.focusedSessionID == session.id
        TerminalHostView(session: session)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isFocused ? settings.accentColor.opacity(0.55) : theme.surfaceBorder,
                        lineWidth: isFocused ? 1.5 : 1
                    )
            )
            .padding(3)
    }
}
