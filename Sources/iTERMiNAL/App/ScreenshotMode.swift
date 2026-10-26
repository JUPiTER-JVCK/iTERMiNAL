#if SCREENSHOTS
import AppKit
import SwiftUI

/// Takes the pictures for the README from the real app.
///
/// Compiled only when a build defines `SCREENSHOTS` — the Screenshots workflow
/// does, no shipped build does — and switched on only when the environment
/// names a directory to write into. In every other build these files are empty.
///
/// It drives the app through its own models rather than clicking on it, then
/// asks each window to draw itself into a bitmap (`cacheDisplay`). That needs
/// no Screen Recording permission, which a CI runner will not grant, and gives
/// the same pixels at 2x whatever display the runner happens to have.
///
/// `cacheDisplay` runs each view's `draw(_:)` and nothing else, so what a view
/// paints through a layer property is missing from it. The terminal's
/// background is one (see `terminalBackgrounds`) and is put back by hand; a web
/// view is another, and is put back from a snapshot of it (see `snapshot`).
/// Metal-backed layers are a third, and none of the pictures use them.
///
/// The scenes (ScreenshotScenes.swift) run against a small sample project, a
/// history file, and a local web server that the workflow prepares
/// (scripts/screenshots), so nothing in a picture is anyone's real data.
///
/// - ScreenshotMode.swift: starting up, and waiting and logging.
/// - ScreenshotScenes.swift: what each picture is of, and how the app is put
///   into it.
/// - ScreenshotDriving.swift: the keyboard and the view tree, as a person
///   would meet them.
/// - ScreenshotPictures.swift: windows, bitmaps, and the frame round a picture.
enum ScreenshotMode {
    static let directoryVariable = "ITERMINAL_SCREENSHOT_DIR"
    static let demoVariable = "ITERMINAL_DEMO_DIR"
    static let logVariable = "ITERMINAL_FIXTURE_LOG"

    /// How long the whole run may take before it is given up on.
    static let giveUpAfter: TimeInterval = 840

    /// The composer's assistant, which the composer owns and nothing else can
    /// reach: set when it is made, so a scene can see what it is showing and,
    /// when the app would have made an offer a run on a runner did not, make it.
    @MainActor static weak var composerAssistant: ComposerAIController?

    /// Called once the app has launched.
    static func startIfRequested() {
        guard let path = ProcessInfo.processInfo.environment[directoryVariable], !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        say("writing to \(directory.path)")

        // A job waiting on a window that never came up should end, not hang.
        // Whatever was written by then is still there to look at.
        DispatchQueue.main.asyncAfter(deadline: .now() + giveUpAfter) {
            say("gave up after \(Int(giveUpAfter)) seconds")
            exit(3)
        }
        Task { @MainActor in
            await run(into: directory)
            say("finished")
            exit(0)
        }
    }

    @MainActor
    private static func run(into directory: URL) async {
        describeDisplays()
        guard let window = await mainWindow() else {
            say("no main window appeared")
            return
        }
        await ScreenshotRun(window: window, directory: directory).runAll()
    }

    // MARK: Waiting and logging

    static func pause(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    @MainActor
    static func until(timeout: TimeInterval, _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            await pause(0.2)
        }
        return condition()
    }

    static func say(_ message: String) {
        print("[screenshots] \(message)")
        fflush(stdout)
    }
}

extension Notification.Name {
    /// Asks the sidebar to open every workspace's folder. The folders start
    /// shut, and a picture of the sidebar is of what is in them.
    static let screenshotsExpandSidebar = Notification.Name("iTERMiNAL.screenshots.expandSidebar")
}
#endif
