import SwiftUI

/// The trailing region's panels, arranged as `DockLayout` says.
///
/// Every panel is drawn from one flat list keyed by the panel, and placed with
/// a frame and an offset worked out from the arrangement, rather than nested
/// in split views that follow its shape. That is what keeps a panel's view in
/// the same place in SwiftUI's tree while the arrangement changes: moving the
/// browser beside Notes moves its rectangle and does not rebuild it, so its
/// page, and a running tool's terminal, are not re-created for being moved.
///
/// A fill is different: while one panel fills the region the others are taken
/// out of the tree, as switching between tabs always did. Their models, and any
/// tool process, stay alive.
///
/// Branching and arithmetic live in plain functions below rather than inside
/// the view builders, which cannot hold statements.
struct DockRegionView: View {
    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID

    /// The arrangement while a divider is being dragged. The store is written
    /// once, when the drag ends — the same arrangement `liveRightPanelWidth`
    /// makes for the region's own width — so a drag repaints this region and
    /// nothing that watches the store.
    @State private var liveLayout: DockNode?

    /// A panel being dragged by its header. Held in `@State`, which keeps it
    /// without watching it: only the overlay observes it, so the pointer
    /// moving does not redraw the panels.
    @State private var drag = DockDragModel()

    /// Hears every mouse-down while the region is on screen and says which panel
    /// it fell in (see `DockClickFocus`), so a click anywhere in a panel, even in
    /// the web view or a terminal, makes it the one in front.
    @State private var clickFocus = DockClickFocus()

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        GeometryReader { proxy in
            region(in: proxy.size, origin: proxy.frame(in: .global).origin)
                .onAppear { report(proxy.size) }
                .onChange(of: proxy.size) { _, newSize in report(newSize) }
        }
        .background(theme.background)
        // A panel closing mid-drag changes the arrangement under the drag.
        .onChange(of: store.dockLayout) { _, _ in liveLayout = nil }
        .onAppear { clickFocus.start { panel in store.focusPanel(panel) } }
        .onDisappear {
            // No release is reported to a view that has gone, and a drag left
            // standing would keep swallowing Escape. The click monitor goes with
            // the region too, not left listening for panels that are away.
            drag.reset()
            clickFocus.stop()
        }
    }

    /// `origin` is where the region starts in the window. A drag reports the
    /// pointer in the window's coordinates, and everything here is measured
    /// from the region's own corner.
    private func region(in size: CGSize, origin: CGPoint) -> some View {
        let rect = DockRect(x: 0, y: 0, width: Double(size.width), height: Double(size.height))
        let frames = DockLayout.frames(
            of: liveLayout ?? store.effectiveDockLayout,
            in: rect,
            metrics: SidePanel.dockMetrics
        )
        // In declaration order, not layout order, so a panel's place in this
        // list — and with it its identity — does not depend on where it sits.
        let visible = SidePanel.allCases.filter { frames.rect(of: $0.rawValue) != nil }
        let corner = frames.topTrailingModule()
        return ZStack(alignment: .topLeading) {
            ForEach(visible) { panel in
                let placed = placement(of: panel, in: frames)
                DockLeaf(
                    panel: panel,
                    showsStrip: visible.count == 1,
                    carriesRegionControls: panel.rawValue == corner,
                    dragHandlers: dragHandlers(for: panel, frames: frames, region: rect, origin: origin)
                )
                .frame(width: placed.width, height: placed.height)
                .offset(x: placed.minX, y: placed.minY)
                .transition(.opacity)
            }
            // After the panels, so a divider's grab area sits above the web view
            // or terminal beside it.
            ForEach(Array(frames.dividers.enumerated()), id: \.offset) { entry in
                dividerView(entry.element, in: rect)
            }
            // Over everything, and never in the way of the pointer.
            DockDropOverlay(drag: drag)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// What a panel's header calls as it is dragged. The pointer comes in the
    /// window's coordinates and is turned into the region's before anything
    /// else sees it. Letting go over a place a panel can go moves it there.
    private func dragHandlers(
        for panel: SidePanel,
        frames: DockFrames,
        region: DockRect,
        origin: CGPoint
    ) -> DockDragHandlers {
        DockDragHandlers(
            changed: { location in
                drag.update(
                    panel: panel,
                    at: CGPoint(x: location.x - origin.x, y: location.y - origin.y),
                    frames: frames,
                    region: region
                )
            },
            ended: { location in
                let released = CGPoint(x: location.x - origin.x, y: location.y - origin.y)
                if let landing = drag.finish(at: released) {
                    store.dropPanel(landing.panel, onto: landing.target)
                }
            }
        )
    }

    private func placement(of panel: SidePanel, in frames: DockFrames) -> CGRect {
        guard let rect = frames.rect(of: panel.rawValue) else { return .zero }
        return CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    @ViewBuilder
    private func dividerView(_ seam: DockDivider, in rect: DockRect) -> some View {
        let line = CGRect(x: seam.rect.x, y: seam.rect.y, width: seam.rect.width, height: seam.rect.height)
        if let range = seam.leadingRange {
            PanelResizeHandle(
                axis: seam.axis == .horizontal ? .horizontal : .vertical,
                value: seam.leadingExtent,
                range: range,
                resetTo: (seam.leadingExtent + seam.trailingExtent) / 2,
                available: seam.splitExtent,
                onChange: { resize(seam, to: $0, in: rect, commit: false) },
                onCommit: { resize(seam, to: $0, in: rect, commit: true) }
            )
            .frame(width: line.width, height: line.height)
            .offset(x: line.minX, y: line.minY)
        } else {
            // Squeezed below what the two neighbours need: drawn, not draggable.
            Rectangle()
                .fill(Color.secondary.opacity(0.14))
                .frame(width: line.width, height: line.height)
                .offset(x: line.minX, y: line.minY)
        }
    }

    /// A divider moved to give the panel before it `leading` of room. Worked out
    /// from the stored arrangement each time rather than from the one being
    /// shown, so every frame of a drag is measured from where it started.
    private func resize(_ seam: DockDivider, to leading: Double, in rect: DockRect, commit: Bool) {
        let resized = DockLayout.resizing(
            store.dockLayout,
            splitPath: seam.path,
            dividerIndex: seam.index,
            leadingExtent: leading,
            in: rect,
            metrics: SidePanel.dockMetrics
        )
        if commit {
            liveLayout = nil
            store.commitDockLayout(resized)
        } else {
            liveLayout = resized
        }
    }

    /// Told to the store, which uses it to choose a side for a panel opened next.
    /// Written from here rather than from `body`, where changing the store
    /// would publish during a view update.
    private func report(_ size: CGSize) {
        store.dockRegionSize = DockSize(width: Double(size.width), height: Double(size.height))
    }
}

/// What a panel's header reports while it is dragged, with the pointer in the
/// window's coordinates.
private struct DockDragHandlers {
    var changed: (CGPoint) -> Void
    var ended: (CGPoint) -> Void
}

/// One panel in the region: a header and the panel itself.
private struct DockLeaf: View {
    let panel: SidePanel
    /// Only one panel is on screen — it is alone, or it fills the region — so
    /// its header is the strip of tabs the region always had, with a tab for
    /// every open panel. Otherwise each panel has a header of its own.
    let showsStrip: Bool
    /// The panel in the region's top-right corner carries the controls that
    /// belong to the region rather than to a panel.
    let carriesRegionControls: Bool
    /// Used by the header a panel has when it shares the region; the strip of
    /// tabs a lone panel has cannot be dragged anywhere.
    let dragHandlers: DockDragHandlers

    @EnvironmentObject private var store: WorkspaceStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        VStack(spacing: 0) {
            if showsStrip {
                stripHeader(theme: theme)
            } else {
                tileHeader(theme: theme)
            }
            FadedDivider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
        // Fills the panel's rectangle, so a click can be matched to it.
        .background(DockLeafMarker(panel: panel))
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(panel.title)
    }

    @ViewBuilder
    private var content: some View {
        switch panel {
        case .browser:
            BrowserPanelView(model: store.panelBrowserTabs)
        case .files:
            FilePaneView(model: store.panelFiles)
        case .notes:
            NotesPaneView(model: store.panelNotes)
        case .superfile:
            ToolPanelView(tool: .superfile)
        case .btop:
            ToolPanelView(tool: .btop)
        case .http:
            HTTPClientPaneView(model: store.panelHTTPClient)
        }
    }

    /// Every open panel as a tab, this one selected.
    private func stripHeader(theme: Theme) -> some View {
        HStack(spacing: 6) {
            ForEach(store.orderedOpenPanels) { open in
                PanelTabChip(
                    panel: open,
                    isSelected: open == panel,
                    onSelect: { store.focusPanel(open) },
                    onClose: { store.closePanel(open) }
                )
            }

            Spacer(minLength: 0)

            // Nothing to arrange with one panel, so nothing to offer.
            if store.panelsInReadingOrder.count > 1 {
                DockArrangeMenuButton(panel: panel)
            }
            expandButton
            iconButton("xmark", help: "Close panel") { store.closeRightRegion() }
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
    }

    /// This panel's own title, with its menu and close button. The title, and the
    /// room after it, is the handle the panel is dragged by.
    private func tileHeader(theme: Theme) -> some View {
        let isFocused = store.visiblePanel == panel
        return HStack(spacing: 6) {
            dragHandle(theme: theme, isFocused: isFocused)

            DockArrangeMenuButton(panel: panel)
            if carriesRegionControls {
                expandButton
            }
            iconButton("xmark", help: "Close \(panel.title)") { store.closePanel(panel) }
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .contentShape(Rectangle())
        .onTapGesture { store.focusPanel(panel) }
    }

    /// The icon and title, stretched to fill the header up to its buttons. A drag
    /// of a few points picks it up; anything shorter is still a click, which
    /// brings the panel to the front.
    private func dragHandle(theme: Theme, isFocused: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: panel.icon)
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
            Text(panel.title)
                .font(.system(size: 12))
                .foregroundStyle(isFocused ? theme.textPrimary : theme.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .global)
                .onChanged { dragHandlers.changed($0.location) }
                .onEnded { dragHandlers.ended($0.location) }
        )
        .help("Drag to move \(panel.title)")
    }

    private var expandButton: some View {
        iconButton(
            store.rightPanelExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
            help: store.rightPanelExpanded ? "Collapse panel" : "Expand panel"
        ) { store.toggleRightPanelExpanded() }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
