#if SCREENSHOTS
import AppKit
import SwiftUI

/// Takes the pictures for the README from the real app.
///
/// Compiled only when a build defines `SCREENSHOTS` — the Screenshots workflow
/// does, no shipped build does — and switched on only when the environment
/// names a directory to write into. In every other build this file is empty.
///
/// It drives the app through its own models rather than clicking on it, then
/// asks each window to draw itself into a bitmap (`cacheDisplay`). That needs
/// no Screen Recording permission, which a CI runner will not grant, and gives
/// the same pixels at 2x whatever display the runner happens to have.
///
/// `cacheDisplay` runs each view's `draw(_:)` and nothing else, so what a view
/// paints through a layer property is missing from it. The terminal's
/// background is one (see `terminalBackgrounds`) and is put back by hand; web
/// views and Metal-backed layers are others, and none of the pictures use them.
///
/// The scenes run against a small sample project and a local web server that
/// the workflow prepares (scripts/screenshots), so nothing in a picture is
/// anyone's real data.
enum ScreenshotMode {
    private static let directoryVariable = "ITERMINAL_SCREENSHOT_DIR"
    private static let demoVariable = "ITERMINAL_DEMO_DIR"
    private static let logVariable = "ITERMINAL_FIXTURE_LOG"
    private static let site = "http://localhost:8765"

    /// What the composer shows in the hero picture: a command word, flags, a
    /// string, a pipe and a redirect, to show the input's colouring.
    private static let composerSample = #"git log --oneline --graph -n 20 | grep -i "merge" > merges.txt"#

    /// Called once the app has launched.
    static func startIfRequested() {
        guard let path = ProcessInfo.processInfo.environment[directoryVariable], !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        say("writing to \(directory.path)")

        // A job waiting on a window that never came up should end, not hang.
        // Whatever was written by then is still there to look at.
        DispatchQueue.main.asyncAfter(deadline: .now() + 420) {
            say("gave up after 420 seconds")
            exit(3)
        }
        Task { @MainActor in
            await run(into: directory)
            say("finished")
            exit(0)
        }
    }

    // MARK: Scenes

