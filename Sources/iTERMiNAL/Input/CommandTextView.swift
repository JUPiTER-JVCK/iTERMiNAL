import SwiftUI
import AppKit

/// Everything about how the composer's input is painted, in one comparable
/// value, so the editor re-colours itself exactly when it changes and not on
/// every SwiftUI update.
struct CommandInputStyle: Equatable {
    var colors: SyntaxColors
    var body: NSColor
    var accent: NSColor
    var placeholder: NSColor
}

/// The composer's input: an AppKit text view that colours the command as it is
/// typed.
///
/// A SwiftUI `TextField` cannot colour parts of its own text, so this takes its
/// place. It keeps what the field did — Return sends, ⇧↩ and ⌥↩ add a line,
/// ↑ and ↓ walk history while the text is one line, one to six lines tall — and
/// adds the colour.
struct CommandInputView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let style: CommandInputStyle
    /// Where the command will run, so `./script` can be checked against it.
    let workingDirectory: String?
    /// The rest of a remembered command, drawn after the caret in a quiet
    /// colour — and the text it was worked out for. A ghost is only drawn, or
    /// taken, while the field still holds exactly that text: a key pressed
    /// before SwiftUI has caught up must not append it to something else.
    let ghost: String
    let ghostBase: String
    /// Suggestions and the list. The editor reports the caret to it, hands it
    /// the keys it uses, and puts what it picks into the field.
    let suggestions: ComposerSuggestions
    /// True while a request to focus the input has not been acted on yet.
    let focusPending: Bool
    @Binding var isFocused: Bool
    var onFocusTaken: () -> Void
    var onSubmit: () -> Void
    /// Return true if the key was used; false lets the text view move the caret.
    var onRecallEarlier: () -> Bool
    var onRecallLater: () -> Bool

    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let insets = NSSize(width: 12, height: 9)
    static let maxLines: CGFloat = 6

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1, built explicitly. A bare NSTextView() is TextKit 2 on
        // current macOS, and measuring its height means reaching for the
        // layout manager, which silently converts it back.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)

        let textView = CommandTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 30), textContainer: container)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = Self.insets
        textView.drawsBackground = false

        // A command line is not prose. Smart quotes and dashes would silently
        // change what is run, and spelling and link detection only add noise.
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        // The composer suggests from history and files itself. The system's
        // word completions and inline predictions would be a second ghost
        // competing with it, offering words rather than commands.
        textView.isAutomaticTextCompletionEnabled = false
        if #available(macOS 14.0, *) {
            textView.inlinePredictionType = .no
        }
        textView.setAccessibilityLabel("Command input")

        let scrollView = CommandScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = textView

        let coordinator = context.coordinator
        coordinator.textView = textView
        textView.delegate = coordinator
        storage.delegate = coordinator
        textView.onAttach = { [weak coordinator] in coordinator?.takeFocusIfRequested() }
        textView.string = text
        coordinator.refresh(textView, from: self)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.refresh(textView, from: self)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        // The storage only holds its delegate weakly, so make sure it cannot
        // outlive the coordinator that is about to go.
        coordinator.textView?.textStorage?.delegate = nil
        coordinator.textView?.delegate = nil
    }

    /// Height for the current text at the proposed width: the text's own height
    /// within one to six lines, plus the padding above and below.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let textView = context.coordinator.textView else { return nil }
        let width = proposal.width ?? max(nsView.frame.width, 100)
        return CGSize(width: width, height: Self.height(of: textView, width: width))
    }

    static func height(of textView: NSTextView, width: CGFloat) -> CGFloat {
        let insets = textView.textContainerInset
        guard let container = textView.textContainer, let layout = textView.layoutManager else {
            return font.pointSize * 1.4 + insets.height * 2
        }
        let contentWidth = max(1, width - insets.width * 2)
        if abs(container.containerSize.width - contentWidth) > 0.5 {
            container.containerSize = NSSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
        }
        layout.ensureLayout(for: container)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        // The used rect leaves out the empty line after a trailing newline.
        let used = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
        let content = min(max(used, lineHeight), lineHeight * maxLines)
        return ceil(content + insets.height * 2)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: CommandInputView
        weak var textView: CommandTextView?
        private var appliedStyle: CommandInputStyle?
        /// Whether `./script` is coloured depends on where the command will
        /// run, so the painted state is a function of this as well as the
        /// style: switching destination must repaint even if nothing else did.
        private var appliedDirectory: String?

        init(_ parent: CommandInputView) {
            self.parent = parent
        }

        /// Brings the text view up to date with what SwiftUI is asking for.
        func refresh(_ textView: CommandTextView, from view: CommandInputView) {
            parent = view

            textView.placeholder = view.placeholder
            textView.onReturn = { [weak self] in self?.parent.onSubmit() }
            textView.onUp = { [weak self] in self?.parent.onRecallEarlier() ?? false }
            textView.onDown = { [weak self] in self?.parent.onRecallLater() ?? false }
            textView.onFocusChange = { [weak self] focused in
                // Not during a view update: SwiftUI complains about state
                // changed while it is still being computed.
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.parent.isFocused != focused { self.parent.isFocused = focused }
                    // A list left open behind a field that lost focus would be
                    // unanswerable from the keyboard. Not while the pointer is
                    // on it, though: that is a click on a row, which is about
                    // to choose it.
                    if !focused, !self.parent.suggestions.pointerInside {
                        self.parent.suggestions.close()
                    }
                }
            }
            textView.ghost = view.ghost
            textView.ghostBase = view.ghostBase
            textView.isListOpen = { [weak self] in self?.parent.suggestions.mode != nil }
            textView.onSuggestionKey = { [weak self, weak textView] key in
                guard let self, let textView else { return false }
                return self.parent.suggestions.handle(
                    key,
                    text: textView.string,
                    caret: textView.selectedRange().location
                )
            }
            view.suggestions.apply = { [weak textView] replacement in
                textView?.apply(replacement)
            }

            // Leave the text alone while an input method is composing: it owns
            // the characters until they are committed.
            if textView.string != view.text, !textView.hasMarkedText() {
                textView.string = view.text
                textView.setSelectedRange(NSRange(location: (view.text as NSString).length, length: 0))
                textView.needsDisplay = true
            }

            apply(view.style, directory: view.workingDirectory, to: textView)

            if view.focusPending {
                DispatchQueue.main.async { [weak self] in self?.takeFocusIfRequested() }
            }
        }

        /// Takes keyboard focus if a request is waiting, and says so only once
        /// it really has focus — the view may not be in a window yet, and a
        /// request acknowledged too early would be lost.
        func takeFocusIfRequested() {
            guard parent.focusPending, let textView, let window = textView.window else { return }
            if window.makeFirstResponder(textView) {
                parent.onFocusTaken()
            }
        }

        // MARK: Colour

        private func apply(_ style: CommandInputStyle, directory: String?, to textView: CommandTextView) {
            guard style != appliedStyle || directory != appliedDirectory else { return }
            appliedStyle = style
            appliedDirectory = directory
            textView.font = CommandInputView.font
            textView.textColor = style.body
            textView.insertionPointColor = style.accent
            textView.placeholderColor = style.placeholder
            // The same quiet colour comments get, which is already held to
            // 4.5:1 on the field.
            textView.ghostColor = NSColor(hex: style.colors.comment)
            textView.typingAttributes = baseAttributes(style)
            // Not while an input method is composing: repainting would erase
            // its underline. The edit that commits the text re-colours it.
            if let storage = textView.textStorage, !textView.hasMarkedText() {
                storage.beginEditing()
                highlight(storage, style: style)
                storage.endEditing()
            }
            textView.needsDisplay = true
        }

        private func baseAttributes(_ style: CommandInputStyle) -> [NSAttributedString.Key: Any] {
            [.font: CommandInputView.font, .foregroundColor: style.body]
        }

        /// Attributes only, never characters — the one thing a storage delegate
        /// may do while editing is processed, and why this adds no undo steps.
        func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            guard editedMask.contains(.editedCharacters),
                  let style = appliedStyle,
                  // Painting over marked text would erase the underline the
                  // input method draws under what is still being composed.
                  textView?.hasMarkedText() != true else { return }
            highlight(textStorage, style: style)
        }

        private func highlight(_ storage: NSTextStorage, style: CommandInputStyle) {
            let whole = NSRange(location: 0, length: storage.length)
            storage.setAttributes(baseAttributes(style), range: whole)

            let string = storage.string as NSString
            for token in ShellTokenizer.tokenize(storage.string) {
                let range = NSRange(location: token.range.lowerBound, length: token.range.count)
                guard NSMaxRange(range) <= storage.length else { continue }

                let color: UInt32
                switch token.kind {
                case .command:
                    // Only a command that exists gets the colour: aliases and
                    // functions are invisible from here, so unknown stays plain.
                    let word = string.substring(with: range)
                    guard CommandResolver.shared.isKnown(word, workingDirectory: appliedDirectory) else { continue }
                    color = style.colors.command
                case .flag: color = style.colors.flag
                case .string: color = style.colors.string
                case .variable: color = style.colors.variable
                case .op: color = style.colors.op
                case .comment: color = style.colors.comment
                }
                storage.addAttribute(.foregroundColor, value: NSColor(hex: color), range: range)
            }
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if parent.text != textView.string {
                parent.text = textView.string
            }
            textView.needsDisplay = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let caret = textView.selectedRange().location
            parent.suggestions.caret = caret
            // The ghost is only drawn with the caret at the end.
            textView.needsDisplay = true
            // A file list is about the word the caret is in, so moving out of
            // it changes or closes the list. After this update, not during it.
            if parent.suggestions.mode == .path {
                let text = textView.string
                DispatchQueue.main.async { [weak self] in
                    self?.parent.suggestions.refresh(text: text, caret: caret)
                }
            }
        }
    }
}

