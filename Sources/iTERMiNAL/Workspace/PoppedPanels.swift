import SwiftUI
import AppKit

// A side panel in a window of its own.
//
// The same idea as `PoppedPanes`, for the panels in the trailing region: a
// panel's view is live (a web view, a terminal running a tool) and cannot be
// drawn in two windows, so a pop-out moves it. The panel stays open and where it
// was in the arrangement; the region draws a placeholder in its place while the
// other window has it, and closing that window just stops the placeholder.

/// What names a panel's window: the panel's raw value.
///
/// Its own type, so `openWindow(value:)` can tell this window group from the
/// pane and Remote Desktop ones.
struct PoppedPanelID: Codable, Hashable {
    var panel: String
}

extension Notification.Name {
    /// Asks the main window to open a window for a panel. `userInfo["panel"]` is
    /// the panel's raw value — only a view has `openWindow`.
    static let popOutPanel = Notification.Name("iTERMiNAL.PopOutPanel")
}

/// The panels that are in windows of their own right now. Not saved: a window
/// does not survive a quit, so a panel is back in the region next launch.
final class PoppedPanels: ObservableObject {
    static let shared = PoppedPanels()

    @Published private(set) var panels: Set<SidePanel> = []

    func contains(_ panel: SidePanel) -> Bool { panels.contains(panel) }

    func popOut(_ panel: SidePanel) {
        guard !panels.contains(panel) else { return }
        panels.insert(panel)
        NotificationCenter.default.post(
            name: .popOutPanel, object: nil, userInfo: ["panel": panel.rawValue]
        )
    }

    /// Puts a panel back in the region. The window notices it holds nothing and
    /// closes; one already closing arrives here from its own close.
    func bringBack(_ panel: SidePanel) {
        guard panels.contains(panel) else { return }
        panels.remove(panel)
        WorkspaceStore.shared.focusPanel(panel)
    }
}

/// The button in a panel's header that moves it to a window of its own.
struct PanelPopOutButton: View {
    let panel: SidePanel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        Button {
            PoppedPanels.shared.popOut(panel)
        } label: {
            Image(systemName: "arrow.up.right.square")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(panel.title) in its own window")
        .accessibilityLabel("Open \(panel.title) in its own window")
    }
}

/// What the region shows where a panel has gone to a window of its own.
struct PoppedPanelPlaceholder: View {
    let panel: SidePanel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        VStack(spacing: 10) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(theme.textSecondary)
            Text("\(panel.title) is in its own window")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.textPrimary)
                .multilineTextAlignment(.center)
            Button("Bring Back") {
                PoppedPanels.shared.bringBack(panel)
            }
            .controlSize(.small)
            Text("Closing that window puts it back here.")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
    }
}

/// The window a popped-out panel lives in.
struct PoppedPanelWindow: View {
    let value: PoppedPanelID?
    @EnvironmentObject private var store: WorkspaceStore
    @ObservedObject private var popped = PoppedPanels.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let raw = value?.panel, let panel = SidePanel(rawValue: raw),
           popped.contains(panel), store.openPanels.contains(panel) {
            PoppedPanelContent(panel: panel)
        } else {
            // Brought back or closed — or a window restored from a last launch,
            // which holds nothing.
            Color.clear
                .frame(width: 1, height: 1)
                .onAppear {
                    if let raw = value?.panel, let panel = SidePanel(rawValue: raw) {
                        PoppedPanels.shared.bringBack(panel)
                    }
                    dismiss()
                }
        }
    }
}

private struct PoppedPanelContent: View {
    let panel: SidePanel
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID

    /// Shared with the pane pop-out windows.
    @AppStorage("popOutKeepInFront") private var keepInFront = false
    @State private var window: NSWindow?

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        SidePanelContent(panel: panel)
            .navigationTitle(panel.title)
            .frame(minWidth: 320, minHeight: 200)
            .background(theme.background)
            .background(PanelWindowReader { window = $0 })
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
                        PoppedPanels.shared.bringBack(panel)
                    } label: {
                        Label("Return to Main Window", systemImage: "arrow.down.left.and.arrow.up.right")
                    }
                    .help("Put this back in the main window")
                }
            }
            .onChange(of: keepInFront) { _, _ in applyLevel() }
            .onChange(of: window) { _, _ in applyLevel() }
            // Closing the window — the red button, ⌘W — puts the panel back.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
                if let closing = note.object as? NSWindow, closing === window {
                    PoppedPanels.shared.bringBack(panel)
                }
            }
    }

    private func applyLevel() {
        window?.level = keepInFront ? .floating : .normal
    }
}

/// Hands back the window a view is in, once it has one.
private struct PanelWindowReader: NSViewRepresentable {
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
            DispatchQueue.main.async { [onWindow] in onWindow(found) }
        }
    }
}
