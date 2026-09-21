import SwiftUI
import AppKit

/// A floating, self-contained terminal.
///
/// It owns its own shell rather than typing into whichever pane happens to
/// have focus, so nothing entered here can land in the window behind it — the
/// transcript below the input is that shell, not a copy of anything else.
///
/// It can be dragged anywhere in the content area and collapsed to a pill;
/// both survive relaunch.
struct ComposerBar: View {
    /// The surface this card floats over. Its offset is clamped against these
    /// bounds, so shrinking the window can never strand the card off-screen.
    let bounds: CGSize

    @EnvironmentObject private var store: WorkspaceStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.colorScheme) private var colorScheme

    @State private var text = ""
    @StateObject private var ai = ComposerAIController()
    @State private var showActions = false
    /// Live drag delta, folded into the persisted offset when the drag ends.
    @State private var dragDelta: CGSize = .zero
    /// Where arrow-key recall currently sits in the history, and the
    /// half-typed line it interrupted.
    @State private var historyIndex: Int?
    @State private var draft = ""
    /// The card's rendered size, measured so the drag clamp can keep the whole
    /// card on screen rather than guessing from the container alone.
    @State private var cardSize: CGSize = .zero
    /// Darkens the grip while a drag is in flight, so it is obvious the card
    /// has been picked up.
    @State private var dragging = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        Group {
            if settings.composerCollapsed {
                collapsedPill
            } else {
                expandedCard
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: ComposerSizeKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(ComposerSizeKey.self) { size in
            guard size != cardSize else { return }
            cardSize = size
            clampToBounds()
        }
        .offset(
            x: settings.composerOffsetX + dragDelta.width,
            y: settings.composerOffsetY + dragDelta.height
        )
        .animation(Motion.panel, value: settings.composerCollapsed)
        .onChange(of: bounds) { _, _ in clampToBounds() }
        .onChange(of: store.composerFocusRequest) { _, _ in inputFocused = true }
        // Hiding the composer mid-request used to leave the call running with
        // nothing left to show its answer.
        .onDisappear { ai.cancel() }
    }

    /// How far the card may travel from home while staying fully on the
    /// surface, with a margin so it never sits flush against an edge.
    ///
    /// This used to guess from the container alone, which let a wide card hang
    /// off the side — the limits have to account for how big the card actually
    /// is. Home is horizontally centred and bottom-aligned, so the horizontal
    /// room is the slack either side and the vertical room is upward only.
    private var offsetLimits: (x: ClosedRange<Double>, y: ClosedRange<Double>) {
        let margin: Double = 12
        let horizontal = max(0, (bounds.width - cardSize.width) / 2 - margin)
        let vertical = max(0, bounds.height - cardSize.height - margin * 2)
        return (-horizontal...horizontal, -vertical...0)
    }

    /// Transcript height that still leaves room for the rest of the card.
    ///
    /// The stored preference is a wish, not a guarantee: the window can be as
    /// short as 560pt, and a transcript that tall would push the input and its
    /// controls off the bottom — leaving the composer visible but unusable.
    /// Everything above and below the transcript needs roughly this much.
    private var maxTranscriptHeight: Double {
        let chrome: Double = 210
        return max(100, bounds.height - chrome)
    }

    private var effectiveTranscriptHeight: Double {
        min(settings.composerTranscriptHeight, maxTranscriptHeight)
    }

    /// The card's fill, honouring the opacity and vibrancy settings.
    ///
    /// Vibrancy is expressed by letting the fill go translucent so the terminal
    /// shows through, rather than by adding an NSVisualEffectView: the card
    /// floats over app content, not over the desktop, so a material would
    /// sample the wrong thing.
    private func cardFill(_ theme: Theme) -> Color {
        let base = theme.floatingSurface
        let opacity = settings.composerVibrancy
            ? min(settings.composerOpacity, 0.85)
            : settings.composerOpacity
        return base.opacity(opacity)
    }

    /// Re-anchors the card when the window shrinks under it. Writes only on a
    /// real change — this runs on every frame of a live window resize.
    private func clampToBounds() {
        let limits = offsetLimits
        let x = settings.composerOffsetX.clamped(to: limits.x)
        let y = settings.composerOffsetY.clamped(to: limits.y)
        if x != settings.composerOffsetX { settings.composerOffsetX = x }
        if y != settings.composerOffsetY { settings.composerOffsetY = y }
    }

    // MARK: Collapsed

    private var collapsedPill: some View {
        let theme = Theme.current(for: colorScheme)
        return Button {
            settings.composerCollapsed = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                Text("Run anything")
                    .font(.system(size: 12))
                if store.composerHasRun {
                    // A quiet reminder that a shell is still alive down here.
                    Circle()
                        .fill(settings.accentColor)
                        .frame(width: 5, height: 5)
                }
            }
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .elevated(cornerRadius: 16, radius: 14, y: 4, fill: cardFill(theme))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show the composer")
    }

    // MARK: Expanded

    private var expandedCard: some View {
        let theme = Theme.current(for: colorScheme)
        return VStack(spacing: 8) {
            if let banner = ai.banner {
                // A dismiss (and, while a request is in flight, a stop) —
                // without one the banner sat above the input until the user
                // happened to run a non-`@ai` command, and a hung endpoint
                // left a spinner with nothing to cancel it.
                HStack(alignment: .top, spacing: 6) {
                    ComposerAIBannerView(banner: banner, theme: theme)
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(Motion.banner) {
                            ai.cancel()
                            ai.clearBanner()
                        }
                    } label: {
                        Image(systemName: banner == .thinking ? "stop.circle" : "xmark")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .help(banner == .thinking ? "Stop the request" : "Dismiss")
                }
                .transition(Motion.bannerTransition)
            }

            VStack(alignment: .leading, spacing: 10) {
                gripBar(theme: theme)
                ContextChipRow()

                if store.composerHasRun, let session = store.composerSession {
                    // The composer's own shell. Identity is tied to the
                    // session so a reset swaps the view rather than reusing
                    // a container still hosting the old terminal.
                    TerminalHostView(session: session)
                        .id(session.id)
                        .frame(height: effectiveTranscriptHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(theme.surfaceBorder)
                        )

                    TranscriptResizeHandle(
                        height: $settings.composerTranscriptHeight,
                        maxHeight: maxTranscriptHeight,
                        theme: theme
                    )
                }

                TextField("Run anything", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .onSubmit(send)
                    .onKeyPress(.upArrow) { recallEarlier() }
                    .onKeyPress(.downArrow) { recallLater() }

                HStack(spacing: 8) {
                    // A popover rather than a Menu: the reference app groups
                    // these under headings and gives each row a line of
                    // explanation, neither of which a Menu can render.
                    Button {
                        showActions = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Add a terminal, split, or panel")
                    .popover(isPresented: $showActions, arrowEdge: .top) {
                        ComposerActionsPopover(isPresented: $showActions)
                            .environmentObject(store)
                            .environmentObject(settings)
                    }

                    Spacer()

                    SessionChip()

                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                            .frame(width: 28, height: 28)
                            .background(
                                Circle().fill(
                                    trimmedText.isEmpty
                                        ? Color.secondary.opacity(0.35)
                                        : (colorScheme == .dark ? Color.white : Color.black)
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(trimmedText.isEmpty)
                }
            }
            .padding(14)
            // A distinctly lighter surface and a deeper shadow, so this reads
            // as floating above the terminal rather than painted onto it.
            .elevated(cornerRadius: 22, radius: 22, y: 8, fill: cardFill(theme))
        }
    }

    /// The card's drag handle: a grip in the middle, window controls on the
    /// right.
    ///
    /// Deliberately its own row rather than sharing one with the context
    /// chips. Those chips are menus, and with them in the handle the only
    /// actually grabbable part of it was the gaps between them.
    private func gripBar(theme: Theme) -> some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)

            Capsule()
                .fill(theme.textSecondary.opacity(dragging ? 0.5 : 0.28))
                .frame(width: 40, height: 4)

            Spacer(minLength: 0)
        }
        // Taller than it looks: the capsule is 4pt, but the grabbable strip
        // around it needs to be big enough to hit without aiming.
        .frame(height: 24)
        .overlay(alignment: .trailing) { headerControls(theme: theme) }
        .contentShape(Rectangle())
        .onHover { NSCursor.openHand.set(); if !$0 { NSCursor.arrow.set() } }
        .gesture(
            // The default 10pt threshold swallowed short drags, which is what
            // made the card feel stuck — it only moved once you had committed
            // to a big gesture.
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    // Clamp while dragging, not only on release. Assigning the
                    // raw translation let the card follow the pointer clean off
                    // the surface and then snap back when let go, which is not
                    // what "stays inside" should feel like.
                    let limits = offsetLimits
                    let x = (settings.composerOffsetX + value.translation.width)
                        .clamped(to: limits.x)
                    let y = (settings.composerOffsetY + value.translation.height)
                        .clamped(to: limits.y)
                    dragDelta = CGSize(
                        width: x - settings.composerOffsetX,
                        height: y - settings.composerOffsetY
                    )
                    if !dragging { dragging = true }
                }
                .onEnded { value in
                    let limits = offsetLimits
                    settings.composerOffsetX = (settings.composerOffsetX + value.translation.width)
                        .clamped(to: limits.x)
                    settings.composerOffsetY = (settings.composerOffsetY + value.translation.height)
                        .clamped(to: limits.y)
                    dragDelta = .zero
                    dragging = false
                }
        )
        // Double-click the handle to put it back where it started.
        .onTapGesture(count: 2) {
            withAnimation(Motion.panel) {
                settings.composerOffsetX = 0
                settings.composerOffsetY = 0
            }
        }
        .help("Drag to move the composer · double-click to reset")
    }

    private func headerControls(theme: Theme) -> some View {
        HStack(spacing: 6) {
            if store.composerHasRun {
                Button {
                    store.resetComposerSession()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Restart this shell and clear the transcript")
            }

            Button {
                settings.composerCollapsed = true
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Minimise the composer")
        }
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send() {
        let command = trimmedText
        guard !command.isEmpty else { return }
        if command.lowercased().hasPrefix("@ai") {
            // A bare `@ai` is a typo, not a prompt. Without this it reached
            // submit with an empty string and spent a real chat-completions
            // call on whatever the model made of the context alone.
            let prompt = ComposerAIController.stripAIPrefix(command)
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            store.recordComposerCommand(command)
            text = ""
            historyIndex = nil
            draft = ""
            withAnimation(Motion.banner) {
                ai.submit(prompt: prompt, store: store, settings: settings)
            }
            return
        }
        ai.cancel()
        ai.clearBanner()
        // Its own shell — never the pane behind it.
        withAnimation(Motion.panel) {
            store.sendToComposer(command + "\n")
        }
        text = ""
        historyIndex = nil
        draft = ""
    }

    // MARK: Arrow-key recall

    /// Walks back through commands this composer has run, the way a shell
    /// does. Multi-line input is left alone: there the arrows have to move
    /// the caret, and stealing them would make the field unusable.
    private func recallEarlier() -> KeyPress.Result {
        let history = store.composerHistory
        guard !text.contains("\n"), !history.isEmpty else { return .ignored }
        if let historyIndex {
            guard historyIndex > 0 else { return .handled }
            self.historyIndex = historyIndex - 1
            text = history[historyIndex - 1]
        } else {
            // Remember the half-typed line so walking back down restores it.
            draft = text
            historyIndex = history.count - 1
            text = history[history.count - 1]
        }
        return .handled
    }

    private func recallLater() -> KeyPress.Result {
        let history = store.composerHistory
        guard !text.contains("\n"), let historyIndex else { return .ignored }
        if historyIndex + 1 < history.count {
            self.historyIndex = historyIndex + 1
            text = history[historyIndex + 1]
        } else {
            self.historyIndex = nil
            text = draft
        }
        return .handled
    }
}
