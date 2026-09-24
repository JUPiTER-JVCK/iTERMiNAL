import Foundation

/// A full-screen terminal program that ships inside the app and opens as a
/// side panel: superfile for files, btop for the machine.
///
/// These are the only third-party executables in the bundle. Both are fetched
/// or built by `scripts/` at the versions pinned in `scripts/tools.env`, copied
/// to `Contents/Resources/Tools`, and checked there by CI — present,
/// universal, linking only system libraries, and able to run.
enum TerminalTool: String, CaseIterable, Identifiable {
    case superfile
    case btop

    var id: String { rawValue }

    /// What the binary is called, in the bundle and on `PATH` alike.
    var executableName: String {
        switch self {
        case .superfile: return "spf"
        case .btop: return "btop"
        }
    }

    var title: String {
        switch self {
        case .superfile: return "superfile"
        case .btop: return "btop"
        }
    }

    /// One line on what it is, for tooltips and the About list.
    var summary: String {
        switch self {
        case .superfile: return "Terminal file manager"
        case .btop: return "Resource monitor"
        }
    }

    /// SF Symbols, so the two sit beside the panel toggles as equals — both
    /// exist on macOS 14.
    var icon: String {
        switch self {
        case .superfile: return "folder.badge.gearshape"
        case .btop: return "gauge.with.dots.needle.67percent"
        }
    }

    var homepage: URL {
        switch self {
        case .superfile: return URL(string: "https://github.com/yorukot/superfile")!
        case .btop: return URL(string: "https://github.com/aristocratos/btop")!
        }
    }

    var licenseName: String {
        switch self {
        case .superfile: return "MIT"
        case .btop: return "Apache-2.0"
        }
    }

    // MARK: Where it lives

    static var bundledDirectory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Tools", isDirectory: true)
    }

    /// The copy inside this app, when the build included one.
    var bundledURL: URL? {
        guard let url = Self.bundledDirectory?.appendingPathComponent(executableName),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    /// The binary to launch: the bundled one, or — for a local build made
    /// without `Vendor/Tools` — one the user installed themselves.
    ///
    /// Bundled first, deliberately. The bundled version is the one CI checked,
    /// and preferring whatever happens to be on `PATH` would make the same app
    /// behave differently on two Macs for reasons neither user can see.
    var resolvedExecutable: String? {
        if let bundledURL { return bundledURL.path }
        return SessionLaunch.resolveExecutable(executableName)
    }

    var isBundled: Bool { bundledURL != nil }

    /// Named `<rawValue>-LICENSE.txt` by the scripts that fetch them.
    var licenseURL: URL? {
        guard let url = Self.bundledDirectory?
            .appendingPathComponent("licenses", isDirectory: true)
            .appendingPathComponent("\(rawValue)-LICENSE.txt"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// The version CI bundled, read from the manifest it wrote alongside the
    /// binaries — not a constant in this file, which could drift from what
    /// actually shipped.
    var bundledVersion: String? {
        guard let url = Self.bundledDirectory?.appendingPathComponent("manifest.json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }
        return manifest[rawValue]
    }

    /// Arguments for a launch that starts in `directory`.
    ///
    /// superfile takes a path and opens there, so it lands where the user was
    /// working. btop has no use for one.
    func arguments(directory: String?) -> [String] {
        switch self {
        case .superfile:
            guard let directory, !directory.isEmpty else { return [] }
            return [directory]
        case .btop:
            return []
        }
    }
}
