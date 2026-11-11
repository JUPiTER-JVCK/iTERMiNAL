import SwiftUI

/// Renders a tab's layout tree: splits become a row or column of panes, leaves
/// host a terminal, browser, file, or HTTP client pane.
///
/// A tab with a single pane draws no card and no focus mark — there is
/// nothing to disambiguate, and the reference app keeps its content flush to
/// the window. Once the tab is split, each pane is a rounded card of its own
/// (see `PaneCard`), and the same gap runs round the outside of the tree and
/// between every pair of cards (see `PaneSplitView`).
struct PaneTreeView: View {
    @ObservedObject var node: PaneNode
    /// False once this node sits inside a split.
    var isSolo = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID

    var body: some View {
        if isSolo, case .split = node.content {
            // The outermost split owns the margin round the whole tree, the
            // same width as the gaps between its cards, on the same surface
            // as the content card around it: the gaps are that surface
            // showing between panes, not a second frame inside the first.
            tree
                .padding(PaneCard.gap)
                .background(Theme.current(for: colorScheme, themeID: appThemeID).background)
        } else {
            tree
        }
    }

    @ViewBuilder
    private var tree: some View {
        switch node.content {
        case .terminal(let session):
            TerminalPaneView(session: session, isSolo: isSolo)
        case .browser(let model):
            BrowserPaneView(model: model)
        case .files(let model):
            FilePaneView(model: model)
        case .http(let model):
            HTTPClientPaneView(model: model)
        case .split(let direction, let children):
            PaneSplitView(direction: direction, children: children)
        }
    }
}

/// Panes in a row or a column, with one gap of `PaneCard.gap` between each
/// pair and a handle in it to drag.
///
/// This replaces `HSplitView`/`VSplitView`. Those draw their own divider line
/// in the middle of whatever space is between the panes, so cards set 6pt
/// apart had a dark rule down the gap, and there was no way to take it out or
/// to make the margin round the outside match the gap between panes. Here the
/// gap is plain surface, the handle in it is invisible until the pointer is
/// over it, and the sizes are the split's own.
///
/// Sizes are fractions of the room left after the gaps, kept in state: a split
/// starts with equal shares, and a drag moves the boundary between two
/// neighbours and no one else's. They are not saved with the layout, as the
/// system's were not.
struct PaneSplitView: View {
    let direction: SplitDirection
    let children: [PaneNode]

    /// Fractions of the usable length, in order. Ignored (equal shares used)
    /// whenever the number of panes is not the number held here — a split
    /// added to or closed.
    @State private var weights: [CGFloat] = []
    /// The shares when the drag in flight began; a drag's translation is
    /// measured from there, not from the previous event.
    @State private var dragStart: [CGFloat]?

    private var horizontal: Bool { direction == .horizontal }

    /// The smallest a pane may be dragged to along the split.
    private var minimum: CGFloat { horizontal ? 160 : 100 }

    private var shares: [CGFloat] {
        weights.count == children.count
            ? weights
            : Array(repeating: 1 / CGFloat(max(children.count, 1)), count: children.count)
    }