    @MainActor
    private static func run(into directory: URL) async {
        describeDisplays()
        guard let window = await mainWindow() else {
            say("no main window appeared")
            return
        }

        let store = WorkspaceStore.shared
        let settings = AppSettings.shared
        let environment = ProcessInfo.processInfo.environment
        let demo = environment[demoVariable]
        let fixtureLog = environment[logVariable]

        // Dark, with everything else at its default: the look most people see
        // the app in, and what the README describes. The CPU and memory of the
        // machine it happens to run on are not part of that.
        settings.theme = .dark
        settings.composerEnabled = true
        settings.railPanelOpen = true
        settings.railPanelPinned = true
        settings.showSystemMetrics = false

        await bringToFront(window)
        fit(window)
        await pause(1.5)
        say("main window: \(describe(window))")

        var server: WorkspaceTab?
        var docs: WorkspaceTab?

        await scene("main") {
            guard let hello = store.workspaces.first else { return false }
            hello.name = "hello-api"
            server = hello.tabs.first
            server?.customName = "server"
            let tests = store.newTab(in: hello, directory: demo)
            tests.customName = "tests"

            store.newWorkspace(named: "infra")
            let infra = store.workspaces.last
            infra?.tabs.first?.customName = "deploy"
            docs = store.newTab(in: infra, directory: demo.map { $0 + "/docs" })
            docs?.customName = "docs"
            if let server { store.togglePin(server) }

            // The tabs nobody is looking at get their output now; the one in
            // the picture is shown first, so it is sized to its window before
            // anything is printed into it.
            await pause(2.0)
            tests.primarySession?.send(text: "clear; git status -sb; git diff --stat\n")
            infra?.tabs.first?.primarySession?.send(text: "clear; ls -F\n")
            docs?.primarySession?.send(text: "clear; ls -F\n")

            guard let shown = server, let session = shown.primarySession else { return false }
            store.selectedTabID = shown.id
            store.focusedSessionID = session.id
            await pause(2.0)
            session.send(text: "clear; git log --oneline --graph --decorate -n 14; echo; ls -F\n")
            await pause(2.5)
            say("composer: \(typeIntoComposer(composerSample, in: window) ? "typed" : "no input field found")")
            await pause(1.0)
            return capture(window, "main", in: directory)
        }

        await scene("http-request") {
            store.openPanelExpanded(.http)
            await pause(1.5)
            let model = store.panelHTTPClient
            model.mode = .request
            model.method = .get
            model.urlText = "\(site)/api/users"
            model.headerFields = [
                HTTPHeaderField(name: "Accept", value: "application/json"),
                HTTPHeaderField(name: "Cache-Control", value: "no-cache"),
            ]
            model.send(settings: settings)
            let finished = await until(timeout: 20) { !model.isSending }
            say("request finished: \(finished)")
            await pause(1.0)
            // The response is the point of this picture, so it gets the room.
            giveResponseRoom(in: window)
            // And the app's own CPU reading, in the sidebar, a moment to come
            // back down from sending and laying this out.
            await pause(3.5)
            return capture(window, "http-request", in: directory)
        }

        await scene("http-explore") {
            let model = store.panelHTTPClient
            model.mode = .explore
            await pause(1.5)
            await explore("open \(site)", model.explorer, settings)
            await explore("ls -l", model.explorer, settings)
            await explore("cd docs", model.explorer, settings)
            await explore("tree -L 2", model.explorer, settings)
            await pause(1.0)
            return capture(window, "http-explore", in: directory)
        }

        await scene("splits") {
            store.closeRightRegion()
            _ = typeIntoComposer("", in: window)
            guard let tab = docs, let first = tab.primarySession else { return false }
            store.selectedTabID = tab.id
            store.focusedSessionID = first.id
            // The sidebar gives its width to the panes, which are what this
            // picture is of; lines that wrap in a narrow pane look like a bug.
            settings.railPanelOpen = false
            await pause(2.0)
            _ = store.splitFocusedPane(.horizontal, kind: .terminal)
            _ = store.splitFocusedPane(.vertical, kind: .files)
            await pause(2.5)

            let sessions = tab.root.allSessions()
            sessions.first?.send(text: "clear; git log --oneline -n 14\n")
            if sessions.count > 1 {
                let command = fixtureLog.map { "clear; tail -n 14 '\($0)'\n" } ?? "clear; ls -F\n"
                sessions[1].send(text: command)
            }
            await pause(2.5)
            let taken = capture(window, "splits", in: directory)
            settings.railPanelOpen = true
            return taken
        }

        await scene("palette") {
            store.closeRightRegion()
            if let server { store.selectedTabID = server.id }
            await pause(1.0)
            // The real thing first: the palette is a sheet, which is a window
            // of its own, so the main window's picture does not include it.
            store.showCommandPalette = true
            await pause(1.5)
            var saved = false
            if let sheet = window.attachedSheet {
                saved = capture(sheet, "palette", in: directory)
            } else {
                say("palette: no sheet is attached")
            }
            store.showCommandPalette = false
            if saved { return true }
            return await host(CommandPaletteView(), size: nil, name: "palette", in: directory)
        }

        await scene("shortcuts") {
            store.closeRightRegion()
            describeMenus()
            store.showShortcuts()
            await pause(1.5)
            guard let sheet = window.attachedSheet else {
                say("shortcuts: no sheet is attached")
                return false
            }
            let everything = capture(sheet, "shortcuts", in: directory)
            // The search field has the focus when the window opens, so type
            // into it the way a person would.
            if let editor = sheet.firstResponder as? NSTextView {
                let whole = NSRange(location: 0, length: (editor.string as NSString).length)
                editor.insertText("shift split", replacementRange: whole)
                await pause(1.0)
                _ = capture(sheet, "shortcuts-search", in: directory)
            } else {
                say("shortcuts: the search field does not have the focus")
            }
            store.showKeyboardShortcuts = false
            await pause(0.5)
            return everything
        }

        await scene("settings-appearance") {
            await host(
                SettingsRootView(initialSection: .appearance),
                size: NSSize(width: 940, height: 640),
                name: "settings-appearance",
                in: directory
            )
        }
    }

    @MainActor
    private static func scene(_ name: String, _ body: @MainActor () async -> Bool) async {
        say("scene \(name)…")
        let ok = await body()
        say("scene \(name): \(ok ? "ok" : "no picture")")
    }

    /// One line at the explorer's prompt, then until what it started is done.
    @MainActor
    private static func explore(_ line: String, _ explorer: SiteExplorerModel, _ settings: AppSettings) async {
        explorer.input = line
        explorer.submit(settings: settings)
        _ = await until(timeout: 30) { !explorer.isWorking }
        await pause(0.5)
    }

