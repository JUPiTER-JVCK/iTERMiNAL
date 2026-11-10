import SwiftUI

/// What the person sees while a panel is being dragged: the panel itself dimmed
/// where it was, the part of the region it would take lit in the accent colour,
/// and a small ghost of its title following the pointer.
///
/// Drawn over the whole region and never hit-tested, so it cannot take the
/// pointer from the header that is being dragged, or from a divider.
struct DockDropOverlay: View {
    @ObservedObject var drag: DockDragModel

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        ZStack(alignment: .topLeading) {
            if let panel = drag.dragging {
                if let source = drag.source {
                    dim(source)
                }
                if let zone = drag.highlight {
                    lit(zone)
                }
                ghost(of: panel, theme: theme)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private func dim(_ area: DockRect) -> some View {
        Rectangle()
            .fill(Color.black.opacity(0.18))
            .frame(width: CGFloat(area.width), height: CGFloat(area.height))
            .offset(x: CGFloat(area.x), y: CGFloat(area.y))
    }

    private func lit(_ area: DockRect) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(settings.accentColor.opacity(0.18))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(settings.accentColor.opacity(0.75), lineWidth: 2)
            )
            .frame(width: CGFloat(area.width), height: CGFloat(area.height))
            .offset(x: CGFloat(area.x), y: CGFloat(area.y))
    }

    private func ghost(of panel: SidePanel, theme: Theme) -> some View {
        HStack(spacing: 6) {
            Image(systemName: panel.icon)
                .font(.system(size: 11))
            Text(panel.title)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(theme.textPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // Picked up, so lit like everything else that floats.
        .elevated(cornerRadius: 8, radius: 10, y: 4, fill: theme.floatingSurface)
        .fixedSize()
        .offset(x: drag.pointer.x + 14, y: drag.pointer.y + 14)
    }
}
