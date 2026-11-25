import AppKit

/// Keeps the Dock icon matched to the app's appearance.
///
/// The icon in the bundle is the dark keycap. An asset-catalog icon cannot
/// switch with the appearance on the toolchain this is built with (that takes
/// an Icon Composer file and Xcode 26), so while the app runs the Dock is given
/// the light keycap when the app is light and put back to the bundle's when it
/// is dark. Finder, Launchpad and the app switcher read the bundle and so show
/// the dark one either way.
///
/// This follows `NSApp.effectiveAppearance`, which already folds in the
/// Light / Dark / System choice in Settings (see `AppSettings.applyAppearance`):
/// on System it is the Mac's appearance, and on Light or Dark it is that.
final class DockIcon {
    static let shared = DockIcon()

    private var observation: NSKeyValueObservation?

    private init() {}

    /// Applies the icon for the current appearance, then again on each change.
    func start() {
        guard observation == nil else { return }
        observation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { app, _ in
            DockIcon.apply(to: app)
        }
    }

    private static func apply(to app: NSApplication) {
        let dark = app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // nil restores the icon from the bundle. A missing image set leaves
        // that in place too, so a damaged catalog degrades to the dark icon.
        app.applicationIconImage = dark ? nil : NSImage(named: "DockIconLight")
    }
}
