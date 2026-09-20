import AppKit
import SwiftTerm

/// LocalProcessTerminalView subclass that reports what the app needs to know.
///
/// Only methods SwiftTerm declares `open` are overridden — `send`,
/// `rangeChanged`, `requestOpenLink`, and `bell`. Other delegate methods on
/// this class (`sizeChanged`, `setTerminalTitle`, and `becomeFirstResponder`
/// on the view) are `public` but not `open`, so they cannot be overridden from
/// outside the module; those signals come through `processDelegate` and a
/// mouse monitor instead. OSC 9 / 777 are hooked via `parser.oscHandlers`.
final class InstrumentedTerminalView: LocalProcessTerminalView {
    var onActivity: (() -> Void)?
    var onInput: (() -> Void)?
    var onLink: ((String) -> Void)?
    /// Bell / OSC 9 / OSC 777 from the PTY stream.
    var onAttention: ((TerminalAttention) -> Void)?
    /// Reports a finished command line, for naming the tab after what it is
    /// doing rather than after its directory.
    var onCommand: ((String) -> Void)?

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

    /// BEL — SwiftTerm exposes this as an open TerminalDelegate method, so
    /// subclasses can observe it without replacing `terminalDelegate`.
    override func bell(source: Terminal) {
        onAttention?(.bell)
        super.bell(source: source)
    }

    /// Hooks OSC 9 (iTerm Growl message) and OSC 777 (notify) via the public
    /// `parser.oscHandlers` map. Custom handlers run before built-ins, so OSC 9
    /// must still forward `9;4` progress reports to keep Dock progress working.
    func installAttentionOSCHandlers() {
        let terminal = getTerminal()
        terminal.parser.oscHandlers[9] = { [weak self] data in
            guard let self else { return }
            if let report = Self.parseProgressReport(data) {
                self.progressReport(source: self.getTerminal(), report: report)
                return
            }
            let message = String(bytes: data, encoding: .utf8) ?? ""
            self.onAttention?(.osc9(message: message))
        }
        terminal.parser.oscHandlers[777] = { [weak self] data in
            guard let self else { return }
            // Same shape SwiftTerm's oscNotification expects:
            //   ESC ] 777 ; notify ; [title] ; [body] BEL
            guard let text = String(bytes: data, encoding: .utf8) else { return }
            let parts = text.components(separatedBy: ";")
            guard parts.count >= 3, parts[0] == "notify" else { return }
            let title = parts[1]
            let body = parts[2...].joined(separator: ";")
            self.onAttention?(.osc777(
                title: title.isEmpty ? nil : title,
                body: body.isEmpty ? nil : body
            ))
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
        var progress: UInt8?
        if parts.count >= 3, !parts[2].isEmpty {
            guard let raw = Int(parts[2]), raw >= 0, raw <= 100 else { return nil }
            progress = UInt8(raw)
        }
        return Terminal.ProgressReport(state: state, progress: progress)
    }
}
