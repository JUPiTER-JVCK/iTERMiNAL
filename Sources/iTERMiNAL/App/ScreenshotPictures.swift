#if SCREENSHOTS
import AppKit
import SwiftUI
import WebKit

/// Windows, and turning one into a picture. See ScreenshotMode.swift.
extension ScreenshotMode {
    // MARK: Windows

    @MainActor
    static func mainWindow() async -> NSWindow? {
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
    static func bringToFront(_ window: NSWindow) async {
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
    static func fit(_ window: NSWindow) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let width = min(1024, visible.width)
        let height = min(visible.height, (width * 2 / 3).rounded())
        let frame = NSRect(x: visible.minX, y: visible.maxY - height, width: width, height: height)
        window.setFrame(frame, display: true)
    }

    @MainActor
    static func describe(_ window: NSWindow) -> String {
        let frame = window.frame
        return "\(Int(frame.width))x\(Int(frame.height)) at \(Int(frame.minX)),\(Int(frame.minY)), "
            + "scale \(window.backingScaleFactor), visible \(window.isVisible), key \(window.isKeyWindow)"
    }

    @MainActor
    static func describeDisplays() {
        if NSScreen.screens.isEmpty { say("no screens") }
        for (index, screen) in NSScreen.screens.enumerated() {
            let visible = screen.visibleFrame
            say("screen \(index): \(Int(screen.frame.width))x\(Int(screen.frame.height)), scale \(screen.backingScaleFactor), "
                + "visible \(Int(visible.width))x\(Int(visible.height))")
        }
    }

    /// A view on its own in a window of its own, with what the app gives its
    /// windows — for the Settings window, which does not exist until someone
    /// asks for it, and as the fallback for a sheet that did not appear.
    @MainActor
    static func host<Content: View>(
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

    // MARK: Pictures

    /// Something a window cannot draw for itself — a web page — as a picture
    /// of it, to be laid over the window's own where `view` is.
    struct Overlay {
        let view: NSView
        let image: NSImage
    }

    /// What a web view shows, at twice its size. A web view paints through its
    /// own process and layers, so `cacheDisplay` leaves a hole where it is; this
    /// is what fills it.
    @MainActor
    static func snapshot(of web: WKWebView) async -> NSImage? {
        let configuration = WKSnapshotConfiguration()
        // The width in points of the picture asked for, so twice the view's
        // makes it 2x whatever the display it happens to be on.
        configuration.snapshotWidth = NSNumber(value: Double(web.bounds.width * 2))
        return await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
            web.takeSnapshot(with: configuration) { image, error in
                if let error { say("snapshot: \(error.localizedDescription)") }
                continuation.resume(returning: image)
            }
        }
    }

    /// The window as it looks on screen — traffic lights included, which live
    /// in the frame view around the content view — at twice its size.
    @MainActor
    static func capture(
        _ window: NSWindow,
        _ name: String,
        in directory: URL,
        trimmingBottom trim: CGFloat = 0,
        overlays: [Overlay] = []
    ) -> Bool {
        guard let content = window.contentView else { return false }
        window.displayIfNeeded()
        return write(content.superview ?? content, name, in: directory, scale: 2, trimmingBottom: trim, overlays: overlays)
    }

    /// Where each terminal in `root` paints its background, and in what colour.
    ///
    /// A terminal's background is its container's `layer.backgroundColor`, and
    /// `cacheDisplay` does not draw layer properties: the first screenshots had
    /// a terminal's text floating on nothing, in light grey against white. The
    /// rectangles come back in `root`'s coordinates with the origin at the
    /// bottom left, whichever way `root` is flipped.
    @MainActor
    static func terminalBackgrounds(in root: NSView) -> [(rect: NSRect, color: NSColor)] {
        allViews(of: TerminalContainerView.self, in: root).compactMap { container in
            guard let cgColor = container.layer?.backgroundColor,
                  let color = NSColor(cgColor: cgColor) else { return nil }
            let visible = container.visibleRect
            guard !visible.isEmpty else { return nil }
            return (rect: rectangle(of: visible, in: container, relativeTo: root), color: color)
        }
    }

    /// `rect`, which is in `view`'s coordinates, in `root`'s — with the origin
    /// at the bottom left, whichever way `root` is flipped.
    @MainActor
    static func rectangle(of rect: NSRect, in view: NSView, relativeTo root: NSView) -> NSRect {
        var converted = view.convert(rect, to: root)
        if root.isFlipped { converted.origin.y = root.bounds.height - converted.maxY }
        return converted
    }

    @MainActor
    static func write(
        _ view: NSView,
        _ name: String,
        in directory: URL,
        scale: CGFloat,
        trimmingBottom trim: CGFloat,
        overlays: [Overlay]
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

        var laidOver: [(rect: NSRect, image: CGImage)] = []
        for overlay in overlays {
            var proposed = NSRect(origin: .zero, size: overlay.image.size)
            guard let image = overlay.image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
                say("\(name): a snapshot could not be read as an image")
                continue
            }
            // The view's whole bounds: what it is on screen, clipped or not, is
            // what its picture was taken of.
            let place = rectangle(of: overlay.view.bounds, in: overlay.view, relativeTo: view)
            say("\(name): snapshot of \(Int(overlay.view.bounds.width))x\(Int(overlay.view.bounds.height)) "
                + "(frame \(overlay.view.frame), visible \(overlay.view.visibleRect)) laid at \(place)")
            guard !place.isEmpty else { continue }
            laidOver.append((rect: place, image: image))
        }
        if !overlays.isEmpty { say("\(name): \(laidOver.count) snapshot(s) laid over") }

        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let edge = dark ? NSColor.white.withAlphaComponent(0.22) : NSColor.black.withAlphaComponent(0.20)
        let finished = framed(
            plain,
            trimmingBottom: trim,
            under: backgrounds,
            over: laidOver,
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

    static func bitmap(width: Int, height: Int) -> NSBitmapImageRep? {
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
    static func looksBlank(_ rep: NSBitmapImageRep) -> Bool {
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
    /// `over` is laid on top of it instead, for what the picture has a hole in
    /// that is not transparent — the page in a web view, under the bare
    /// background the panel paints behind it.
    ///
    /// The picture is drawn as a CGImage, which composites over what is under
    /// it. `NSBitmapImageRep.draw(in:)` copies instead — its transparent
    /// pixels replace what was beneath them — which is how a first attempt at
    /// this lost the terminal backgrounds it had just painted.
    ///
    /// Drawn in pixels throughout (the output's size is only set to points at
    /// the end, so the PNG says it is a 2x image). `trim` points are left off
    /// the bottom.
    static func framed(
        _ picture: NSBitmapImageRep,
        trimmingBottom trim: CGFloat,
        under backgrounds: [(rect: NSRect, color: NSColor)],
        over overlays: [(rect: NSRect, image: CGImage)],
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
        for overlay in overlays {
            context.cgContext.draw(overlay.image, in: CGRect(
                x: pad + overlay.rect.minX * scale,
                y: pad + (overlay.rect.minY - trim) * scale,
                width: overlay.rect.width * scale,
                height: overlay.rect.height * scale
            ))
        }
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
}
#endif
