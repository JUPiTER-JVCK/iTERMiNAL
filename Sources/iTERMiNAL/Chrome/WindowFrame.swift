import SwiftUI

// The two bars of the window's frame — the top bar across the whole width and
// the icon rail down the left edge. Both sit on the window's chrome color; the
// content lives in a rounded card inside them (see `MainWindowView`).

// MARK: - Surface

/// The fill behind the top bar and the rail — and the workspaces panel, which
/// is the same family — as one view, so they can't differ: flat or with
/// vibrancy, tinted or not, they are always the same surface.
struct FrameSurface: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if settings.sidebarTranslucent {
            // Vibrancy can't be mixed with a color, so the tint goes over it.
            ZStack {
                VisualEffectView(material: .sidebar)
                if let tint = settings.frameTintHex {
                    Color(hex: tint).opacity(settings.frameTintStrength)
                }
            }
            .ignoresSafeArea()
        } else {
            settings.frameColor(for: colorScheme).ignoresSafeArea()
        }
    }
}

// MARK: - Top bar

/// The window's one top bar, standing in for the system title bar: the
/// traffic lights float over its leading end, then a button to show or hide
/// the workspaces panel, what you're looking at, and — at the far right — the
/// single button that opens the panels menu. Dragging anywhere on it moves the
/// window.
struct TopBar: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        HStack(spacing: 10) {
            BarIconButton(
                icon: "sidebar.left",
                help: settings.railPanelOpen ? "Hide sidebar" : "Show sidebar",
                isActive: settings.railPanelOpen
            ) {
                withAnimation(Motion.panel) { settings.railPanelOpen.toggle() }
            }

            Rectangle()
                .fill(theme.surfaceBorder)
                .frame(width: 1, height: 16)

            // Hit-testing off so the drag area behind it takes the click.
            breadcrumb(theme)
                .allowsHitTesting(false)

            Spacer(minLength: 12)

            BarIconButton(
                icon: store.rightRegionOpen ? "chevron.right" : "chevron.left",
                help: store.rightRegionOpen ? "Hide panels and tools" : "Show panels and tools",
                isActive: store.rightRegionOpen
            ) {
                store.toggleRightRegion()
            }

            PanelsMenuButton()
        }
        // Clear the traffic lights sideways, not downwards: padding down past
        // them would leave an empty band above everything else in the bar.
        .padding(.leading, WindowChrome.trafficLightWidth)
        // The last button's edge lines up with the content card's right edge
        // below it — the card is inset by the frame gap — and never closer to
        // the window edge than the rail's icons are to theirs.
        .padding(.trailing, max(settings.frameGap, WindowChrome.railIconInset))
        .frame(height: WindowChrome.topBarHeight)
        .background(WindowDragArea())
    }

    /// Where you are, from the outside in: the space, the tab, and — for a
    /// terminal — the folder and branch its shell is in. On any other page,
    /// just the page's name.
    @ViewBuilder
    private func breadcrumb(_ theme: Theme) -> some View {
        HStack(spacing: 6) {
            if store.detailMode == .terminal, store.selectedTab != nil,
               let space = store.currentWorkspace?.name, !space.isEmpty {
                Text(space)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                crumbSeparator(theme)
            }

            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                // The tab's name is the last thing to give way when the bar
                // is narrow.
                .layoutPriority(1)

            if store.detailMode == .terminal, store.selectedTab != nil,
               let session = store.focusedSession, !session.kind.isTool {
                TopBarSessionCrumbs(session: session, theme: theme)
                    .id(session.id)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func crumbSeparator(_ theme: Theme) -> some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(theme.textSecondary.opacity(0.6))
            .accessibilityHidden(true)
    }

    private var title: String {
        switch store.detailMode {
        case .terminal: return store.selectedTab?.displayName ?? "iTERMiNAL"
        case .tasks: return RailItem.tasks.title
        case .automations: return RailItem.automations.title
        case .skills: return RailItem.skills.title
        case .cheatsheet: return RailItem.cheatsheet.title
        }
    }
}

/// The focused terminal's folder and branch, after the tab's name. Its own
/// view because the session is its own observable object: read from the bar,
/// these would not follow a `cd`.
private struct TopBarSessionCrumbs: View {
    @ObservedObject var session: TerminalSession
    let theme: Theme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(theme.textSecondary.opacity(0.6))
                .accessibilityHidden(true)

            Text(session.abbreviatedDirectory)
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let branch = session.gitBranch, !session.isRemote {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9))
                    Text(branch)
                        .font(.system(size: 11))
                        .lineLimit(1)
                }
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(theme.surface.opacity(0.7)))
            }
        }
    }
}

