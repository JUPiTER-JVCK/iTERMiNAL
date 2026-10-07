import SwiftUI

/// The one button at the top right of the window. It replaces the row of
/// toggles that used to sit there — each bundled tool, the dock, every panel,
/// and Settings — with a menu that lists the same things, plus a way to open a
/// panel in "full view" (across the whole content area) instead of beside the
/// terminal.
struct PanelsMenuButton: View {
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @State private var isOpen = false
    @State private var hovering = false

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        // Something is showing that this menu put there.
        let anythingOpen = store.rightRegionOpen || store.bottomDockOpen
        Button {
            isOpen.toggle()
        } label: {
            Image(systemName: "plus.square")
                .font(.system(size: 14))
                .foregroundStyle(anythingOpen || isOpen ? theme.textPrimary : theme.textSecondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isOpen ? theme.surface : theme.surface.opacity(hovering ? 0.6 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Motion.hover, value: hovering)
        .animation(Motion.hover, value: isOpen)
        .onHover { hovering = $0 }
        .help("Panels and tools")
        .accessibilityLabel("Panels and tools")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            PanelsMenuContent(dismiss: { isOpen = false })
                .environmentObject(store)
                .environmentObject(settings)
        }
    }
}

private struct PanelsMenuContent: View {
    let dismiss: () -> Void

    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        VStack(alignment: .leading, spacing: 2) {
            sectionLabel("Panels", theme: theme)
            ForEach(SidePanel.allCases.filter { !$0.isTool }) { panel in
                panelRow(panel)
            }

            sectionLabel("Tools", theme: theme)
            ForEach(SidePanel.allCases.filter(\.isTool)) { panel in
                panelRow(panel)
            }

            FadedDivider()
                .padding(.vertical, 4)

            PanelsMenuRow(
                icon: "rectangle.bottomthird.inset.filled",
                title: "Terminal dock",
                shortcut: "⌘J",
                isActive: store.bottomDockOpen,
                action: {
                    store.toggleBottomDock()
                    dismiss()
                }
            )

            PanelsMenuRow(
                icon: "gearshape",
                title: "Settings…",
                shortcut: "⌘,",
                action: {
                    dismiss()
                    openSettings()
                }
            )
        }
        .padding(6)
        .frame(width: 270)
    }

    private func sectionLabel(_ title: String, theme: Theme) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    private func panelRow(_ panel: SidePanel) -> some View {
        PanelsMenuRow(
            icon: panel.icon,
            title: panel.title,
            shortcut: panel.shortcutHint,
            isActive: store.rightRegionOpen && store.openPanels.contains(panel),
            onFullView: {
                store.openPanelExpanded(panel)
                dismiss()
            },
            action: {
                store.togglePanel(panel)
                dismiss()
            }
        )
    }
}

/// One row of the menu: a title and shortcut that act on click, and — for a
/// panel — a small button on the right that opens it in full view.
private struct PanelsMenuRow: View {
    let icon: String
    let title: String
    var shortcut: String? = nil
    var isActive = false
    var onFullView: (() -> Void)? = nil
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        HStack(spacing: 4) {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 13))
                        .foregroundStyle(isActive ? theme.textPrimary : theme.textSecondary)
                        .frame(width: 18)
                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.textPrimary)
                    Spacer(minLength: 12)
                    if let shortcut {
                        Text(shortcut)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let onFullView {
                Button(action: onFullView) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0.5)
                .help("Open \(title) in full view")
                .accessibilityLabel("Open \(title) in full view")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isActive ? theme.surface : theme.surface.opacity(hovering ? 0.7 : 0))
        )
        .animation(Motion.hover, value: hovering)
        .onHover { hovering = $0 }
    }
}
