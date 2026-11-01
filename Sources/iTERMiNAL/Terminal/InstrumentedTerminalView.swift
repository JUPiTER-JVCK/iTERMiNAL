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
    /// Reports a finished command line, for naming the tab after what it is
    /// doing rather than after its directory.
    var onCommand: ((String) -> Void)?
    /// A mark from a shell started with the integration hooks (OSC 633): a prompt
    /// is about to be drawn, a command starts, a command ended with a status.
    /// Called on whichever queue SwiftTerm parses on.
    var onShellMark: ((ShellIntegration.Mark) -> Void)?
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

    /// What has been typed since the last Enter.
    private var lineBuffer: [UInt8] = []
    /// Cleared when something happens that makes the buffer stop matching what
    /// the shell will actually run.
    private var lineIsTrustworthy = true

    /// The keystroke path — `super` writes the bytes to the PTY, so it must
    /// always run first.
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        super.send(source: source, data: data)
        accumulateCommand(data)
        onInput?()
    }

    /// Rebuilds the command line from the bytes heading for the shell.
    ///
    /// Deliberately conservative. These are the bytes the user typed, not what
    /// the shell has after its own line editing, so anything that rewrites the
    /// line behind our back — history recall, tab completion, any arrow key —
    /// abandons the buffer rather than reporting a command that was never run.
    /// A wrong tab name is worse than the directory it would otherwise show.
    private func accumulateCommand(_ data: ArraySlice<UInt8>) {
        for byte in data {
            switch byte {
            case 0x0D, 0x0A:                    // Enter: the line is complete
                if lineIsTrustworthy, !lineBuffer.isEmpty,
                   let line = String(bytes: lineBuffer, encoding: .utf8) {
                    onCommand?(line)
                }
                lineBuffer.removeAll(keepingCapacity: true)
                lineIsTrustworthy = true
            case 0x7F, 0x08:                    // Backspace
                // One keypress deletes one character, which in UTF-8 may be
                // several bytes: dropping a single byte would leave a broken
                // sequence that fails to decode on Enter, silently losing an
                // otherwise perfectly good command.
                while let last = lineBuffer.last, last & 0xC0 == 0x80 {
                    lineBuffer.removeLast()
                }
                if !lineBuffer.isEmpty { lineBuffer.removeLast() }
            case 0x03, 0x04, 0x15:              // ^C, ^D, ^U abandon the line
                lineBuffer.removeAll(keepingCapacity: true)
                lineIsTrustworthy = true
            case 0x20...0x7E, 0x80...0xFF:      // Printable ASCII and UTF-8
                lineBuffer.append(byte)
            default:
                // Every other control byte — escape sequences, Tab, and the
                // readline editing keys (^W, ^K, ^A, ^E, ^Y…) — moves or
                // rewrites the shell's line somewhere this buffer cannot
                // follow. Treating them as "no effect" produced titles that
                // were confidently wrong: `echo old`, ^W, `new` runs
                // `echo new` and would have been recorded as `echo oldnew`.
                lineIsTrustworthy = false
            }
        }
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
            guard let mark = ShellIntegration.parse(data) else { return }
            self?.onShellMark?(mark)
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