private struct BarIconButton: View {
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
                .font(.system(size: 13))
                .foregroundStyle(isActive ? theme.textPrimary : theme.textSecondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(theme.surface.opacity(hovering ? 0.6 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Motion.hover, value: hovering)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Rail

/// Where an item on the rail takes you. Shared by the rail's own buttons and
/// the rows of its "···" menu, so both do the same thing.
enum RailNavigation {
    static func open(_ item: RailItem, store: WorkspaceStore, settings: AppSettings) {
        switch item {
        case .terminal: store.goHome()
        case .workspaces: withAnimation(Motion.panel) { settings.railPanelOpen.toggle() }
        case .tasks: store.detailMode = .tasks
        case .automations: store.detailMode = .automations
        case .skills: store.detailMode = .skills
        case .cheatsheet: store.detailMode = .cheatsheet
        }
    }
}

/// The icon rail down the left edge: the two destinations that are always
/// there, whichever of the rest you've pinned under a rule, and at the bottom a
/// "···" menu for the rest and the terminal dock.
struct SidebarRail: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID
    @State private var moreOpen = false

    /// Live shells, shown as a badge on Tasks so the count is visible without
    /// opening the page.
    private var runningTaskCount: Int {
        store.allTasks().filter(\.session.isRunning).count
    }

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        let pinned = settings.pinnedRailItems
        VStack(spacing: 6) {
            railButton(.terminal)
            railButton(.workspaces)

            if !pinned.isEmpty {
                Rectangle()
                    .fill(theme.surfaceBorder)
                    .frame(width: 24, height: 1)
                    .padding(.vertical, 2)
                ForEach(pinned) { item in
                    railButton(item)
                }
            }

            Spacer(minLength: 0)

            // Just above the dock, at the bottom of the rail.
            RailButton(icon: "ellipsis", title: "More", isActive: moreOpen, isToggle: true) {
                moreOpen.toggle()
            }
            .popover(isPresented: $moreOpen, arrowEdge: .trailing) {
                RailMoreMenu(dismiss: { moreOpen = false })
                    .environmentObject(store)
                    .environmentObject(settings)
            }

            // The bottom left of the frame: the terminal dock, the one panel
            // that is always a keystroke away, so it gets a button where the
            // dock itself opens.
            RailButton(
                icon: "rectangle.bottomthird.inset.filled",
                title: "Terminal dock (⌘J)",
                isActive: store.bottomDockOpen,
                isToggle: true
            ) {
                store.toggleBottomDock()
            }
        }
        .padding(.top, 6)
        .padding(.bottom, max(settings.frameGap, WindowChrome.railBottomInset))
        .frame(width: WindowChrome.railWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        // Empty rail is chrome like the bar above it: drag it to move the
        // window.
        .background(WindowDragArea())
    }

    private func railButton(_ item: RailItem) -> some View {
        RailButton(
            icon: item.icon,
            title: item.title,
            isActive: isActive(item),
            // Workspaces shows and hides a panel; it is not somewhere you are.
            isToggle: item == .workspaces,
            badge: item == .tasks ? runningTaskCount : nil
        ) {
            RailNavigation.open(item, store: store, settings: settings)
        }
    }

    private func isActive(_ item: RailItem) -> Bool {
        switch item {
        case .terminal: return store.isHome
        case .workspaces: return settings.railPanelOpen
        case .tasks: return store.detailMode == .tasks
        case .automations: return store.detailMode == .automations
        case .skills: return store.detailMode == .skills
        case .cheatsheet: return store.detailMode == .cheatsheet
        }
    }
}

/// The icon itself, without a button around it — a `Menu` supplies its own.
struct RailIconLabel: View {
    let icon: String
    var isActive = false
    /// A button that shows and hides something — the workspaces panel, the
    /// dock, the "···" menu — rather than a page. It brightens while its
    /// thing is open but never takes the raised tile, which is left to mean
    /// one thing: the page you are on.
    var isToggle = false
    var isHovering = false
    var badge: Int? = nil

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        let raised = isActive && !isToggle
        Image(systemName: icon)
            .font(.system(size: 16))
            .foregroundStyle(isActive ? theme.textPrimary : theme.textSecondary)
            .frame(width: 40, height: 40)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(raised ? theme.surface : theme.surface.opacity(isHovering ? 0.6 : 0))
            )
            .overlay(
                // The selected icon is lit like a raised surface — a hairline
                // catching the light along its top — rather than a flat tile.
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [theme.elevatedHighlight, .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                    .opacity(raised ? 1 : 0)
            )
            .overlay(alignment: .topTrailing) {
                if let badge, badge > 0 {
                    Text(badge > 99 ? "99+" : "\(badge)")
                        .font(.system(size: 9, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        // The count rolls to its new value.
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .animation(reduceMotion ? nil : Motion.hover, value: badge)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 14, minHeight: 14)
                        // The app's accent, not the system's: the badge is
                        // the one spot of colour on the rail, and the system
                        // blue clashed with any other accent.
                        .background(Capsule().fill(settings.accentColor))
                        .overlay(Capsule().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
                        .offset(x: 2, y: -2)
                }
            }
            .animation(Motion.hover, value: isHovering)
            .animation(Motion.hover, value: isActive)
            .contentShape(Rectangle())
    }
}

struct RailButton: View {
    let icon: String
    let title: String
    var isActive = false
    var isToggle = false
    var badge: Int? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            RailIconLabel(icon: icon, isActive: isActive, isToggle: isToggle, isHovering: hovering, badge: badge)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
    }
}

/// The rail's "···" menu: everything that can be pinned, each with a pin
/// that puts its icon on the rail (filled) or takes it off (outline).
/// Clicking the name goes there; clicking the pin leaves the menu open so
/// several can be pinned in one visit.
private struct RailMoreMenu: View {
    let dismiss: () -> Void

    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        let pinned = settings.pinnedRailItems
        VStack(alignment: .leading, spacing: 2) {
            ForEach(RailItem.pinnable) { item in
                RailMoreRow(
                    item: item,
                    isPinned: pinned.contains(item),
                    onOpen: {
                        RailNavigation.open(item, store: store, settings: settings)
                        dismiss()
                    },
                    onTogglePin: { settings.toggleRailPin(item) }
                )
            }
        }
        .padding(6)
        .frame(width: 230)
    }
}

private struct RailMoreRow: View {
    let item: RailItem
    let isPinned: Bool
    let onOpen: () -> Void
    let onTogglePin: () -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        HStack(spacing: 4) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Image(systemName: item.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 18)
                    Text(item.title)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textPrimary)
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onTogglePin) {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 11))
                    .foregroundStyle(isPinned ? theme.textPrimary : theme.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isPinned ? "Unpin from the rail" : "Pin to the rail")
            .accessibilityLabel(isPinned ? "Unpin \(item.title)" : "Pin \(item.title)")
        }
        // 12 leading against the pin's 24pt frame at 6 trailing: the icon
        // and the pin glyph sit the same distance from the row's two ends.
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 32)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.surface.opacity(hovering ? 0.7 : 0))
        )
        .animation(Motion.hover, value: hovering)
        .onHover { hovering = $0 }
    }
}
