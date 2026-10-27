import AppKit
import CoreText

/// Fonts brought to the terminal by the person using it.
///
/// Copied into the app's own folder (`~/Library/Application Support/iTERMiNAL/Fonts`)
/// and registered with CoreText for this process only — the same way the Nerd
/// Font symbols face is. Nothing is installed on the Mac: they do not appear in
/// Font Book or in any other app, and removing one here deletes the copy.
///
/// The file is read by macOS's own font parser, which is the one place an
/// untrusted font could do harm; what this does to limit that is what
/// `FontImport` decides — only the four font extensions, a size cap, and a
/// name that cannot leave the folder — and that a font is only ever imported
/// by the person choosing it.
final class ImportedFonts: ObservableObject {
    static let shared = ImportedFonts()

    struct Entry: Identifiable, Equatable {
        /// The name the copy is kept under.
        let fileName: String
        let faces: [FontImport.Face]
        var id: String { fileName }
        var url: URL { ImportedFonts.directory.appendingPathComponent(fileName) }
    }

    enum Failure: Error, Equatable {
        case refused(FontImport.Refusal)
        case unreadable(String)
        case notRegistered

        var message: String {
            switch self {
            case .refused(let refusal): return refusal.message
            case .unreadable(let name): return "Couldn't read “\(name)”."
            case .notRegistered: return "macOS did not accept that font. It may be damaged, or not a font after all."
            }
        }
    }

    @Published private(set) var entries: [Entry] = []

    /// Every face imported, grouped by family.
    var families: [FontImport.Family] {
        FontImport.groups(entries.flatMap(\.faces))
    }

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("iTERMiNAL", isDirectory: true)
            .appendingPathComponent("Fonts", isDirectory: true)
    }

    private init() {
        reload()
    }

    /// Reads the folder and registers what is in it. Called once, when the
    /// first terminal font is asked for, and again after any change.
    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Self.directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var found: [Entry] = []
        for url in urls.sorted(by: { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }) {
            guard FontImport.allowedExtensions.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let faces = Self.register(url) else { continue }
            found.append(Entry(fileName: url.lastPathComponent, faces: faces))
        }
        entries = found
    }

    /// Copies `source` into the folder, registers it, and returns the families
    /// it adds. A file that macOS will not take is removed again.
    @discardableResult
    func importFont(from chosen: URL) -> Result<[String], Failure> {
        // The file itself, not a link to one: what is copied is what was
        // measured, and a link left in the folder would be skipped when it is
        // read back.
        let source = chosen.resolvingSymlinksInPath()
        let name = chosen.lastPathComponent
        let values = try? source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true else { return .failure(.unreadable(name)) }
        if let refusal = FontImport.refusal(fileName: name, size: values?.fileSize ?? 0) {
            return .failure(.refused(refusal))
        }
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        } catch {
            return .failure(.unreadable(name))
        }
        let taken = Set((try? fileManager.contentsOfDirectory(atPath: Self.directory.path)) ?? [])
        let stored = FontImport.storedName(for: name, existing: taken)
        let destination = Self.directory.appendingPathComponent(stored)
        do {
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            return .failure(.unreadable(name))
        }
        guard let faces = Self.register(destination) else {
            try? fileManager.removeItem(at: destination)
            return .failure(.notRegistered)
        }
        reload()
        return .success(Array(Set(faces.map(\.family))).sorted())
    }

    /// Deletes the copy and takes the font out of this process.
    func remove(_ entry: Entry) {
        CTFontManagerUnregisterFontsForURL(entry.url as CFURL, .process, nil)
        try? FileManager.default.removeItem(at: entry.url)
        reload()
    }

    /// Registers `url` for this process and lists what is in it, or nil when
    /// macOS finds no font there.
    ///
    /// A second registration of the same file reports "already registered",
    /// which is not a failure, so the result of the call is not what decides:
    /// whether the file holds faces CoreText can describe is.
    private static func register(_ url: URL) -> [FontImport.Face]? {
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              !descriptors.isEmpty else { return nil }
        let faces = descriptors.compactMap { descriptor -> FontImport.Face? in
            guard let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String,
                  let postScript = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String else { return nil }
            let style = CTFontDescriptorCopyAttribute(descriptor, kCTFontStyleNameAttribute) as? String ?? "Regular"
            return FontImport.Face(family: family, style: style, postScriptName: postScript)
        }
        return faces.isEmpty ? nil : faces
    }
}
