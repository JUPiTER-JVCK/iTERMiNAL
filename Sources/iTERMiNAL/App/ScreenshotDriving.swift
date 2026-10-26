#if SCREENSHOTS
import AppKit

/// The keyboard and the view tree, as a person would meet them. See
/// ScreenshotMode.swift.
extension ScreenshotMode {
    // MARK: The composer

    /// The composer's input, if the window has one on screen.
    @MainActor
    static func composerField(in window: NSWindow) -> CommandTextView? {
        guard let root = window.contentView else { return nil }
        return firstView(ofType: CommandTextView.self, in: root)
    }

    /// Types into the composer the way a person would: through its text view,
    /// so its colouring and suggestions run. An empty string clears it.
    @MainActor
    static func typeIntoComposer(_ text: String, in window: NSWindow) -> Bool {
        guard let field = composerField(in: window) else { return false }
        let whole = NSRange(location: 0, length: (field.string as NSString).length)
        field.insertText(text, replacementRange: whole)
        return true
    }

    /// Gives the composer the keyboard, which is what makes it a field being
    /// typed in rather than one on the page: the keys below are only answered
    /// by one that has it, and a list left open behind a field that loses it
    /// is closed again.
    @MainActor
    static func focusComposer(in window: NSWindow) -> Bool {
        guard let field = composerField(in: window) else { return false }
        return window.makeFirstResponder(field)
    }

    /// ⌃R: the list that searches the history.
    @MainActor
    static func pressControlR(in window: NSWindow) {
        press(code: 15, characters: "\u{12}", ignoringModifiers: "r", modifiers: .control, in: window)
    }

    /// ⇥: the file list, or the rest of a ghost.
    @MainActor
    static func pressTab(in window: NSWindow) {
        press(code: 48, characters: "\t", in: window)
    }

    /// ↩: sends what is in the composer.
    @MainActor
    static func pressReturn(in window: NSWindow) {
        press(code: 36, characters: "\r", in: window)
    }

    /// ⎋: puts away a list, or a ghost.
    @MainActor
    static func pressEscape(in window: NSWindow) {
        press(code: 53, characters: "\u{1B}", in: window)
    }

    /// A key-down event, handed to the composer's text view directly — the
    /// route a keystroke takes once the window has picked its recipient, minus
    /// the window picking. `characters` is what the key types; the layout only
    /// matters for ⌃R, which the view looks for by letter.
    @MainActor
    private static func press(
        code: UInt16,
        characters: String,
        ignoringModifiers: String? = nil,
        modifiers: NSEvent.ModifierFlags = [],
        in window: NSWindow
    ) {
        guard let field = composerField(in: window) else {
            say("key \(code): there is no composer to press it in")
            return
        }
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: ignoringModifiers ?? characters,
            isARepeat: false,
            keyCode: code
        ) else {
            say("key \(code): the system would not make an event for it")
            return
        }
        field.keyDown(with: event)
    }

    // MARK: Panels

    /// The response half of the request pane is a split view under the request
    /// builder. Its divider is moved up, so the response is what fills the pane.
    @MainActor
    static func giveResponseRoom(in window: NSWindow) {
        guard let root = window.contentView else { return }
        let stacked = allViews(of: NSSplitView.self, in: root).first {
            !$0.isVertical && $0.arrangedSubviews.count == 2
        }
        guard let split = stacked else {
            say("response: no stacked split view found")
            return
        }
        split.setPosition((split.bounds.height * 0.18).rounded(), ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        say("response: divider moved, split is \(Int(split.bounds.height)) high")
    }

    // MARK: Views

    /// Where each terminal in the window is and how big, for when the picture
    /// of one comes out empty.
    @MainActor
    static func describeTerminals(in window: NSWindow, label: String) {
        guard let root = window.contentView else { return }
        for (index, container) in allViews(of: TerminalContainerView.self, in: root).enumerated() {
            let inWindow = container.convert(container.bounds, to: nil)
            let terminal = container.terminal
            say("\(label): terminal \(index): container \(inWindow), terminal frame \(terminal.frame), "
                + "hidden \(terminal.isHidden || container.isHidden), alpha \(terminal.alphaValue), "
                + "in a window \(terminal.window != nil)")
        }
    }

    @MainActor
    static func allViews<V: NSView>(of type: V.Type, in root: NSView) -> [V] {
        var found: [V] = []
        if let match = root as? V { found.append(match) }
        for child in root.subviews { found.append(contentsOf: allViews(of: type, in: child)) }
        return found
    }

    @MainActor
    static func firstView<V: NSView>(ofType type: V.Type, in root: NSView) -> V? {
        allViews(of: type, in: root).first
    }

    // MARK: What the menu bar binds

    /// The key equivalents the menu bar actually holds, from AppKit rather than
    /// from the source text — and how they compare with `ShortcutCatalog`,
    /// which the logic check can only hold to the source.
    ///
    /// Every item of the menus this app defines is listed, with or without a
    /// key: a shortcut the code binds can still arrive with none, and the
    /// absence is the finding. A chord two items want is reported too.
    @MainActor
    static func describeMenus() {
        guard let menus = NSApp.mainMenu else {
            say("menus: there is no main menu")
            return
        }
        let ours: Set<String> = ["View", "Terminal", "Panels", "Help"]
        var bound = Set<String>()
        var owners: [String: [String]] = [:]
        var keyless: [String] = []
        for menu in menus.items {
            for item in menu.submenu?.items ?? [] where !item.isSeparatorItem {
                let name = "\(menu.title) > \(item.title)"
                let hasKey = !item.keyEquivalent.isEmpty
                if hasKey {
                    let chord = keys(of: item)
                    bound.insert(chord)
                    owners[chord, default: []].append(name)
                }
                if !hasKey, ours.contains(menu.title) { keyless.append(item.title) }
                if hasKey || ours.contains(menu.title) {
                    let notes = (item.isAlternate ? " [alternate]" : "") + (item.isEnabled ? "" : " [disabled]")
                    say("menu \(name): \(hasKey ? keys(of: item) : "(no key)")\(notes)")
                }
            }
        }
        for (chord, names) in owners.sorted(by: { $0.key < $1.key }) where names.count > 1 {
            say("shared key \(chord): \(names)")
        }
        // The two splits are meant to have none; anything else here is a
        // shortcut the code binds that the menu bar did not keep.
        say("items of ours with no key: \(keyless)")
        let listed = Set(ShortcutCatalog.all.filter { $0.source != .view }.flatMap(\.chords).map(\.display))
        say("menus bind \(bound.count) keys; the catalog lists \(listed.count) outside views")
        say("in the menus but not the catalog: \(bound.subtracting(listed).sorted())")
        say("in the catalog but not the menus: \(listed.subtracting(bound).sorted())")
    }

    private static func keys(of item: NSMenuItem) -> String {
        let mask = item.keyEquivalentModifierMask
        var keys = ""
        if mask.contains(.control) { keys += "⌃" }
        if mask.contains(.option) { keys += "⌥" }
        if mask.contains(.shift) { keys += "⇧" }
        if mask.contains(.command) { keys += "⌘" }
        return keys + item.keyEquivalent.uppercased()
    }
}
#endif
