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
/// the same pixels at 2x whatever display the runner happens to have. What it
/// cannot draw: web views and anything Metal-backed — none of which the
/// pictures below use.
///
/// The scenes run against a small sample project and a local web server that
/// the workflow prepares (scripts/screenshots), so nothing in a picture is
/// anyone's real data.
enum ScreenshotMode {
    private static let directoryVariable = "ITERMINAL_SCREENSHOT_DIR"
    private static let demoVariable = "ITERMINAL_DEMO_DIR"
    private static let logVariable = "ITERMINAL_FIXTURE_LOG"
    private static let site = "http://localhost:8765"

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
        // the app in, and what the README describes.
        settings.theme = .dark
        settings.composerEnabled = true
        settings.railPanelOpen = true
        settings.railPanelPinned = true

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
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
            return capture(window, "main", in: directory)
        }

        await scene("http-request") {
            store.openPanelExpanded(.http)
            await pause(1.5)
            let model = store.panelHTTPClient
            model.mode = .request
            model.method = .get
            model.urlText = "\(site)/api/users"
            model.send(settings: settings)
            let finished = await until(timeout: 20) { !model.isSending }
            say("request finished: \(finished)")
            await pause(1.5)
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
            guard let tab = docs, let first = tab.primarySession else { return false }
            store.selectedTabID = tab.id
            store.focusedSessionID = first.id
            await pause(2.0)
            _ = store.splitFocusedPane(.horizontal, kind: .terminal)
            _ = store.splitFocusedPane(.vertical, kind: .files)
            await pause(2.5)

            let sessions = tab.root.allSessions()
            sessions.first?.send(text: "clear; git log --oneline --graph --decorate -n 14\n")
            if sessions.count > 1 {
                let command = fixtureLog.map { "clear; tail -n 14 '\($0)'\n" } ?? "clear; ls -F\n"
                sessions[1].send(text: command)
            }
            await pause(2.5)
            return capture(window, "splits", in: directory)
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
        window.setContentSize(target)
        window.setFrameOrigin(NSPoint(x: 80, y: 80))
        window.orderFront(nil)
        await pause(2.0)
        let ok = capture(window, name, in: directory)
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
            say("screen \(index): \(Int(screen.frame.width))x\(Int(screen.frame.height)), scale \(screen.backingScaleFactor)")
        }
    }

    // MARK: Pictures

    /// The window as it looks on screen — traffic lights included, which live
    /// in the frame view around the content view — at twice its size.
    @MainActor
    private static func capture(_ window: NSWindow, _ name: String, in directory: URL) -> Bool {
        guard let content = window.contentView else { return false }
        window.displayIfNeeded()
        return write(content.superview ?? content, name, in: directory, scale: 2)
    }

    @MainActor
    private static func write(_ view: NSView, _ name: String, in directory: URL, scale: CGFloat) -> Bool {
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

        let finished = framed(plain, cornerRadius: 11, margin: 36) ?? plain
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
    /// shadow under it — the way a window looks in a macOS screenshot.
    ///
    /// Drawn in pixels throughout (the output's size is only set to points at
    /// the end, so the PNG says it is a 2x image).
    private static func framed(_ picture: NSBitmapImageRep, cornerRadius: CGFloat, margin: CGFloat) -> NSBitmapImageRep? {
        guard picture.size.width > 0 else { return nil }
        let scale = CGFloat(picture.pixelsWide) / picture.size.width
        let pad = (margin * scale).rounded()
        let width = picture.pixelsWide + Int(pad * 2)
        let height = picture.pixelsHigh + Int(pad * 2)
        guard let output = bitmap(width: width, height: height),
              let context = NSGraphicsContext(bitmapImageRep: output) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let rect = NSRect(x: pad, y: pad, width: CGFloat(picture.pixelsWide), height: CGFloat(picture.pixelsHigh))
        let outline = NSBezierPath(roundedRect: rect, xRadius: cornerRadius * scale, yRadius: cornerRadius * scale)

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
        outline.addClip()
        picture.draw(in: rect)
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