    var body: some View {
        GeometryReader { proxy in
            let total = horizontal ? proxy.size.width : proxy.size.height
            let gaps = PaneCard.gap * CGFloat(max(children.count - 1, 0))
            let usable = max(total - gaps, 1)
            let shares = self.shares
            let layout = horizontal
                ? AnyLayout(HStackLayout(spacing: 0))
                : AnyLayout(VStackLayout(spacing: 0))
            layout {
                ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                    PaneTreeView(node: child, isSolo: false)
                        .modifier(PaneCard(node: child))
                        .frame(
                            width: horizontal ? usable * shares[index] : nil,
                            height: horizontal ? nil : usable * shares[index]
                        )
                    if index < children.count - 1 {
                        PaneSplitHandle(horizontal: horizontal) {
                            drag(at: index, by: $0, usable: usable, active: true)
                        } onEnd: {
                            drag(at: index, by: $0, usable: usable, active: false)
                        } onReset: {
                            withAnimation(Motion.panel) { weights = [] }
                        }
                        .frame(
                            width: horizontal ? PaneCard.gap : nil,
                            height: horizontal ? nil : PaneCard.gap
                        )
                        // Over the panes either side, which the handle's wider
                        // hit area reaches into.
                        .zIndex(1)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        // A seam can vanish mid-drag — its pane closed by a shortcut — and then
        // the end never comes. Left set, every terminal would wait out the
        // catch-up delay on each resize from then on.
        .onDisappear {
            if dragStart != nil {
                dragStart = nil
                SeamDrag.end()
            }
        }
    }

    /// Moves the boundary after pane `index` by `delta` points from where the
    /// drag began, taking from one neighbour and giving to the other.
    private func drag(at index: Int, by delta: CGFloat, usable: CGFloat, active: Bool) {
        if dragStart == nil {
            dragStart = shares
            // Terminals hold their size until the drag ends — see SeamDrag.
            SeamDrag.begin()
        }
        guard let start = dragStart, start.count == children.count,
              start.indices.contains(index + 1) else { return }
        let pair = (start[index] + start[index + 1]) * usable
        let floor = min(minimum, pair / 2)
        let first = min(max(start[index] * usable + delta, floor), pair - floor)
        var next = start
        next[index] = first / usable
        next[index + 1] = (pair - first) / usable
        weights = next
        if !active {
            dragStart = nil
            SeamDrag.end()
        }
    }
}

/// The strip of gap between two panes that is dragged to resize them. Nothing
/// is drawn until the pointer is over it, then a short rounded bar in the
/// middle of the gap, in the accent — not a line the length of the pane.
private struct PaneSplitHandle: View {
    let horizontal: Bool
    let onChange: (CGFloat) -> Void
    let onEnd: (CGFloat) -> Void
    let onReset: () -> Void

    @State private var hovering = false
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Color.clear
            .overlay {
                Capsule()
                    .fill(settings.accentColor.opacity(hovering ? 0.7 : 0))
                    .frame(
                        width: horizontal ? 3 : 36,
                        height: horizontal ? 36 : 3
                    )
                    .animation(Motion.hover, value: hovering)
                    .allowsHitTesting(false)
            }
            // The gap is 6pt, which is hard to land on, so the grab area runs a
            // few points into the panes either side without moving anything.
            .overlay {
                Color.clear
                    .frame(
                        width: horizontal ? PaneCard.gap + 8 : nil,
                        height: horizontal ? nil : PaneCard.gap + 8
                    )
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hovering = inside
                        // set() rather than push()/pop(): the view can vanish
                        // mid-hover when a pane closes, which would strand a
                        // resize cursor on the stack forever.
                        if inside {
                            (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
                        } else {
                            NSCursor.arrow.set()
                        }
                    }
                    .gesture(
                        // Global, not local: the handle moves with the drag, and
                        // a translation measured in its own space would chase it.
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { onChange(horizontal ? $0.translation.width : $0.translation.height) }
                            .onEnded { onEnd(horizontal ? $0.translation.width : $0.translation.height) }
                    )
                    .onTapGesture(count: 2, perform: onReset)
            }
            .help("Drag to resize · double-click for equal sizes")
    }
}

/// What makes a pane inside a split its own card: rounded corners and a
/// hairline edge. The gap round it is not its own — `PaneTreeView` and
/// `PaneSplitView` leave it, equal on every side.
///
/// Applied to leaves only. A nested split is not a card — its children are.
struct PaneCard: ViewModifier {
    @ObservedObject var node: PaneNode
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID

    /// The gap between two panes, and between a pane and the edge of the
    /// content card round them.
    static let gap: CGFloat = 8

    /// Concentric with the content card, whose corners are `frameRadius`: the
    /// pane's edge is `gap` inside the card's, so its corner is that much
    /// tighter, or the space between the two curves would be wider at the
    /// corner than along the sides.
    static func cornerRadius(frameRadius: Double) -> CGFloat {
        max(CGFloat(frameRadius) - gap, 6)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if case .split = node.content {
            content
        } else {
            let theme = Theme.current(for: colorScheme, themeID: appThemeID)
            let shape = RoundedRectangle(
                cornerRadius: Self.cornerRadius(frameRadius: settings.frameCornerRadius),
                style: .continuous
            )
            content
                .clipShape(shape)
                .overlay(shape.strokeBorder(theme.surfaceBorder).allowsHitTesting(false))
        }
    }
}

/// Terminal leaf. A lone pane renders flush; inside a split, the one the
/// keyboard drives is marked by a bar along its top edge and the others sit
/// back a little.
struct TerminalPaneView: View {
    @ObservedObject var session: TerminalSession
    var isSolo = true
    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appThemeID) private var appThemeID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let theme = Theme.current(for: colorScheme, themeID: appThemeID)
        let isFocused = store.focusedSessionID == session.id
        // Same reasoning as the dock: tie the hosted view's identity to the
        // session so a restructured tree can never leave a stale terminal.
        let host = TerminalHostView(session: session)
            .id(session.id)
            .overlay(alignment: .top) {
                // The container carries the animation, so the banner's removal
                // is animated too: a modifier on the banner itself is gone by
                // the time it would run.
                VStack(spacing: 0) {
                    if let note = session.statusNote {
                        SessionStatusBanner(session: session, note: note, theme: theme)
                            .transition(Motion.bannerTransition(reduceMotion: reduceMotion))
                    }
                }
                .animation(Motion.banner, value: session.statusNote)
            }

        if isSolo {
            host
        } else {
            // A bar along the focused pane's top edge, clipped to the card's
            // corners by `PaneCard`, with the other panes dimmed slightly: the
            // mark says which pane has the keyboard, the dimming says it
            // before you have looked for the mark.
            //
            // The look is the person's to choose (Settings → Terminal → Split
            // panes); the bar stays the default.
            let style = settings.splitFocusStyle
            let markColor = settings.splitFocusColor.hex.map { Color(nsColor: NSColor(hex: $0)) }
                ?? settings.accentColor
            host
                .overlay {
                    if style == .standard {
                        Color.black
                            .opacity(isFocused ? 0 : 0.1)
                            .allowsHitTesting(false)
                            .animation(Motion.disclosure, value: isFocused)
                    }
                }
                .overlay(alignment: .top) {
                    if style == .standard {
                        Rectangle()
                            .fill(isFocused ? markColor : Color.clear)
                            .frame(height: 2)
                            .allowsHitTesting(false)
                            .animation(Motion.disclosure, value: isFocused)
                    }
                }
                .overlay {
                    if style == .outline {
                        // The card's own shape, so the line follows its corners.
                        RoundedRectangle(
                            cornerRadius: PaneCard.cornerRadius(frameRadius: settings.frameCornerRadius),
                            style: .continuous
                        )
                            .strokeBorder(isFocused ? markColor : Color.clear, lineWidth: 2)
                            .allowsHitTesting(false)
                            .animation(Motion.disclosure, value: isFocused)
                    }
                }
                .overlay {
                    if style == .dimOthers {
                        Color.black
                            .opacity(isFocused ? 0 : 0.3)
                            .allowsHitTesting(false)
                            .animation(Motion.disclosure, value: isFocused)
                    }
                }
        }
    }
}

