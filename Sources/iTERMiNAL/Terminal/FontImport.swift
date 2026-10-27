import Foundation

/// The rules for fonts a person brings to the terminal, and how they are
/// grouped to be shown. Foundation only, so they are checked off a Mac;
/// `ImportedFonts` does the reading, copying and registering.
enum FontImport {
    /// What macOS reads as a font: TrueType, OpenType, and the two collection
    /// formats. Not `woff`, which is for web pages, and not Type 1 or bitmap
    /// formats, which CoreText no longer takes.
    static let allowedExtensions: Set<String> = ["ttf", "otf", "ttc", "otc"]

    /// Larger than any terminal font — a full CJK face is about this — and a
    /// bound on what one click can copy into the app's folder and hand to the
    /// system's font parser.
    static let maxBytes = 50 * 1024 * 1024

    /// Shown under the font picker, in the font and size the terminal will use.
    /// Letters, digits, the punctuation a shell is made of, the ligature
    /// candidates, and two private-use code points a Nerd Font symbol face
    /// answers — a folder and a git branch — so a missing fallback shows as a
    /// box here before it does in a prompt.
    static let sampleText = """
    The quick brown fox jumps over the lazy dog
    0123456789  {}[]()  <-> => != >= ~/.config
    \u{F07B} \u{E0A0}  Il1 O0o  ┌─┬─┐
    """

    enum Refusal: Equatable {
        case notAFont(String)
        case empty
        case tooLarge

        /// A sentence for the person.
        var message: String {
            switch self {
            case .notAFont(let name):
                return "“\(name)” isn't a font file macOS reads. Use .ttf, .otf, .ttc or .otc."
            case .empty:
                return "That file is empty."
            case .tooLarge:
                return "That file is larger than \(maxBytes / (1024 * 1024)) MB, which is more than a terminal font needs."
            }
        }
    }

    /// Nil when a file called `fileName` of `size` bytes may be imported.
    static func refusal(fileName: String, size: Int) -> Refusal? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else { return .notAFont(fileName) }
        guard size > 0 else { return .empty }
        guard size <= maxBytes else { return .tooLarge }
        return nil
    }

    /// The name a font is kept under in the app's folder. Only the last part of
    /// the path is used — a name with `..` or a slash in it must land in the
    /// folder, not beside it — odd characters become underscores, a name cannot
    /// start with a dot (a hidden file nobody would find to remove), it is kept
    /// to a sane length with its extension intact, and a name already taken gets
    /// a number rather than replacing what is there.
    static func storedName(for fileName: String, existing: Set<String>) -> String {
        let last = (fileName as NSString).lastPathComponent
        let ext = (last as NSString).pathExtension.lowercased()
        var stem = (last as NSString).deletingPathExtension
        stem = String(stem.unicodeScalars.map { scalar -> Character in
            let ok = (scalar.value < 128 && (CharacterSet.alphanumerics.contains(scalar) || " ._-()".unicodeScalars.contains(scalar)))
            return ok ? Character(scalar) : "_"
        })
        while stem.hasPrefix(".") { stem.removeFirst() }
        stem = stem.trimmingCharacters(in: .whitespaces)
        if stem.isEmpty { stem = "font" }
        if stem.count > 80 { stem = String(stem.prefix(80)) }
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var candidate = stem + suffix
        var number = 2
        while existing.contains(candidate) || existing.contains(where: { $0.lowercased() == candidate.lowercased() }) {
            candidate = "\(stem) \(number)\(suffix)"
            number += 1
        }
        return candidate
    }

    /// One face of a font family, as the font file names it.
    struct Face: Equatable {
        var family: String
        var style: String
        var postScriptName: String
    }

    /// A family and its faces, in the order a person expects.
    struct Family: Equatable, Identifiable {
        var name: String
        var faces: [Face]
        var id: String { name }
    }

    /// `faces` grouped by family, families A to Z without regard to case, and
    /// within one the regular first, then bold, italic and bold italic, then
    /// whatever else the font has, alphabetically. A face that appears twice —
    /// the same font imported from two files — is listed once. A face with no
    /// family name is left out: there is nothing to pick it by.
    static func groups(_ faces: [Face]) -> [Family] {
        var seen = Set<String>()
        var byFamily: [String: [Face]] = [:]
        for face in faces {
            let family = face.family.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !family.isEmpty else { continue }
            let key = family + "\u{0}" + face.postScriptName + "\u{0}" + face.style
            guard seen.insert(key).inserted else { continue }
            byFamily[family, default: []].append(face)
        }
        let order = ["regular": 0, "bold": 1, "italic": 2, "bold italic": 3]
        func rank(_ face: Face) -> Int { order[face.style.lowercased()] ?? 4 }
        return byFamily
            .map { name, faces in
                Family(name: name, faces: faces.sorted {
                    (rank($0), $0.style.lowercased()) < (rank($1), $1.style.lowercased())
                })
            }
            .sorted { ($0.name.lowercased(), $0.name) < ($1.name.lowercased(), $1.name) }
    }
}
