import AppKit
import SwiftTerm

/// LocalProcessTerminalView subclass that reports what the app needs to know.
///
/// Only methods SwiftTerm declares `open` are overridden — `send`,
/// `rangeChanged`, `requestOpenLink`, and `bell` — plus AppKit's own
/// `menu(for:)`, which SwiftTerm leaves alone. Other delegate methods on
/// this class (`sizeChanged`, `setTerminalTitle`, and `becomeFirstResponder`
/// on the view) are `public` but not `open`, so they cannot be overridden from
/// outside the module; those signals come through `processDelegate` and a
/// mouse monitor instead. OSC 9 / 777 are hooked via `registerOscHandler`.
final class InstrumentedTerminalView: LocalProcessTerminalView {
    /// How see-through the person asked the background to be. SwiftTerm's own
    /// `backgroundOpacity` is held at 0 while this is below 1, and the
    /// container paints the whole area — padding and terminal alike — in one
    /// pass, so the two can never be tinted differently.
    var requestedBackgroundOpacity: CGFloat = 1

    var onActivity: (() -> Void)?
    var onInput: (() -> Void)?
    var onLink: ((String) -> Void)?
    /// Bell / OSC 9 / OSC 777 from the PTY stream.
    var onAttention: ((TerminalAttention) -> Void)?
    /// Reports a finished line, for naming the tab after what it is doing
    /// rather than after its directory, with what was true as Return was
    /// pressed. That is what says whether the shell was reading it, or a
    /// program it started — sudo asking for a password, say: see
    /// `EnteredLine`.
    var onCommand: ((String, EnteredLine.Moment) -> Void)?
    /// A mark from a shell started with the integration hooks (OSC 633): a prompt
    /// is about to be drawn, a command starts — and, signed with
    /// `shellIntegrationNonce`, what it is — or a command ended with a status.
    /// Called on whichever queue SwiftTerm parses on.
    var onShellMark: ((ShellIntegration.Mark) -> Void)?
    /// The code this launch's hooks sign command lines with; nil for a shell
    /// started without them, whose output then cannot name a command at all.
    /// Set as each process is started, before it can print anything.
    var shellIntegrationNonce: String?
    /// What the app adds to the right-click menu beneath the editing items —
    /// splitting the pane, opening a tab. Asked each time the menu opens, so it
    /// can reflect the moment.
    var contextMenuActions: (() -> [TerminalMenuAction])?
    /// What the app offers for the text selected here, asked each time the menu
    /// opens, with that text. Not asked when nothing is selected.
    var selectionActions: ((String) -> [TerminalMenuAction])?

    /// What a drop onto this terminal may carry. Nothing until the session
    /// says otherwise; see `TerminalDrop`.
    var dropPolicy: TerminalDrop.Policy = .nothing

    /// Whether the drag now over this view would be accepted. Worked out once,
    /// as it enters, because AppKit asks again with every mouse move and text
    /// can be long.
    private var dragIsAcceptable = false

    /// What has been typed since the last Enter, rebuilt from the keystrokes
    /// (see `EnteredLine.LineBuffer`).
    private var lineBuffer = EnteredLine.LineBuffer()
    /// Called after each keystroke with `typedLine`, for the quick reference
    /// strip's "a command is being typed". Kept in memory: nothing here is
    /// written anywhere.
    var onLineEdited: ((String?) -> Void)?

    /// A line the keys alone could not follow — Tab completed a word, ↑ brought
    /// one back — read off the screen as Return was pressed, with the moment
    /// it was entered at. For the quick reference's record of what was run,
    /// never for a tab's name: those keep to lines the keys spell out, or that
    /// the shell's own hooks report (`ShellIntegration.Mark.commandLine`).
    var onEnteredFromScreen: ((String, EnteredLine.Moment) -> Void)?