/// Shown when a session has exited, dropped, or failed to launch, with the
/// one action that matters: try again.
private struct SessionStatusBanner: View {
    @ObservedObject var session: TerminalSession
    let note: String
    let theme: Theme
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 11))
            message
                .font(.system(size: 11))
                .lineLimit(2)
            Spacer(minLength: 8)
            if session.localNetworkBlocked {
                Button("Local Network Settings…") {
                    LocalNetworkPermission.openSettings()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
            }
            if let problem = session.endProblem {
                ForEach(TabConnectionProblem.actions(for: problem), id: \.title) { action in
                    Button(action.title) { perform(action) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            if session.reconnectPlan != nil {
                Button("Stop") {
                    session.stopAutoReconnect()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
            }
            Button(session.reconnectPlan != nil ? "Reconnect Now" : (session.isRemote ? "Reconnect" : "Restart")) {
                session.reconnect()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(theme.textPrimary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(theme.surface.opacity(0.96))
        .overlay(alignment: .bottom) { FadedDivider() }
    }

    /// What a button from `TabConnectionProblem` does. A command is typed into
    /// a new tab and left for Return, as the file browser's are.
    private func perform(_ action: RemoteAction) {
        switch action {
        case .runInLocalTerminal(_, let command):
            WorkspaceStore.shared.newTab(typing: command)
        case .editConnection:
            SettingsNavigator.request(.connections)
            openSettings()
        case .openLocalNetworkSettings:
            LocalNetworkPermission.openSettings()
        case .tryAgain:
            session.reconnect()
        case .signInInTerminal:
            // Not offered on a tab, which is already a terminal signed in to it.
            break
        }
    }

    /// While a reconnect is waiting, the count down to it; otherwise what
    /// happened to the session, and why it was not started again if that is
    /// worth saying.
    @ViewBuilder
    private var message: some View {
        if let plan = session.reconnectPlan, plan.waitingForNetwork {
            Text("Connection lost, and this Mac has no network. Try \(plan.attempt) of \(plan.total) starts when it is back.")
        } else if let plan = session.reconnectPlan {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(plan.at.timeIntervalSince(context.date).rounded(.up)))
                Text("Connection lost. Reconnecting in \(seconds) s — try \(plan.attempt) of \(plan.total).")
            }
        } else if let error = session.launchError {
            Text(error)
        } else if let problem = session.endProblem {
            Text("\(problem.title). \(TabConnectionProblem.summary(for: problem))")
        } else if let why = session.reconnectNote {
            Text("Session \(note). \(why)")
        } else {
            Text("Session \(note).")
        }
    }
}
