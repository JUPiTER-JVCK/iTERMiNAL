import Foundation

/// What a file is, as far as its first bytes say.
struct FormatIdentity: Equatable {
    let id: String
    let name: String
    let detail: String
    /// Whether there is a structure view for it.
    let hasParser: Bool
}

/// What a parser is allowed to spend. The dump never waits for a parser, but a
/// parser that was given a hostile file still has to finish.
struct ParseContext {
    /// The most records — packets, chunks, blocks — listed. More than this are in the
    /// file, and in the dump, but not in the tree.
    var maxRecords = 100_000
    /// Asked every so often by a parser that loops; true means stop and hand back
    /// what there is.
    var isCancelled: () -> Bool = { false }
    /// The file's name, for the formats that have no signature and are known by their extension as much as by
    /// their bytes: a CSV is text until its name says otherwise.
    var fileName: String?
}

/// What a parser found.
struct ParseOutcome {
    var roots: [FieldNode] = []
    /// Things wrong with the file as a whole, in words.
    var problems: [String] = []
    /// One line: "PNG, 3 × 2, 8-bit RGB, 8 chunks".
    var summary: String?
    /// Set when the tree stops short of the end of the file, and says why.
    var listingLimit: String?
    /// What the file turned out to be, when that takes more than its first bytes to say: a compound file is a
    /// Word document if it has a WordDocument stream.
    var identity: FormatIdentity?
}

/// One kind of file that can be taken apart.
///
/// A parser is given a `ByteSource` and reads what it needs through it: never the
/// whole file, never more than a few kilobytes at once. It does not trust the file:
/// every length it reads is checked against what is there, every loop has a limit,
/// and what does not add up becomes a `problem` node and not a crash.
protocol FormatParser {
    static var identity: FormatIdentity { get }
    /// Whether the start of the file (its first few kilobytes) looks like this format.
    static func matches(head: [UInt8], length: Int64) -> Bool
    /// The same, knowing the file's name. Most formats go by their bytes alone and leave this as it is.
    static func matches(head: [UInt8], length: Int64, name: String?) -> Bool
    static func parse(_ source: ByteSource, context: ParseContext) -> ParseOutcome
    /// Other formats, by id, this parser also takes apart: one that reads a container
    /// shared by several kinds of file says here which kinds.
    static var alsoParses: [String] { get }
}

extension FormatParser {
    static var alsoParses: [String] { [] }

    static func matches(head: [UInt8], length: Int64, name: String?) -> Bool {
        matches(head: head, length: length)
    }
}

/// The answer for one file: what it was taken for, what was found, and what to say
/// when there is nothing to show.
struct StructureResult {
    var identity: FormatIdentity?
    var outcome: ParseOutcome
    /// Empty when there is a tree to show.
    var message: String
}

enum FormatRegistry {
    /// In the order they are tried.
    static let parsers: [FormatParser.Type] = [PNGParser.self, PcapParser.self, PcapNGParser.self, JPEGParser.self, MP4Parser.self, PDFParser.self, GIFParser.self, BMPParser.self, ICOParser.self, WebPParser.self, TIFFParser.self, JXLParser.self, ZIPParser.self, ELFParser.self, MachOParser.self, CFBParser.self,
                                                 // Last, as they have no signature: what is left that reads as text.
                                                 TableParser.self, TextParser.self]

    static var parserIDs: Set<String> {
        Set(parsers.flatMap { [$0.identity.id] + $0.alsoParses })
    }

    /// Takes `source` apart if a parser knows the format; says what it is if not; and
    /// never fails: a file nothing recognises gets an honest line saying so.
    static func analyze(_ source: ByteSource, context: ParseContext = ParseContext()) -> StructureResult {
        let head = source.read(0..<4096)
        for parser in parsers where parser.matches(head: head, length: source.count, name: context.fileName) {
            var identity = parser.identity
            if !parser.alsoParses.isEmpty, let named = FormatDetector.identify(head: head, length: source.count),
               parser.alsoParses.contains(named.id) {
                identity = named
            }
            let outcome = parser.parse(source, context: context)
            return StructureResult(identity: outcome.identity ?? identity, outcome: outcome, message: "")
        }
        let identity = FormatDetector.identify(head: head, length: source.count)
        let tail = "The Hex and Bits views show every byte of any file."
        if let identity {
            return StructureResult(identity: identity, outcome: ParseOutcome(),
                                   message: "This looks like \(identity.name). There is no structure view for it yet. \(tail)")
        }
        return StructureResult(identity: nil, outcome: ParseOutcome(),
                               message: "Nothing at the start of this file says what it is, so there is no structure to show. \(tail)")
    }
}