    /// A view on its own in a window of its own, with what the app gives its
    /// windows — for the Settings window, which does not exist until someone
    /// asks for it, and as the fallback for a sheet that did not appear.
    @MainActor
    private static func host<Content: View>(
        _ content: Content,
        size: NSSize?,
        name: String,
        in directory: URL
    ) async -> Bool {
        let settings = AppSettings.shared
        let root = content
            .environmentObject(settings)
            .environmentObject(WorkspaceStore.shared)
            .preferredColorScheme(settings.preferredColorScheme)
            .tint(settings.accentColor)
            .fontDesign(settings.uiFontDesign.design)
        let hosting = NSHostingView(rootView: root)
        let target = size ?? hosting.fittingSize
        guard target.width > 0, target.height > 0 else {
            say("\(name): nothing to show (\(target.width)x\(target.height))")
            return false
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: target),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        // The frame, not the content size: with the title bar drawn over the
        // content, a content size leaves a title-bar-high strip of bare window
        // under it.
        window.setFrame(NSRect(origin: NSPoint(x: 80, y: 80), size: target), display: true)
        window.makeKeyAndOrderFront(nil)
        await pause(2.0)
        // The system will not make a window shorter than its content plus a
        // title bar, even with the content drawn under it; what is left under
        // the content is bare window, and is left out of the picture.
        let spare = max(0, window.frame.height - target.height)
        let ok = capture(window, name, in: directory, trimmingBottom: spare)
        window.orderOut(nil)
        return ok
    }

    // MARK: Windows