// MARK: - Views

/// The text view. Handles the keys the composer gives meaning to, and draws the
/// placeholder.
final class CommandTextView: NSTextView {
    var placeholder = ""
    var placeholderColor = NSColor.secondaryLabelColor
    var onReturn: (() -> Void)?
    var onUp: (() -> Bool)?
    var onDown: (() -> Bool)?
    var onFocusChange: ((Bool) -> Void)?
    var onAttach: (() -> Void)?
    /// Offers a key to the suggestions; true if it used it.
    var onSuggestionKey: ((ComposerSuggestions.Key) -> Bool)?
    /// Asked at the moment of a key, not cached: a list can open and close
    /// between one SwiftUI update and the next.
    var isListOpen: () -> Bool = { false }

    var ghost = "" {
        didSet { if ghost != oldValue { needsDisplay = true } }
    }
    var ghostBase = ""
    var ghostColor = NSColor.tertiaryLabelColor

    // Key codes: Return, keypad Enter, down arrow, up arrow.
    private static let returnKeys: Set<UInt16> = [36, 76]
    private static let tabKey: UInt16 = 48
    private static let escapeKey: UInt16 = 53
    private static let rightArrowKey: UInt16 = 124

    override func keyDown(with event: NSEvent) {
        // While an input method is composing, Return commits the composition
        // and the arrows choose between candidates. They are not ours.
        if hasMarkedText() {
            super.keyDown(with: event)
            return
        }
        // The arrow keys also report .function and .numericPad, so look only at
        // the modifiers a person actually pressed.
        let modifiers = event.modifierFlags.intersection([.shift, .option, .command, .control])
        let code = event.keyCode

        // ⌃R searches history. By character rather than key code, so it is the
        // R key on whatever layout is in use.
        if modifiers == .control, event.charactersIgnoringModifiers?.lowercased() == "r",
           onSuggestionKey?(.historySearch) == true {
            return
        }

        // While a list is open it owns the keys that move through it, and
        // Return and Tab choose from it instead of sending or completing.
        if modifiers.isEmpty, isListOpen(), let key = Self.listKey(for: code), onSuggestionKey?(key) == true {
            return
        }

        if Self.returnKeys.contains(code) {
            if modifiers.isEmpty {
                onReturn?()
                return
            }
            if modifiers == .shift || modifiers == .option {
                insertText("\n", replacementRange: NSRange(location: NSNotFound, length: 0))
                return
            }
        } else if modifiers.isEmpty {
            switch code {
            case 126:
                if onUp?() == true { return }
            case 125:
                if onDown?() == true { return }
            case Self.tabKey:
                // The ghost first; failing that, a file name. Either way Tab
                // does not type a tab into a command line.
                if acceptGhost() { return }
                if onSuggestionKey?(.tab) == true { return }
            case Self.rightArrowKey:
                if acceptGhost() { return }
            case Self.escapeKey:
                if visibleGhost != nil, onSuggestionKey?(.dismiss) == true { return }
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    /// What a key means to an open list.
    private static func listKey(for code: UInt16) -> ComposerSuggestions.Key? {
        switch code {
        case 126: return .up
        case 125: return .down
        case 36, 76, tabKey: return .accept
        case escapeKey: return .dismiss
        default: return nil
        }
    }

    /// The ghost, if it is there to be seen: the field holds exactly the text
    /// it was worked out for, the caret is at the end with nothing selected,
    /// and no input method is mid-composition.
    private var visibleGhost: String? {
        guard !ghost.isEmpty, string == ghostBase, !hasMarkedText() else { return nil }
        let selection = selectedRange()
        guard selection.length == 0, selection.location == (string as NSString).length else { return nil }
        return ghost
    }

    private func acceptGhost() -> Bool {
        guard let ghost = visibleGhost else { return false }
        insertText(ghost, replacementRange: NSRange(location: (string as NSString).length, length: 0))
        return true
    }

    /// Puts a suggestion into the text: all of it, or one range. Through
    /// `insertText`, so it is one undo step and the colouring follows.
    func apply(_ replacement: ComposerSuggestions.Replacement) {
        let length = (string as NSString).length
        let range = replacement.range ?? NSRange(location: 0, length: length)
        guard NSMaxRange(range) <= length else { return }
        window?.makeFirstResponder(self)
        insertText(replacement.text, replacementRange: range)
    }

    /// Escape in a text view offers word completions from the dictionary —
    /// nothing a command line wants, and a second popup beside the composer's
    /// own.
    override func complete(_ sender: Any?) {}

    /// Pasting formatted text would bring its fonts and colours along.
    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            drawPlaceholder()
        } else {
            drawGhost()
        }
    }

    private func drawPlaceholder() {
        guard !placeholder.isEmpty, !hasMarkedText() else { return }
        let origin = NSPoint(
            x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0),
            y: textContainerInset.height
        )
        (placeholder as NSString).draw(
            at: origin,
            withAttributes: [.font: CommandInputView.font, .foregroundColor: placeholderColor]
        )
    }

