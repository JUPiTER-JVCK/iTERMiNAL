import Foundation

/// A command-line program that ships inside the app and is on the `PATH` of
/// every local terminal tab — ripgrep, bat and imgcat.
///
/// Not a panel like `TerminalTool` (superfile, btop), which the app launches
/// itself: these are for a person to type. They live apart, in `Tools/bin`, so
/// that folder is the only thing added to `PATH` and the panel tools do not
/// ride along with it.
///
/// Fetched by `scripts/fetch-cli-tools.sh` at the versions pinned in
/// `scripts/tools.env`, copied into the bundle with the rest of `Vendor/Tools`,
/// and checked there by CI — present, universal, linking only system
/// libraries, and able to run.
enum BundledCommand: String, CaseIterable, Identifiable {
    case ripgrep
    case bat
    case imgcat

    var id: String { rawValue }

    /// What it is typed as.
    var executableName: String {
        switch self {
        case .ripgrep: return "rg"
        case .bat: return "bat"
        case .imgcat: return "imgcat"
        }
    }

    var title: String {
        switch self {
        case .ripgrep: return "ripgrep (rg)"
        case .bat: return "bat"
        case .imgcat: return "imgcat"
        }
    }

    /// One line on what it is, for the About list.
    var summary: String {
        switch self {
        case .ripgrep: return "Fast regex search"
        case .bat: return "cat with syntax highlighting"
        case .imgcat: return "Show an image in the terminal"
        }
    }

    var icon: String {
        switch self {
        case .ripgrep: return "magnifyingglass"
        case .bat: return "doc.text"
        case .imgcat: return "photo"
        }
    }

    var homepage: URL {
        switch self {
        case .ripgrep: return URL(string: "https://github.com/BurntSushi/ripgrep")!
        case .bat: return URL(string: "https://github.com/sharkdp/bat")!
        case .imgcat: return URL(string: "https://github.com/JUPiTER-JVCK/iTERMiNAL")!
        }
    }

    var licenseName: String {
        switch self {
        case .ripgrep: return "MIT or Unlicense"
        case .bat: return "MIT or Apache-2.0"
        case .imgcat: return "MIT"
        }
    }

    /// The key CI writes its version under in `manifest.json`; nil for the one
    /// that is this repository's own script.
    var manifestKey: String? {
        switch self {
        case .ripgrep: return "ripgrep"
        case .bat: return "bat"
        case .imgcat: return nil
        }
    }

    // MARK: Where it lives

    /// `Contents/Resources/Tools/bin`: the folder put on `PATH`.
    static var directory: URL? {
        TerminalTool.bundledDirectory?.appendingPathComponent("bin", isDirectory: true)
    }

    /// The copy inside this app, when the build included one.
    var bundledURL: URL? {
        guard let url = Self.directory?.appendingPathComponent(executableName),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    var isBundled: Bool { bundledURL != nil }

    /// Named `<name>-LICENSE.txt` by the script that fetches them; the script
    /// is this repository's own, whose licence is the repository's.
    var licenseURL: URL? {
        let name: String
        switch self {
        case .ripgrep: name = "ripgrep-LICENSE.txt"
        case .bat: name = "bat-LICENSE.txt"
        case .imgcat: return nil
        }
        guard let url = TerminalTool.bundledDirectory?
            .appendingPathComponent("licenses", isDirectory: true)
            .appendingPathComponent(name),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// The version CI bundled, read from the manifest it wrote beside the
    /// binaries — not a constant in this file, which could drift from what
    /// actually shipped.
    var bundledVersion: String? {
        guard let key = manifestKey,
              let url = TerminalTool.bundledDirectory?.appendingPathComponent("manifest.json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }
        return manifest[key]
    }
}
