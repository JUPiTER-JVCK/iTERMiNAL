import AppKit

/// Opening folders from outside the window: the Services menu ("New iTERMiNAL
/// Tab at Folder"), a folder dropped on the Dock icon, Open With in Finder, and
/// `open -a iTERMiNAL <folder>`. Which folders, and how many, is `OpenFolders`;
/// the Info.plist entries that make macOS offer all this are in `project.yml`.
///
/// Main thread only, like the AppKit calls that reach it.
final class FinderIntegration: NSObject {
    static let shared = FinderIntegration()

    /// Makes the Services entry reachable: AppKit sends its `NSMessage` to the
    /// object set here. Called once, at launch.
    func register() {
        NSApp.servicesProvider = self
    }

    // MARK: Services

    /// The service. Its selector is the `NSMessage` in Info.plist
    /// (`openTabAtFolder`) and the two must stay in step; the build reads the
    /// plist side back (Verify bundle contents).
    ///
    /// Reads the pasteboard for files and, if there are none, for a path
    /// written out as text — the declaration lets a path selected in any app
    /// offer the service, the way Finder's right-click menu does. Whatever is
    /// there, nothing is run: a tab is opened in each folder and that is all.
    @objc(openTabAtFolder:userData:error:)
    func openTabAtFolder(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        var paths = Self.filePaths(on: pasteboard)
        if paths.isEmpty, let text = pasteboard.string(forType: .string) {
            paths = OpenFolders.paths(inText: text, home: NSHomeDirectory())
        }
        if open(paths: paths) == 0 {
            error.pointee = "There is no folder here to open." as NSString
        }
    }

    // MARK: Opening

    /// A folder dropped on the Dock icon, Open With, or `open -a`.
    func open(urls: [URL]) {
        open(paths: urls.filter(\.isFileURL).map(Self.path(of:)))
    }

    /// Opens a tab in each folder `paths` comes to, and says how many. A file
    /// opens the folder it is in.
    @discardableResult
    private func open(paths: [String]) -> Int {
        let plan = OpenFolders.plan(for: paths, kind: Self.kind(of:))
        for folder in plan.folders {
            WorkspaceStore.shared.newTab(directory: folder)
        }
        if !plan.folders.isEmpty { bringForward() }
        if plan.leftOut > 0 { tellAboutLimit(opened: plan.folders.count, leftOut: plan.leftOut) }
        return plan.folders.count
    }

    /// Comes to the front, and brings the main window out of the Dock if it was
    /// put there. The window is found by its title: Settings and a remote
    /// desktop are windows of this app too.
    private func bringForward() {
        NSApp.activate()
        guard let window = NSApp.windows.first(where: { $0.title == "iTERMiNAL" }) else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    /// Otherwise the folders after the limit would just not be there, with
    /// nothing to say why.
    private func tellAboutLimit(opened: Int, leftOut: Int) {
        let alert = NSAlert()
        alert.messageText = "Opened \(opened) of \(opened + leftOut) folders"
        alert.informativeText = "iTERMiNAL opens at most \(OpenFolders.limit) tabs at once. Open the rest in a second go."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: Reading what was sent

    /// The files on a pasteboard, as paths.
    private static func filePaths(on pasteboard: NSPasteboard) -> [String] {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        return urls.map(path(of:))
    }

    /// `filePathURL` turns the `/.file/id=…` form a file reference can take into
    /// the real path; an ordinary file URL comes back as itself.
    private static func path(of url: URL) -> String {
        (((url as NSURL).filePathURL) ?? url).path
    }

    private static func kind(of path: String) -> OpenFolders.Kind {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return .missing }
        return isDirectory.boolValue ? .folder : .file
    }
}
