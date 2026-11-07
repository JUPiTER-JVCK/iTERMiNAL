import Foundation

/// The examples from tldr-pages (CC BY 4.0), as `scripts/tldr-convert.py`
/// writes them into `Cheatsheets/tldr.json` and the app bundles them.
///
/// The file is a version-1 document:
///
///     {"format":1,"version":"2.3","pages":[
///       {"n":"tar","p":"common","s":"Archiving utility.","u":"https://…",
///        "x":[["Create an archive…","tar cf {{target}} {{file}}"],
///             ["Unpack a part…","git add {{file}}","add"]]}]}
///
/// `x` is a list of `[description, command]`, with the subcommand's name as a
/// third item when the example came from a subcommand's own page.
enum TldrData {
    /// The document layout this reads. The converter writes it, so a change to
    /// one is a change to the other.
    static let supportedFormat = 1

    struct Loaded {
        var programs: [CheatProgram]
        var version: String
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case unreadable
        case unsupportedFormat(Int)

        var description: String {
            switch self {
            case .unreadable:
                return "the file is not the cheatsheet data this version reads"
            case .unsupportedFormat(let format):
                return "the data is in format \(format), and this version reads format \(TldrData.supportedFormat)"
            }
        }
    }

    private struct Document: Decodable {
        var format: Int
        var version: String
        var pages: [Page]
    }

    private struct Page: Decodable {
        var n: String
        var s: String
        var u: String?
        var x: [[String]]
    }

    /// The programs in `data`. A page or an example that is not shaped as
    /// described is left out rather than failing the rest.
    static func decode(_ data: Data) throws -> Loaded {
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw Failure.unreadable
        }
        guard document.format == supportedFormat else { throw Failure.unsupportedFormat(document.format) }

        var programs: [CheatProgram] = []
        programs.reserveCapacity(document.pages.count)
        for page in document.pages where !page.n.isEmpty {
            var examples: [CheatExample] = []
            examples.reserveCapacity(page.x.count)
            for entry in page.x {
                guard entry.count == 2 || entry.count == 3, !entry[0].isEmpty, !entry[1].isEmpty else { continue }
                examples.append(CheatExample(
                    description: entry[0],
                    command: entry[1],
                    source: .tldr,
                    intent: "",
                    section: entry.count == 3 && !entry[2].isEmpty ? entry[2] : nil
                ))
            }
            guard !examples.isEmpty else { continue }
            programs.append(CheatProgram(
                name: page.n,
                summary: page.s,
                syntax: [],
                tags: [],
                examples: examples,
                isCurated: false,
                url: webAddress(page.u)
            ))
        }
        return Loaded(programs: programs, version: document.version)
    }

    /// `text` if it is an http or https address, so the page never offers a
    /// link that opens something else.
    static func webAddress(_ text: String?) -> String? {
        guard let text, text.hasPrefix("https://") || text.hasPrefix("http://") else { return nil }
        return text
    }
}

/// Where tldr-pages' data is kept inside the app, and what travels with it.
///
/// `Contents/Resources/Cheatsheets`, put there by project.yml's copy phase from what
/// scripts/fetch-tldr.sh made. A local build made without running that script has
/// no such folder, and everything here says so by returning nil, as the font does.
enum TldrBundle {
    static let homepage = URL(string: "https://github.com/tldr-pages/tldr")

    static var directory: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Cheatsheets", isDirectory: true)
    }

    /// The data file, when this build has one.
    static var dataURL: URL? { dataURL(in: directory) }

    /// The CC BY 4.0 notice that ships with it.
    static var licenseURL: URL? { licenseURL(in: directory) }

    /// The version the fetch script wrote beside the data, not a constant here that
    /// could drift from what shipped.
    static var version: String? { version(in: directory) }

    static func dataURL(in directory: URL?) -> URL? {
        existing(directory?.appendingPathComponent("tldr.json"))
    }

    static func licenseURL(in directory: URL?) -> URL? {
        existing(directory?.appendingPathComponent("licenses", isDirectory: true).appendingPathComponent("tldr-pages-LICENSE.md"))
    }

    static func version(in directory: URL?) -> String? {
        guard let url = directory?.appendingPathComponent("manifest.json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        return manifest["tldr-pages"]
    }

    private static func existing(_ url: URL?) -> URL? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}
