import SwiftUI
import AppKit

// A pane in a window of its own.
//
// A terminal's view is a live AppKit view owned by its session and a web view is
// owned by its model, so neither can be drawn in two windows at once. A pop-out
// therefore moves the pane rather than copying it — and does so without touching
// the layout tree. The pane stays exactly where it was in its tab, so saving,
// the Tasks list, the sidebar and focus all carry on as before; the main window
// draws a placeholder in its place while the other window has it, and closing
// that window just stops drawing the placeholder. That is what puts the pane back
// where it came from.

/// What names a pop-out window: the id of the pane it holds.
///
/// Its own type, not a bare `UUID`: the Remote Desktop windows are a
/// `WindowGroup` keyed by `UUID` too, and `openWindow(value:)` could not tell the
/// two apart.
struct PoppedPaneID: Codable, Hashable {
    var id: UUID
}

extension Notification.Name {
    /// Asks the main window to open a pop-out window. `userInfo["id"]` is the
    /// pane's id — only a view has `openWindow`, so the request goes through one,
    /// as Remote Desktop's does.
    static let popOutPane = Notification.Name("iTERMiNAL.PopOutPane")
}

/// The panes that are in windows of their own right now.
///
/// Not saved: a window does not survive a quit, so a pane is back in its tab the
/// next time the app opens.
final class PoppedPanes: ObservableObject {
    static let shared = PoppedPanes()

    @Published private(set) var ids: Set<UUID> = []

    func contains(_ id: UUID) -> Bool { ids.contains(id) }

    /// Moves a pane into a window of its own. Only a pane that holds content
    /// can go: a split is the arrangement of the panes inside it.
    func popOut(_ node: PaneNode) {
        guard node.isLeaf, !ids.contains(node.id) else { return }
        ids.insert(node.id)
        NotificationCenter.default.post(name: .popOutPane, object: nil, userInfo: ["id": node.id])
    }

    /// Puts a pane back in its tab. The window notices it no longer holds
    /// anything and closes; one already closing arrives here from its own close.
    func bringBack(_ id: UUID) {
        guard ids.contains(id) else { return }
        ids.remove(id)
        WorkspaceStore.shared.reveal(paneNodeID: id)
    }
}

// MARK: - Finding a pane

extension PaneNode {
    /// This node, or the one beneath it with `id`.
    func find(_ id: UUID) -> PaneNode? {
        if self.id == id { return self }
        if case .split(_, let children) = content {
            for child in children {
                if let found = child.find(id) { return found }
            }
        }
        return nil
    }
}

extension WorkspaceStore {
    func paneNode(withID id: UUID) -> PaneNode? {
        for workspace in workspaces {
            for tab in workspace.tabs {
                if let node = tab.root.find(id) { return node }
            }
        }
        return nil
    }

    /// Shows the tab a pane belongs to, with the pane focused, so a pane that
    /// has just come back is where the person is looking.
    func reveal(paneNodeID id: UUID) {
        for workspace in workspaces {
            for tab in workspace.tabs {
                guard let node = tab.root.find(id) else { continue }
                showTerminalSurface()
                // Focus first: selecting the tab keeps a focus that is already
                // inside it.
                if let session = node.firstTerminal() { focusedSessionID = session.id }
                selectedTabID = tab.id
                return
            }
        }
    }

    /// The focused pane, or a tab's only pane, in a window of its own.
    func popOutFocusedPane() {
        guard let tab = selectedTab else { return }
        if let focusedSessionID, let leaf = tab.root.leaf(containingSessionID: focusedSessionID) {
            PoppedPanes.shared.popOut(leaf)
        } else if tab.root.isLeaf {
            PoppedPanes.shared.popOut(tab.root)
        }
    }
}

// MARK: - The buttons

private struct HostPaneNodeKey: EnvironmentKey {
    static let defaultValue: PaneNode? = nil
}

extension EnvironmentValues {
    /// The pane a view is the content of, when it is in a tab's layout. Nil in a
    /// side panel and in the pop-out window itself, so the button hides there.
    var hostPaneNode: PaneNode? {
        get { self[HostPaneNodeKey.self] }
        set { self[HostPaneNodeKey.self] = newValue }
    }
}

/// The button in a pane's toolbar that moves it to a window of its own. Draws
/// nothing outside a tab's layout, so a pane's toolbar can carry it everywhere.
struct PopOutButton: View {
    @Environment(\.hostPaneNode) private var node

    var body: some View {
        if let node {
            Button {
                PoppedPanes.shared.popOut(node)
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.plain)
            .help("Open in its own window")
            .accessibilityLabel("Open in its own window")
        }
    }
}