    @MainActor
    private static func mainWindow() async -> NSWindow? {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let window = NSApp.windows.first(where: {
                $0.contentView != nil && $0.frame.width >= 400 && !($0 is NSPanel)
            }) {
                return window
            }
            await pause(0.25)
        }
        return nil
    }

    /// Asks to be the front app, and says whether it worked: a window that is
    /// not key draws grey traffic lights and no focus, which is not how the app
    /// looks to anyone using it. The system may decline a request from an app
    /// nobody launched by hand.
    @MainActor
    private static func bringToFront(_ window: NSWindow) async {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        await pause(1.0)
        if !NSApp.isActive {
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            window.makeKeyAndOrderFront(nil)
            await pause(1.0)
        }
        say("active: \(NSApp.isActive), key: \(window.isKeyWindow)")
    }

    /// The largest window that fits the screen with room to spare, at the
    /// proportions of a laptop's. The runner's display is small (1024x768),
    /// and the system keeps a window inside what is visible.
    @MainActor
    private static func fit(_ window: NSWindow) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let width = min(1024, visible.width)
        let height = min(visible.height, (width * 2 / 3).rounded())
        let frame = NSRect(x: visible.minX, y: visible.maxY - height, width: width, height: height)
        window.setFrame(frame, display: true)
    }

    @MainActor
    private static func describe(_ window: NSWindow) -> String {
        let frame = window.frame
        return "\(Int(frame.width))x\(Int(frame.height)) at \(Int(frame.minX)),\(Int(frame.minY)), "
            + "scale \(window.backingScaleFactor), visible \(window.isVisible), key \(window.isKeyWindow)"
    }

    @MainActor
    private static func describeDisplays() {
        if NSScreen.screens.isEmpty { say("no screens") }
        for (index, screen) in NSScreen.screens.enumerated() {
            let visible = screen.visibleFrame
            say("screen \(index): \(Int(screen.frame.width))x\(Int(screen.frame.height)), scale \(screen.backingScaleFactor), "
                + "visible \(Int(visible.width))x\(Int(visible.height))")
        }
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
    private static func describeMenus() {
        guard let menus = NSApp.mainMenu else {
            say("menus: there is no main menu")
            return
        }
        let ours: Set<String> = ["View", "Terminal", "Panels", "Help"]
        var bound = Set<String>()
        var owners: [String: [String]] = [:]
        for menu in menus.items {
            for item in menu.submenu?.items ?? [] where !item.isSeparatorItem {
                let name = "\(menu.title) > \(item.title)"
                let hasKey = !item.keyEquivalent.isEmpty
                if hasKey {
                    let chord = keys(of: item)
                    bound.insert(chord)
                    owners[chord, default: []].append(name)
                }
                if hasKey || ours.contains(menu.title) {
                    let notes = (item.isAlternate ? " [alternate]" : "") + (item.isEnabled ? "" : " [disabled]")
                    say("menu \(name): \(hasKey ? keys(of: item) : "(no key)")\(notes)")
                }
            }
        }
        for (chord, names) in owners.sorted(by: { $0.key < $1.key }) where names.count > 1 {
            say("shared key \(chord): \(names)")
        }
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

    // MARK: Driving the interface

    /// Types into the composer the way a person would: through its text view,
    /// so its colouring and suggestions run. An empty string clears it.
    @MainActor
    private static func typeIntoComposer(_ text: String, in window: NSWindow) -> Bool {
        guard let root = window.contentView, let field = firstView(ofType: CommandTextView.self, in: root) else {
            return false
        }
        let whole = NSRange(location: 0, length: (field.string as NSString).length)
        field.insertText(text, replacementRange: whole)
        return true
    }

    /// The response half of the request pane is a split view under the request
    /// builder. Its divider is moved up, so the response is what fills the pane.
    @MainActor
    private static func giveResponseRoom(in window: NSWindow) {
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

    @MainActor
    private static func allViews<V: NSView>(of type: V.Type, in root: NSView) -> [V] {
        var found: [V] = []
        if let match = root as? V { found.append(match) }
        for child in root.subviews { found.append(contentsOf: allViews(of: type, in: child)) }
        return found
    }

    @MainActor
    private static func firstView<V: NSView>(ofType type: V.Type, in root: NSView) -> V? {
        allViews(of: type, in: root).first
    }

    // MARK: Pictures

    /// The window as it looks on screen — traffic lights included, which live
    /// in the frame view around the content view — at twice its size.
    @MainActor
    private static func capture(
        _ window: NSWindow,
        _ name: String,
        in directory: URL,
        trimmingBottom trim: CGFloat = 0
    ) -> Bool {
        guard let content = window.contentView else { return false }
        window.displayIfNeeded()
        return write(content.superview ?? content, name, in: directory, scale: 2, trimmingBottom: trim)
    }

    /// Where each terminal in `root` paints its background, and in what colour.
    ///
    /// A terminal's background is its container's `layer.backgroundColor`, and
    /// `cacheDisplay` does not draw layer properties: the first screenshots had
    /// a terminal's text floating on nothing, in light grey against white. The
    /// rectangles come back in `root`'s coordinates with the origin at the
    /// bottom left, whichever way `root` is flipped.
    @MainActor
    private static func terminalBackgrounds(in root: NSView) -> [(rect: NSRect, color: NSColor)] {
        allViews(of: TerminalContainerView.self, in: root).compactMap { container in
            guard let cgColor = container.layer?.backgroundColor,
                  let color = NSColor(cgColor: cgColor) else { return nil }
            let visible = container.visibleRect
            guard !visible.isEmpty else { return nil }
            var rect = container.convert(visible, to: root)
            if root.isFlipped { rect.origin.y = root.bounds.height - rect.maxY }
            return (rect, color)
        }
    }

    @MainActor
    private static func write(
        _ view: NSView,
        _ name: String,
        in directory: URL,
        scale: CGFloat,
        trimmingBottom trim: CGFloat
    ) -> Bool {
        let bounds = view.bounds
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0, let plain = bitmap(width: width, height: height) else {
            say("\(name): nothing to draw (\(bounds.width)x\(bounds.height))")
            return false
        }
        // Points on one side, pixels on the other: that ratio is what makes
        // the view draw itself at 2x.
        plain.size = bounds.size
        view.cacheDisplay(in: bounds, to: plain)

        if looksBlank(plain) {
            say("\(name): the picture is one flat colour — nothing was drawn")
            return false
        }

        let backgrounds = terminalBackgrounds(in: view)
        say("\(name): \(backgrounds.count) terminal background(s) put back")
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let edge = dark ? NSColor.white.withAlphaComponent(0.22) : NSColor.black.withAlphaComponent(0.20)
        let finished = framed(
            plain,
            trimmingBottom: trim,
            under: backgrounds,
            edge: edge,
            cornerRadius: 11,
            margin: 36
        ) ?? plain
        guard let data = finished.representation(using: .png, properties: [:]) else {
            say("\(name): could not encode a PNG")
            return false
        }
        do {
            try data.write(to: directory.appendingPathComponent("\(name).png"))
            say("\(name): \(finished.pixelsWide)x\(finished.pixelsHigh), \(data.count) bytes")
            return true
        } catch {
            say("\(name): \(error.localizedDescription)")
            return false
        }
    }

    private static func bitmap(width: Int, height: Int) -> NSBitmapImageRep? {
        NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    }

    /// A coarse look at the picture: a grid of samples, all the same colour,
    /// is a view that drew nothing (a layer this method cannot see, a window
    /// that never showed) rather than a picture worth keeping.
    private static func looksBlank(_ rep: NSBitmapImageRep) -> Bool {
        guard rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return true }
        let stepX = max(rep.pixelsWide / 48, 1)
        let stepY = max(rep.pixelsHigh / 30, 1)
        var reference: NSColor?
        for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
                guard let color = rep.colorAt(x: x, y: y) else { continue }
                guard let first = reference else {
                    reference = color
                    continue
                }
                if color != first { return false }
            }
        }
        return true
    }

    /// `picture` with rounded corners, on a transparent margin, with a soft
    /// shadow under it and a hairline round it — the way a window looks in a
    /// macOS screenshot — and
    /// `backgrounds` filled in beneath it: the picture is transparent where a
    /// terminal should be, so they show through there and nowhere else.
    ///
    /// The picture is drawn as a CGImage, which composites over what is under
    /// it. `NSBitmapImageRep.draw(in:)` copies instead — its transparent
    /// pixels replace what was beneath them — which is how a first attempt at
    /// this lost the terminal backgrounds it had just painted.
    ///
    /// Drawn in pixels throughout (the output's size is only set to points at
    /// the end, so the PNG says it is a 2x image). `trim` points are left off
    /// the bottom.
    private static func framed(
        _ picture: NSBitmapImageRep,
        trimmingBottom trim: CGFloat,
        under backgrounds: [(rect: NSRect, color: NSColor)],
        edge: NSColor,
        cornerRadius: CGFloat,
        margin: CGFloat
    ) -> NSBitmapImageRep? {
        guard picture.size.width > 0, let whole = picture.cgImage else { return nil }
        let scale = CGFloat(picture.pixelsWide) / picture.size.width
        let kept = picture.pixelsHigh - Int((trim * scale).rounded())
        // A CGImage's origin is its top-left, so keeping the top rows trims the bottom.
        guard kept > 0,
              let image = whole.cropping(to: CGRect(x: 0, y: 0, width: picture.pixelsWide, height: kept))
        else { return nil }

        let pad = (margin * scale).rounded()
        let width = image.width + Int(pad * 2)
        let height = image.height + Int(pad * 2)
        guard let output = bitmap(width: width, height: height),
              let context = NSGraphicsContext(bitmapImageRep: output) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let rect = NSRect(x: pad, y: pad, width: CGFloat(image.width), height: CGFloat(image.height))
        let outline = NSBezierPath(roundedRect: rect, xRadius: cornerRadius * scale, yRadius: cornerRadius * scale)

        // The shadow is cast by the outline, and then the inside is cleared
        // again, so only the part outside the window is left.
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.40)
        shadow.shadowBlurRadius = 28 * scale
        shadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
        shadow.set()
        NSColor.black.setFill()
        outline.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        context.compositingOperation = .clear
        outline.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        for background in backgrounds {
            background.color.setFill()
            // A path, not NSRect.fill(), which copies rather than composites.
            NSBezierPath(rect: NSRect(
                x: pad + background.rect.minX * scale,
                y: pad + (background.rect.minY - trim) * scale,
                width: background.rect.width * scale,
                height: background.rect.height * scale
            )).fill()
        }
        context.cgContext.draw(image, in: rect)
        NSGraphicsContext.restoreGraphicsState()

        // A hairline round the window, as macOS draws one. Without it a dark
        // window on a dark page has no edge at all.
        NSGraphicsContext.saveGraphicsState()
        edge.setStroke()
        let line = scale
        let hairline = NSBezierPath(
            roundedRect: rect.insetBy(dx: line / 2, dy: line / 2),
            xRadius: cornerRadius * scale - line / 2,
            yRadius: cornerRadius * scale - line / 2
        )
        hairline.lineWidth = line
        hairline.stroke()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.restoreGraphicsState()

        output.size = NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        return output
    }

    // MARK: Waiting and logging

    private static func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    @MainActor
    private static func until(timeout: TimeInterval, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await pause(0.2)
        }
        return condition()
    }

    private static func say(_ message: String) {
        print("[screenshots] \(message)")
        fflush(stdout)
    }
}
#endif
