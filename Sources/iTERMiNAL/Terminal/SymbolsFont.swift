import AppKit
import CoreText

/// The Nerd Font symbols face the app bundles, and the fallback that puts it
/// behind whatever font the terminal uses.
///
/// superfile draws its file and folder icons from Nerd Font code points in
/// Unicode's Private Use Area, and so do shell prompts like Starship and `ls`
/// replacements like eza. No font macOS ships has glyphs there, so with an
/// ordinary font every one of those icons drew as an empty box. The fix is
/// the one Ghostty and WezTerm ship: bundle the symbols-only face and give the
/// terminal font a cascade list that points at it. CoreText consults a cascade
/// list only for characters the primary font lacks, so nothing the user's
/// font can draw changes — letters, box drawing and emoji all render as they
/// did.
///
/// Registered for this process only. Nothing is installed on the Mac, and the
/// face never appears in Font Book or other apps.
///
/// Self-contained on purpose: CI compiles this file on its own, next to a
/// small check, to prove CoreText really resolves the icons to this face —
/// something no amount of reading the code can settle.
enum SymbolsFont {
    static let fileName = "SymbolsNerdFontMono-Regular.ttf"
    static let familyName = "Symbols Nerd Font Mono"

    /// `Contents/Resources/Fonts`, where project.yml's copy phase puts it.
    static var directory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Fonts", isDirectory: true)
    }

    /// The bundled file, when this build has one — a local build made without
    /// running `scripts/fetch-symbols-font.sh` does not.
    static var bundledURL: URL? {
        guard let url = directory?.appendingPathComponent(fileName),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Registered once, on first use rather than at launch, so there is no
    /// ordering to get wrong: the first terminal font asked for is the first
    /// thing that needs it.
    private static let bundledDescriptor: NSFontDescriptor? = bundledURL.flatMap { register($0) }

    /// Whether the fallback is in effect in this build.
    static var isAvailable: Bool { bundledDescriptor != nil }

    static let homepage = URL(string: "https://github.com/ryanoasis/nerd-fonts")!

    /// The MIT notice; the README beside it credits each icon set.
    static var licenseURL: URL? {
        guard let url = directory?
            .appendingPathComponent("licenses", isDirectory: true)
            .appendingPathComponent("nerd-fonts-symbols-LICENSE.txt"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// The version the fetch script wrote beside the font, not a constant
    /// here that could drift from what shipped.
    static var bundledVersion: String? {
        guard let url = directory?.appendingPathComponent("manifest.json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }
        return manifest["nerd-fonts-symbols"]
    }

    /// `font` with the bundled symbols face as its fallback for missing
    /// characters, or `font` unchanged when this build has no symbols face.
    static func withFallback(_ font: NSFont) -> NSFont {
        guard let symbols = bundledDescriptor else { return font }
        return font.cascading(to: symbols)
    }

    /// Registers the face in `url` for this process and returns a descriptor
    /// that finds it by name, or nil if it cannot be loaded.
    ///
    /// The descriptor is built from the name inside the file rather than a
    /// constant here, and only returned once a font actually resolves from
    /// it — a registration that silently failed would otherwise leave a
    /// cascade entry pointing at nothing.
    static func register(_ url: URL) -> NSFontDescriptor? {
        // A second registration of the same file reports "already
        // registered", which is not a failure; the lookup below is the test
        // that matters either way.
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first,
              let name = CTFontDescriptorCopyAttribute(first, kCTFontNameAttribute) as? String else {
            return nil
        }
        let descriptor = NSFontDescriptor(fontAttributes: [.name: name])
        guard NSFont(descriptor: descriptor, size: 12) != nil else { return nil }
        return descriptor
    }
}

extension NSFont {
    /// This font with `fallback` consulted first for characters it lacks,
    /// ahead of any cascade list it already had.
    func cascading(to fallback: NSFontDescriptor) -> NSFont {
        let existing = fontDescriptor.object(forKey: .cascadeList) as? [NSFontDescriptor] ?? []
        let descriptor = fontDescriptor.addingAttributes([.cascadeList: [fallback] + existing])
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