/// A terminal has no toolbar, so its button appears in the corner while the
/// pointer is there.
struct TerminalPopOutCorner: View {
    let node: PaneNode
    @ObservedObject var session: TerminalSession
    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        // Not while the session's banner is up: its Reconnect and Restart
        // buttons are in this corner and must not be covered.
        if session.statusNote == nil {
            ZStack {
                Color.clear
                if hovering {
                    Button {
                        PoppedPanes.shared.popOut(node)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(theme.surface.opacity(0.92)))
                            .overlay(Circle().strokeBorder(theme.surfaceBorder))
                    }
                    .buttonStyle(.plain)
                    .help("Open in its own window")
                    .accessibilityLabel("Open in its own window")
                }
            }
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: hovering)
            .padding(.top, 4)
            .padding(.trailing, 4)
        }
    }
}

/// What the main window shows where a pane has gone to a window of its own.
struct PoppedOutPlaceholder: View {
    let node: PaneNode
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        VStack(spacing: 10) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(theme.textSecondary)
            Text("Open in its own window")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.textPrimary)
            Button("Bring Back") {
                PoppedPanes.shared.bringBack(node.id)
            }
            .controlSize(.small)
            Text("Closing that window puts it back here.")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }
}

// MARK: - The window

/// The window a popped-out pane lives in.
struct PoppedPaneWindow: View {
    let value: PoppedPaneID?
    @EnvironmentObject private var store: WorkspaceStore
    @ObservedObject private var popped = PoppedPanes.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let id = value?.id, popped.contains(id), let node = store.paneNode(withID: id) {
            PoppedPaneContent(node: node)
        } else {
            // The pane has been brought back or closed — or this is a window
            // restored from a last launch, which holds nothing.
            Color.clear
                .frame(width: 1, height: 1)
                .onAppear { dismiss() }
        }
    }
}

private struct PoppedPaneContent: View {
    @ObservedObject var node: PaneNode
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID

    /// Remembered between pop-outs: someone who keeps one in front wants the
    /// next one to stay there too.
    @AppStorage("popOutKeepInFront") private var keepInFront = false
    @State private var window: NSWindow?

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        Group {
            switch node.content {
            case .terminal(let session):
                PoppedTerminal(session: session)
            case .browser(let model):
                BrowserPaneView(model: model)
                    .navigationTitle("Browser")
            case .files(let model):
                FilePaneView(model: model)
                    .navigationTitle("Files")
            case .http(let model):
                HTTPClientPaneView(model: model)
                    .navigationTitle("HTTP Client")
            case .split:
                // The pane was split while it was out here, so it is a layout
                // again and belongs in the tab.
                Color.clear.onAppear { PoppedPanes.shared.bringBack(node.id) }
            }
        }
        .frame(minWidth: 320, minHeight: 200)
        .background(theme.background)
        .background(PopOutWindowReader { window = $0 })
        // No pop-out button inside the pop-out window.
        .environment(\.hostPaneNode, nil)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: $keepInFront) {
                    Label("Keep in Front", systemImage: keepInFront ? "pin.fill" : "pin")
                }
                .toggleStyle(.button)
                .help(keepInFront
                      ? "Let other windows cover this one"
                      : "Keep this window in front of other windows")

                Button {
                    PoppedPanes.shared.bringBack(node.id)
                } label: {
                    Label("Return to Main Window", systemImage: "arrow.down.left.and.arrow.up.right")
                }
                .help("Put this back in the main window")
            }
        }
        .onChange(of: keepInFront) { _, _ in applyLevel() }
        .onChange(of: window) { _, _ in applyLevel() }
        // Closing the window — the red button, ⌘W — puts the pane back.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if let closing = note.object as? NSWindow, closing === window {
                PoppedPanes.shared.bringBack(node.id)
            }
        }
        // A tab or pane closed while this window is open does not announce
        // itself to the store's observers, so look now and then.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if store.paneNode(withID: node.id) == nil {
                PoppedPanes.shared.bringBack(node.id)
                dismiss()
            }
        }
    }

    /// Above ordinary windows while it is on; the same as any other when off.
    private func applyLevel() {
        window?.level = keepInFront ? .floating : .normal
    }
}

/// The terminal, with the shell's own title on the window as it changes.
private struct PoppedTerminal: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        TerminalPaneView(session: session, isSolo: true)
            .navigationTitle(session.displayTitle)
    }
}

/// Hands back the window a view is in, once it has one.
private struct PopOutWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = Reader()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? Reader)?.onWindow = onWindow
    }

    private final class Reader: NSView {
        var onWindow: (NSWindow?) -> Void = { _ in }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let found = window
            // Not now: this is mid-layout, and the callback sets view state.
            DispatchQueue.main.async { [onWindow] in onWindow(found) }
        }
    }
}
