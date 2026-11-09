import SwiftUI
import AppKit

/// The bottom-left of the window: where the focused terminal is. Follows focus
/// across tabs and panes, so it always describes the shell you are typing into.
struct StatusBarReadout: View {
    @EnvironmentObject private var store: WorkspaceStore

    var body: some View {
        // The session is its own observable object: reading its fields here
        // would not redraw on a `cd`. The child view observes it directly.
        if let session = store.focusedSession, !session.kind.isTool {
            StatusBarSession(session: session)
                .id(session.id)
        }
    }
}

private struct StatusBarSession: View {
    @ObservedObject var session: TerminalSession
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID

    /// Who and where: the saved host's user and name for a remote shell, this
    /// Mac's for a local one.
    private var identity: String {
        if session.isRemote, let connection = session.connection {
            let host = connection.name.isEmpty ? connection.host : connection.name
            return connection.username.isEmpty ? host : "\(connection.username)@\(host)"
        }
        let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return "\(NSUserName())@\(host)"
    }

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        HStack(spacing: 14) {
            item("person", identity)
            item("folder", session.abbreviatedDirectory)
            if let branch = session.gitBranch, !session.isRemote {
                item("arrow.triangle.branch", branch)
            }
            if let failure = session.failedCommandNote {
                item("exclamationmark.circle", failure, tint: .red)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(theme.textSecondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(session.isRemote ? identity : session.currentDirectory)
    }

    private func item(_ icon: String, _ text: String, tint: Color? = nil) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text)
        }
        .foregroundStyle(tint ?? .secondary)
    }
}
