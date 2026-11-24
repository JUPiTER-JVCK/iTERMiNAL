import SwiftUI
import AppKit

// The frame of a pop-out window — a pane or a side panel in a window of its own.
//
// These windows used to be an ordinary titled window with a SwiftUI toolbar: a
// system title bar in its own colour, with the pin and return buttons in it as
// full-size toolbar buttons, much larger than anything else in the app. This
// replaces that with what the main window does — a frameless window, the three
// traffic lights floating over a slim bar of the app's own — so the bar and the
// content below it are one surface rather than a title bar stuck on a window.

/// The least a pop-out window can be resized to.
private let popOutMinimumSize = CGSize(width: 320, height: 200)

/// A pop-out window's content under its slim title bar.
///
/// Owns what every pop-out window shares: the "keep in front" choice, putting
/// the content back when the window closes, and the window's own look.
struct PopOutFrame<Content: View>: View {
    let title: String
    let icon: String
    /// Puts the content back where it came from. Called by the bar's return
    /// button and when the window closes — the red button, ⌘W.
    let bringBack: () -> Void
    let content: Content

    /// Remembered between pop-outs: someone who keeps one in front wants the
    /// next one to stay there too. Shared by panes and panels.
    @AppStorage("popOutKeepInFront") private var keepInFront = false
    @State private var window: NSWindow?
    @State private var isFullScreen = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID

    init(
        title: String,
        icon: String,
        bringBack: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.bringBack = bringBack
        self.content = content()
    }

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        VStack(spacing: 0) {
            PopOutTitleBar(
                title: title,
                icon: icon,
                keepInFront: $keepInFront,
                clearsTrafficLights: !isFullScreen,
                bringBack: bringBack
            )
            content
        }
        .frame(minWidth: popOutMinimumSize.width, minHeight: popOutMinimumSize.height)
        .background(theme.background)
        // Frameless, and the window itself the same colour as the content: any
        // sliver the content does not reach — a live resize, the corners — is
        // part of the same surface, not the system's grey.
        .framelessWindow()
        .background(WindowBackgroundPainter(color: theme.background))
        .background(PopOutWindowReader { window = $0 })
        // Still the window's name, in the Window menu and Mission Control, even
        // though the bar draws its own.
        .navigationTitle(title)
        .onChange(of: keepInFront) { _, _ in applyLevel() }
        .onChange(of: window) { _, _ in applyLevel() }
        // Closing the window puts what it holds back.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if let closing = note.object as? NSWindow, closing === window { bringBack() }
        }
        // The traffic lights are gone in full screen, so the bar need not leave
        // room for them.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            if let entered = note.object as? NSWindow, entered === window { isFullScreen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            if let left = note.object as? NSWindow, left === window { isFullScreen = false }
        }
    }

    /// Above ordinary windows while it is on; the same as any other when off.
    private func applyLevel() {
        window?.level = keepInFront ? .floating : .normal
    }
}

/// The slim bar along a pop-out window's top: the traffic lights float over its
/// leading end, then what the window holds, and at the trailing end two small
/// buttons. Dragging anywhere else on it moves the window.
private struct PopOutTitleBar: View {
    let title: String
    let icon: String
    @Binding var keepInFront: Bool
    let clearsTrafficLights: Bool
    let bringBack: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        HStack(spacing: 6) {
            // Hit-testing off so the drag area behind it takes the click.
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            PopOutBarButton(
                icon: keepInFront ? "pin.fill" : "pin",
                help: keepInFront
                    ? "Let other windows cover this one"
                    : "Keep this window in front of other windows",
                isActive: keepInFront
            ) {
                keepInFront.toggle()
            }

            PopOutBarButton(
                icon: "arrow.down.left.and.arrow.up.right",
                help: "Put this back in the main window",
                isActive: false,
                action: bringBack
            )
        }
        // Clear the traffic lights sideways, as the main window's bar does.
        .padding(.leading, clearsTrafficLights ? WindowChrome.trafficLightWidth : 12)
        .padding(.trailing, 8)
        .frame(height: WindowChrome.titleBarHeight)
        .background(WindowDragArea())
    }
}

/// One of the bar's buttons: the same 22pt square, 11pt glyph and hover fill as
/// the buttons in a side panel's header, so a window's bar reads as part of the
/// same app and not as a system toolbar.
private struct PopOutBarButton: View {
    let icon: String
    let help: String
    let isActive: Bool
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                // `.tint`, not `Color.accentColor`: the app's accent setting is
                // applied as a tint on the window's content.
                .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(theme.textSecondary))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(theme.surface.opacity(hovering ? 0.6 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Motion.hover, value: hovering)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// Hands back the window a view is in, once it has one.
struct PopOutWindowReader: NSViewRepresentable {
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