    /// The suggestion, right after the last character, cut off with an ellipsis
    /// if it would run past the edge.
    private func drawGhost() {
        guard let ghost = visibleGhost, let layoutManager, let textContainer else { return }
        let glyphCount = layoutManager.numberOfGlyphs
        guard glyphCount > 0 else { return }
        let last = NSRange(location: glyphCount - 1, length: 1)
        let glyph = layoutManager.boundingRect(forGlyphRange: last, in: textContainer)
        let line = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphCount - 1, effectiveRange: nil)
        let origin = textContainerOrigin
        let x = origin.x + glyph.maxX
        let available = bounds.width - x - textContainerInset.width
        guard available > 24 else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (ghost as NSString).draw(
            in: NSRect(x: x, y: origin.y + line.minY, width: available, height: line.height),
            withAttributes: [
                .font: CommandInputView.font,
                .foregroundColor: ghostColor,
                .paragraphStyle: paragraph,
            ]
        )
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onAttach?() }
    }

    /// The frameless window moves by its background, and this view is not
    /// opaque. Without this a drag across the text moved the window instead of
    /// selecting it.
    override var mouseDownCanMoveWindow: Bool { false }
}

final class CommandScrollView: NSScrollView {
    override var mouseDownCanMoveWindow: Bool { false }
}
