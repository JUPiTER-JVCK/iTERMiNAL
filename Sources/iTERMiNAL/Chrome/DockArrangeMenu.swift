import SwiftUI

/// The small button in a panel's header that opens its Move and Fill menu.
///
/// Move sends the panel to one side of the whole region; Fill and arrange sets
/// how it sits with the others — arranged side by side, filling the region, or
/// filling the window. Dragging a header to re-dock it is the other way to
/// arrange panels; this menu is the one that works from the keyboard and with
/// VoiceOver.
struct DockArrangeMenuButton: View {
    let panel: SidePanel

    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var isOpen = false
    @State private var hovering = false

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        Button {
            isOpen.toggle()
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isOpen ? theme.surface : theme.surface.opacity(hovering ? 0.6 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Motion.hover, value: hovering)
        .animation(Motion.hover, value: isOpen)
        .onHover { hovering = $0 }
        .help("Move and arrange")
        .accessibilityLabel("Move and arrange \(panel.title)")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            DockArrangeMenuContent(panel: panel, dismiss: { isOpen = false })
                .environmentObject(store)
        }
    }
}

private struct DockArrangeMenuContent: View {
    let panel: SidePanel
    let dismiss: () -> Void

    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        let alone = store.panelsInReadingOrder.count < 2
        let current = store.arrangement(of: panel)
        VStack(alignment: .leading, spacing: 4) {
            sectionLabel("Move", theme: theme)
            HStack(spacing: 6) {
                ForEach(DockEdge.allCases, id: \.self) { edge in
                    ArrangeIconButton(
                        symbol: moveSymbol(for: edge),
                        label: moveLabel(for: edge),
                        isSelected: false,
                        isEnabled: !alone
                    ) {
                        store.movePanel(panel, toRegionEdge: edge)
                        dismiss()
                    }
                }
            }
            .padding(.horizontal, 6)

            sectionLabel("Fill and arrange", theme: theme)
            HStack(spacing: 6) {
                ArrangeIconButton(
                    symbol: "square.grid.2x2",
                    label: "Arrange panels side by side",
                    isSelected: current == .tiled,
                    isEnabled: true
                ) {
                    store.setArrangement(.tiled, for: panel)
                    dismiss()
                }
                ArrangeIconButton(
                    symbol: "rectangle.inset.filled",
                    label: "Fill the panel region",
                    isSelected: current == .fillRegion,
                    isEnabled: true
                ) {
                    store.setArrangement(.fillRegion, for: panel)
                    dismiss()
                }
                ArrangeIconButton(
                    symbol: "arrow.up.left.and.arrow.down.right",
                    label: "Fill the window",
                    isSelected: current == .fillWindow,
                    isEnabled: true
                ) {
                    store.setArrangement(.fillWindow, for: panel)
                    dismiss()
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 4)
        }
        .padding(6)
        .frame(width: 236)
    }

    private func sectionLabel(_ title: String, theme: Theme) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    private func moveSymbol(for edge: DockEdge) -> String {
        switch edge {
        case .left: return "rectangle.lefthalf.inset.filled"
        case .right: return "rectangle.righthalf.inset.filled"
        case .top: return "rectangle.tophalf.inset.filled"
        case .bottom: return "rectangle.bottomhalf.inset.filled"
        }
    }

    private func moveLabel(for edge: DockEdge) -> String {
        switch edge {
        case .left: return "Move to the left edge"
        case .right: return "Move to the right edge"
        case .top: return "Move to the top edge"
        case .bottom: return "Move to the bottom edge"
        }
    }
}

/// One icon in the menu: a rounded button that lights when it is the current
/// choice, and dims when it does nothing.
private struct ArrangeIconButton: View {
    let symbol: String
    let label: String
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = Theme.current(for: colorScheme)
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? theme.surface : theme.surface.opacity(hovering && isEnabled ? 0.7 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .animation(Motion.hover, value: hovering)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