    /// Where the line being typed began on the screen: the cursor's column,
    /// and its row counted from the top of the scrollback, as the first key of
    /// the line was pressed — just past the prompt. Nil until then.
    private var lineStart: (column: Int, row: Int)?

    /// What has been typed since the last Enter, as far as it can be known.
    /// While the keys spell it out, from them. Once Tab or ↑ has changed it
    /// where the keys cannot follow, from the screen, between where it began
    /// and the cursor — which is where a completed word or a recalled command
    /// is drawn. Nil while nothing is typed, and when neither can say.
    var typedLine: String? {
        if let text = lineBuffer.text { return text }
        guard lineBuffer.isUntracked, let screen = lineOnScreen() else { return nil }
        return EnteredLine.lineOnScreen(screen, typedBefore: lineBuffer.typedBeforeUntracked)
    }

    /// The keystroke path — `super` writes the bytes to the PTY, so it must
    /// always run, and nothing here may stop it.
    ///
    /// Who is reading the terminal is asked before it does, when the bytes
    /// hold a Return: once the shell has the Return, the program the line
    /// starts can take the terminal before the line is judged. Every other
    /// keystroke asks nothing.
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let hasReturn = data.contains(where: { $0 == 0x0D || $0 == 0x0A })
        let moment = hasReturn ? momentAtReturn() : nil
        // Before the key reaches the shell, the cursor is where the line
        // starts, or still where it was.
        if lineBuffer.isAtLineStart { lineStart = cursorOnScreen() }
        let untrackedLine = hasReturn && lineBuffer.isUntracked ? typedLine : nil
        super.send(source: source, data: data)
        for entered in lineBuffer.feed(data, moment: moment) {
            onCommand?(entered.line, entered.moment)
        }
        if let untrackedLine, let moment { onEnteredFromScreen?(untrackedLine, moment) }
        if lineBuffer.isAtLineStart { lineStart = nil }
        onInput?()
        if let onLineEdited { onLineEdited(typedLine) }
    }

    /// The cursor, with its row counted from the top of the scrollback — when
    /// that can be told: on the normal screen, scrolled to the bottom, where
    /// the rows on view are the newest.
    private func cursorOnScreen() -> (column: Int, row: Int)? {
        let terminal = getTerminal()
        guard !terminal.isCurrentBufferAlternate, isScrolledToBottom else { return nil }
        let cursor = terminal.getCursorLocation()
        return (cursor.x, terminal.getTopVisibleRow() + cursor.y)
    }

    private var isScrolledToBottom: Bool {
        !canScroll || scrollPosition >= 0.999
    }

    /// The text between where the line began and the cursor, across the rows
    /// a long line wraps onto — at most four, beyond which it is something
    /// else on the screen.
    private func lineOnScreen() -> String? {
        guard let start = lineStart, let cursor = cursorOnScreen() else { return nil }
        guard cursor.row >= start.row, cursor.row - start.row < 4 else { return nil }
        let terminal = getTerminal()
        let top = terminal.getTopVisibleRow()
        var text = ""
        for row in start.row...cursor.row {
            guard let line = terminal.getLine(row: row - top) else { return nil }
            let from = row == start.row ? start.column : 0
            let to = row == cursor.row ? cursor.column : -1
            if to != -1, to <= from { continue }
            text += line.translateToString(startCol: from, endCol: to)
        }
        return text
    }

    /// What is true of the terminal now, for a Return about to be passed on.
    private func momentAtReturn() -> EnteredLine.Moment {
        EnteredLine.Moment(
            shellInFront: TerminalReader.shellIsInFront(shellPID: process?.shellPid ?? 0),
            hiddenInput: TerminalReader.isReadingHiddenLine(pty: process?.childfd ?? -1),
            alternateScreen: getTerminal().isCurrentBufferAlternate
        )
    }

    /// Fires whenever the terminal repaints a row range: the closest thing
    /// SwiftTerm offers to an "output happened" signal without a byte hook.
    override func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        super.rangeChanged(source: source, startY: startY, endY: endY)
        onActivity?()
    }

    /// Clicking a link opens it in the app's own browser pane when a handler
    /// is installed, instead of bouncing the user out to Safari.
    override func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let onLink {
            onLink(link)
        } else {
            super.requestOpenLink(source: source, link: link, params: params)
        }
    }

    /// The right-click menu. `NSView` calls this from its own `rightMouseDown`,
    /// which is as far as a right-click gets: SwiftTerm does not handle the
    /// right button at all. See `TerminalContextMenu`.
    override func menu(for event: NSEvent) -> NSMenu? {
        // `getSelection` is nil unless a selection is active: the selection
        // service's own text reader would hand back the range of the last one.
        let selected = getSelection() ?? ""
        let forSelection = selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? []
            : (selectionActions?(selected) ?? [])
        return TerminalContextMenu.make(
            for: self,
            actions: contextMenuActions?() ?? [],
            link: link(at: convert(event.locationInWindow, from: nil)),
            selectionActions: forSelection
        )
    }

    /// The link under a point in this view's own coordinates: a hyperlink a
    /// program printed, or text that reads as a URL. Nil in the padding around
    /// the grid and anywhere there is none.
    ///
    /// SwiftTerm finds it for a click itself, with geometry it keeps to itself;
    /// this finds the cell from the size of the grid it does report. The
    /// scrollbar is hidden in every container this view is put in, so the grid
    /// is all cells.
    func link(at point: NSPoint) -> String? {
        let terminal = getTerminal()
        let grid = getOptimalFrameSize()
        guard let size = TerminalLinks.cellSize(
                gridWidth: Double(grid.width), gridHeight: Double(grid.height),
                cols: terminal.cols, rows: terminal.rows),
              let cell = TerminalLinks.cell(
                x: Double(point.x), y: Double(point.y), viewHeight: Double(bounds.height),
                cellWidth: size.width, cellHeight: size.height,
                cols: terminal.cols, rows: terminal.rows) else { return nil }
        return terminal.link(at: .screen(Position(col: cell.col, row: cell.row)), mode: .explicitAndImplicit)
    }

    // MARK: Drops

    /// What a drop would type into the shell, or nil when this terminal takes
    /// none of it. Files win over text when a drag carries both, as in Finder.
    private enum DropContent {
        case typed(String)
        case bytes([UInt8])
    }

    private func dropContent(from sender: NSDraggingInfo) -> DropContent? {
        guard dropPolicy != .nothing else { return nil }
        let pasteboard = sender.draggingPasteboard
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        if !urls.isEmpty {
            // A drag of files is files or nothing. A path on this Mac is no use
            // to a remote shell, and the plain-text form such a drag can also
            // carry is just a file's name — not what the person dragged — so
            // it is never tried. A set of paths with one unsafe name is
            // likewise refused whole.
            guard dropPolicy == .filesAndText else { return nil }
            // `filePathURL` turns a file-reference URL (some apps drag those)
            // into the real path; for an ordinary file URL it is the same one.
            // It belongs to `NSURL`, not Swift's `URL`, hence the bridge.
            let paths = urls.map { (($0 as NSURL).filePathURL ?? $0).path }
            return TerminalDrop.typedPaths(paths).map(DropContent.typed)
        }
        if let text = pasteboard.string(forType: .string),
           let payload = TerminalDrop.textPayload(text, bracketedPasteMode: getTerminal().bracketedPasteMode) {
            return .bytes(payload)
        }
        return nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragIsAcceptable = dropContent(from: sender) != nil
        return dragIsAcceptable ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragIsAcceptable ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dragIsAcceptable = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dragIsAcceptable = false }
        guard let content = dropContent(from: sender) else {
            NSSound.beep()
            return false
        }
        switch content {
        case .typed(let line):
            send(txt: line)
        case .bytes(let payload):
            send(data: payload[...])
        }
        window?.makeFirstResponder(self)
        return true
    }

    /// BEL — SwiftTerm exposes this as an open TerminalDelegate method.
    override func bell(source: Terminal) {
        onAttention?(.bell)
        super.bell(source: source)
    }

    /// Hooks OSC 9 (Growl-style message) and OSC 777 (notify). Custom handlers
    /// run before built-ins, so OSC 9 must still forward `9;4` progress reports
    /// to keep Dock progress working.
    func installAttentionOSCHandlers() {
        // `terminal` is used to register and must NOT be captured: the handler
        // is stored on this same terminal's parser, so a strong reference from
        // inside the closure is a cycle (Terminal → parser → handler →
        // Terminal) that keeps the whole scrollback alive after the pane
        // closes. Reach it through `self` instead, which is already weak.
        let terminal = getTerminal()
        terminal.registerOscHandler(code: 9) { [weak self] data in
            guard let self else { return }
            if let report = Self.parseProgressReport(data) {
                self.progressReport(source: self.getTerminal(), report: report)
                return
            }
            let message = String(bytes: data, encoding: .utf8) ?? ""
            self.onAttention?(.osc9(message: message))
        }
        terminal.registerOscHandler(code: 777) { [weak self] data in
            guard let self else { return }
            // ESC ] 777 ; notify ; [title] ; [body] BEL
            //
            // The body is optional: `777;notify;Build finished` is a title on
            // its own and must still raise attention. SwiftTerm's own
            // `oscNotification` delegate is an empty no-op at the pinned
            // revision, so nothing else picks this up if we drop it.
            guard let text = String(bytes: data, encoding: .utf8) else { return }
            let parts = text.components(separatedBy: ";")
            guard parts.count >= 2, parts[0] == "notify" else { return }
            let title = parts[1]
            let body = parts.count >= 3 ? parts[2...].joined(separator: ";") : ""
            self.onAttention?(.osc777(
                title: title.isEmpty ? nil : title,
                body: body.isEmpty ? nil : body
            ))
        }
    }

    /// Reads OSC 633 from a shell started with the integration hooks. SwiftTerm
    /// handles OSC 133 itself and leaves this code alone, so registering for it
    /// displaces nothing. The handler is stored on this terminal's own parser,
    /// so, as above, it holds `self` weakly.
    func installShellMarkHandler() {
        getTerminal().registerOscHandler(code: ShellIntegration.oscCode) { [weak self] data in
            guard let self, let mark = ShellIntegration.parse(data, nonce: self.shellIntegrationNonce) else { return }
            self.onShellMark?(mark)
        }
    }

    /// Mirrors SwiftTerm's private OSC 9;4 parser so registering a custom
    /// handler does not drop Dock progress updates.
    private static func parseProgressReport(_ data: ArraySlice<UInt8>) -> Terminal.ProgressReport? {
        guard let text = String(bytes: data, encoding: .ascii) else { return nil }
        let parts = text.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "4" else { return nil }
        let statePart = parts[1]
        guard statePart.count == 1,
              let stateValue = Int(statePart),
              let state = Terminal.ProgressReportState(rawValue: stateValue) else {
            return nil
        }
        // Clamp rather than reject, exactly as SwiftTerm does. Returning nil
        // for an out-of-range percentage does not merely drop the progress
        // update — the handler above then treats the sequence as a message and
        // raises attention, so `9;4;1;150` lit a sidebar dot and posted a
        // banner titled "4;1;150".
        var progress: UInt8?
        if parts.count >= 3, !parts[2].isEmpty {
            guard let raw = Int(parts[2]) else { return nil }
            progress = UInt8(max(0, min(raw, 100)))
        } else if state == .set {
            // Without this, `9;4;1` leaves progress nil and the bar redraws at
            // the previous run's value instead of resetting.
            progress = 0
        }
        if state == .remove {
            progress = nil
        }
        return Terminal.ProgressReport(state: state, progress: progress)
    }
}
