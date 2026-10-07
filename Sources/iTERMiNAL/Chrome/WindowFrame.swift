import SwiftUI

// The two bars of the window's frame — the top bar across the whole width and
// the icon rail down the left edge. Both sit on the window's chrome color; the
// content lives in a rounded card inside them (see `MainWindowView`).

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

    var body: some View {
        let theme = Theme.current(for: colorScheme)
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
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .allowsHitTesting(false)

            Spacer(minLength: 12)

            PanelsMenuButton()
        }
        // Clear the traffic lights sideways, not downwards: padding down past
        // them would leave an empty band above everything else in the bar.
        .padding(.leading, WindowChrome.trafficLightWidth)
        .padding(.trailing, 10)
        .frame(height: WindowChrome.topBarHeight)
        .background(WindowDragArea())
    }

    private var title: String {
        switch store.detailMode {
        case .terminal: return store.selectedTab?.displayName ?? "iTERMiNAL"
        case .tasks: return RailItem.tasks.title
        case .automations: return RailItem.automations.title
        case .skills: return RailItem.skills.title
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

    var body: some View {
        let theme = Theme.current(for: colorScheme)
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
        case .terminal: store.detailMode = .terminal
        case .workspaces: withAnimation(Motion.panel) { settings.railPanelOpen.toggle() }
        // A menu of its own on the rail; never routed through here.
        case .connections: break
        case .tasks: store.detailMode = .tasks
        case .automations: store.detailMode = .automations
        case .skills: store.detailMode = .skills
        }
    }
}

/// The icon rail down the left edge: the three destinations that are always
/// there, a "···" menu for the rest, and — under a rule — whichever of those
/// you've pinned.
struct SidebarRail: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var moreOpen = false
    @State private var connectHovering = false

    /// Live shells, shown as a badge on Tasks so the count is visible without
    /// opening the page.
    private var runningTaskCount: Int {
        store.allTasks().filter(\.session.isRunning).count
    }

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        let pinned = settings.pinnedRailItems
        VStack(spacing: 6) {
            railButton(.terminal)
            railButton(.workspaces)

            ConnectMenu(
                label: RailIconLabel(icon: RailItem.connections.icon, isHovering: connectHovering)
            )
            .onHover { connectHovering = $0 }
            .help("Connect to a saved host or a machine on this network")
            .accessibilityLabel("Connect")

            RailButton(icon: "ellipsis", title: "More", isActive: moreOpen) {
                moreOpen.toggle()
            }
            .popover(isPresented: $moreOpen, arrowEdge: .trailing) {
                RailMoreMenu(dismiss: { moreOpen = false })
                    .environmentObject(store)
                    .environmentObject(settings)
            }

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
        }
        .padding(.top, 6)
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
            badge: item == .tasks ? runningTaskCount : nil
        ) {
            RailNavigation.open(item, store: store, settings: settings)
        }
    }

    private func isActive(_ item: RailItem) -> Bool {
        switch item {
        case .terminal: return store.detailMode == .terminal
        case .workspaces: return settings.railPanelOpen
        case .connections: return false
        case .tasks: return store.detailMode == .tasks
        case .automations: return store.detailMode == .automations
        case .skills: return store.detailMode == .skills
        }
    }
}

/// The icon itself, without a button around it — a `Menu` supplies its own.
struct RailIconLabel: View {
    let icon: String
    var isActive = false
    var isHovering = false
    var badge: Int? = nil

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        Image(systemName: icon)
            .font(.system(size: 16))
            .foregroundStyle(isActive ? theme.textPrimary : theme.textSecondary)
            .frame(width: 40, height: 40)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isActive ? theme.surface : theme.surface.opacity(isHovering ? 0.6 : 0))
            )
            .overlay(alignment: .topTrailing) {
                if let badge, badge > 0 {
                    Text(badge > 99 ? "99+" : "\(badge)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(Capsule().fill(Color.accentColor))
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
    var badge: Int? = nil
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            RailIconLabel(icon: icon, isActive: isActive, isHovering: hovering, badge: badge)
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

    var body: some View {
        let theme = Theme.current(for: colorScheme)
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
        .padding(.leading, 10)
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
