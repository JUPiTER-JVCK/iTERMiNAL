import Foundation

// The site explorer's command line, as pure logic: what a typed line means,
// what is allowed to be fetched, and how results are laid out as text. The
// model that runs it (SiteExplorerModel) and the view that shows it hold no
// decisions of their own that aren't checked here.

// MARK: - Commands

enum ExplorerCommand: Equatable {
    case empty
    case help
    case clear
    case pwd
    case info
    case refresh
    case ls(path: String?, long: Bool)
    case cd(path: String?)
    case tree(path: String?, depth: Int)
    case find(String)
    /// Fetch one address on this site and print what came back.
    case get(path: String?)
    /// Load an address into the request builder, without sending it.
    case request(path: String?)
    /// Map another site.
    case open(String)
    /// Something that can't be run, and what to tell the person.
    case invalid(String)
}

enum ExplorerCommandParser {
    static let defaultTreeDepth = 3
    static let maxTreeDepth = 8

    /// `siteIsOpen` decides what a bare address means: with no site open, an
    /// address typed on its own opens it — "when an address is entered" —
    /// while with one open, a stray word is an unknown command rather than a
    /// guess that it was meant as a host.
    static func parse(_ line: String, siteIsOpen: Bool) -> ExplorerCommand {
        guard let words = split(line) else { return .invalid("unterminated quote") }
        guard let first = words.first else { return .empty }
        let args = Array(words.dropFirst())

        switch first.lowercased() {
        case "help", "?": return .help
        case "clear", "cls": return .clear
        case "pwd": return .pwd
        case "info", "sources": return .info
        case "refresh": return .refresh
        case "ls", "dir": return parseLs(args, long: false)
        case "ll": return parseLs(args, long: true)
        case "cd":
            guard args.count <= 1 else { return .invalid("cd: too many arguments") }
            return .cd(path: args.first)
        case "tree": return parseTree(args)
        case "find":
            let needle = args.joined(separator: " ")
            return needle.isEmpty ? .invalid("find: what are you looking for? (find <text>)") : .find(needle)
        case "get", "cat":
            guard args.count <= 1 else { return .invalid("\(first): one address at a time") }
            return .get(path: args.first)
        case "req", "request":
            guard args.count <= 1 else { return .invalid("\(first): one address at a time") }
            return .request(path: args.first)
        case "open":
            guard args.count == 1 else { return .invalid("open: give one address (open example.com)") }
            return .open(args[0])
        default:
            if !siteIsOpen, args.isEmpty, looksLikeAddress(first) { return .open(first) }
            return .invalid("command not found: \(first)  (try `help`)")
        }
    }

    private static func parseLs(_ args: [String], long: Bool) -> ExplorerCommand {
        var isLong = long
        var paths: [String] = []
        for arg in args {
            if arg.hasPrefix("-"), arg.count > 1 {
                for flag in arg.dropFirst() {
                    switch flag {
                    case "l": isLong = true
                    case "1", "a": continue  // one per line already; nothing is hidden
                    default: return .invalid("ls: invalid option -- '\(flag)'")
                    }
                }
            } else {
                paths.append(arg)
            }
        }
        guard paths.count <= 1 else { return .invalid("ls: one path at a time") }
        return .ls(path: paths.first, long: isLong)
    }

    private static func parseTree(_ args: [String]) -> ExplorerCommand {
        var depth = defaultTreeDepth
        var path: String?
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "-L" {
                guard index + 1 < args.count, let value = Int(args[index + 1]), value >= 1 else {
                    return .invalid("tree: -L needs a depth of 1 or more")
                }
                depth = min(value, maxTreeDepth)
                index += 2
            } else if arg.hasPrefix("-L"), let value = Int(arg.dropFirst(2)), value >= 1 {
                depth = min(value, maxTreeDepth)
                index += 1
            } else if arg.hasPrefix("-"), arg.count > 1 {
                return .invalid("tree: invalid option \(arg)")
            } else {
                guard path == nil else { return .invalid("tree: one path at a time") }
                path = arg
                index += 1
            }
        }
        return .tree(path: path, depth: depth)
    }

    /// A word that reads as somewhere to connect to: has a scheme, is
    /// `localhost`, or has a dot in it. Used only when no site is open yet.
    static func looksLikeAddress(_ word: String) -> Bool {
        let lowered = word.lowercased()
        if lowered.contains("://") { return true }
        if lowered == "localhost" || lowered.hasPrefix("localhost:") { return true }
        return lowered.contains(".") && !lowered.hasPrefix(".") && !lowered.hasPrefix("/")
    }

    /// Splits a line into words on whitespace, honouring single and double
    /// quotes and backslash escapes. Nil on an unterminated quote.
    static func split(_ line: String) -> [String]? {
        var words: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaping = false

        for character in line {
            if escaping {
                current.append(character)
                escaping = false
                inWord = true
            } else if character == "\\" && quote != "'" {
                escaping = true
                inWord = true
            } else if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                inWord = true
            } else if character == " " || character == "\t" {
                if inWord { words.append(current); current = ""; inWord = false }
            } else {
                current.append(character)
                inWord = true
            }
        }
        if quote != nil { return nil }
        if escaping { current.append("\\") }
        if inWord { words.append(current) }
        return words
    }
}

// MARK: - What may be fetched

/// The limits on discovery, and the one rule that matters most: **only what
/// the site declared is fetched.** Everything here is a function of text the
/// site itself published — nothing builds an address from a convention, a
/// wordlist or a guess. A site that declares no sitemap gets no sitemap
/// request; there is no fall-back to `/sitemap.xml`.
enum ExplorerPolicy {
    /// Sitemap files read in one `open`, across every level of an index.
    static let maxSitemapFiles = 40
    /// How deep an index may point at further indexes.
    static let maxSitemapDepth = 3
    /// Paths taken from sitemaps in one `open`. Past this the rest are
    /// counted and not stored.
    static let maxEntries = 25_000
    /// Sitemaps requested at once. Low on purpose: this is someone else's
    /// server.
    static let sitemapConcurrency = 4

    static let bodyPreviewLines = 40
    static let maxLineLength = 400
    static let maxTranscriptLines = 2_000
    static let maxFindResults = 200
    static let maxTreeLines = 500

    /// The first thing asked of any site: its robots.txt, at the root. This
    /// is a published, standard location, not a guess at a path.
    static func robotsURL(for origin: SiteOrigin) -> String {
        origin.root + "/robots.txt"
    }

    struct SitemapTargets: Equatable {
        /// Absolute URLs to request.
        var fetch: [String] = []
        /// Declared, but on another origin — never requested. A robots.txt
        /// that says `Sitemap: https://somewhere-else/…` is not allowed to
        /// make this app send a request there.
        var foreign: [String] = []
        /// Not an address at all.
        var invalid: [String] = []
        /// Declared, same origin, but past `budget`.
        var overBudget = 0
    }

    /// Which of the sitemap addresses a site declared may be fetched.
    ///
    /// Same origin only, compared exactly. A value written as a bare
    /// root-relative path (`/sitemap.xml`) is read against the site's origin:
    /// the site wrote it, so it is a declaration, however sloppy.
    static func sitemapTargets(
        declared: [String],
        origin: SiteOrigin,
        alreadySeen: Set<String>,
        budget: Int
    ) -> SitemapTargets {
        var result = SitemapTargets()
        var seen = alreadySeen
        for value in declared {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let absolute: String
            if trimmed.hasPrefix("/"), !trimmed.hasPrefix("//") {
                absolute = origin.root + trimmed
            } else {
                absolute = trimmed
            }
            guard let url = URL(string: absolute), let candidate = SiteOrigin(url: url) else {
                if !trimmed.isEmpty { result.invalid.append(trimmed) }
                continue
            }
            guard candidate == origin else {
                result.foreign.append(absolute)
                continue
            }
            guard seen.insert(absolute).inserted else { continue }
            if result.fetch.count >= max(0, budget) {
                result.overBudget += 1
                continue
            }
            result.fetch.append(absolute)
        }
        return result
    }
}

// MARK: - Resolving what was typed

enum ExplorerTarget: Equatable {
    case url(String)
    case error(String)

    /// The address `get` and `req` mean. A path is read against the current
    /// directory; a full URL must be on the site being explored.
    static func resolve(argument: String?, cwd: [String], tree: SitePathTree) -> ExplorerTarget {
        guard let argument, !argument.isEmpty else {
            return .url(tree.url(for: cwd))
        }
        if argument.contains("://") {
            guard let url = URL(string: argument), tree.origin.contains(url) else {
                return .error("that address isn't on \(tree.origin.display) — `open` it to map that site instead")
            }
            return .url(argument)
        }
        var pathPart = argument
        var query: String?
        if let mark = argument.firstIndex(of: "?") {
            pathPart = String(argument[..<mark])
            query = SitePathTree.encodeQuery(String(argument[argument.index(after: mark)...]))
        }
        // A fragment is for the browser, not the server.
        if let hash = pathPart.firstIndex(of: "#") { pathPart = String(pathPart[..<hash]) }
        let segments = tree.resolve(pathPart, from: cwd)
        let typedAsDirectory = pathPart.hasSuffix("/")
        return .url(tree.url(for: segments, query: query, asDirectory: typedAsDirectory ? true : nil))
    }
}

// MARK: - Layout

enum ExplorerFormat {
    static func prompt(origin: SiteOrigin?, cwd: [String]) -> String {
        guard let origin else { return "$" }
        return "\(origin.display):\(SitePathTree.display(cwd)) $"
    }

    /// One entry per line. Long form adds where each came from — see the
    /// legend in `helpLines` — and how much is under a directory.
    static func ls(_ entries: [SiteEntry], long: Bool) -> [String] {
        guard long else {
            return entries.map { $0.name + ($0.isDirectory ? "/" : "") }
        }
        let labels = entries.map { $0.name + ($0.isDirectory ? "/" : "") }
        let width = min(labels.map(\.count).max() ?? 0, 48)
        return zip(entries, labels).map { entry, label in
            var line = entry.provenance.flags + "  " + label
            var notes: [String] = []
            if entry.isDirectory, entry.childCount > 0 { notes.append("\(entry.childCount) inside") }
            if entry.queryVariants > 0 { notes.append("\(entry.queryVariants) with ?query") }
            if entry.provenance.isEmpty { notes.append("implied") }
            if !notes.isEmpty {
                line += String(repeating: " ", count: max(0, width - label.count)) + "  " + notes.joined(separator: ", ")
            }
            return line
        }
    }

    /// A tree below `path`, `maxDepth` levels deep, at most `maxLines` lines.
    static func tree(at path: [String], in tree: SitePathTree, maxDepth: Int, maxLines: Int) -> [String] {
        var lines: [String] = []
        var cut = false

        func emit(_ current: [String], prefix: String, depth: Int) {
            guard let entries = tree.entries(at: current) else { return }
            for (index, entry) in entries.enumerated() {
                if lines.count >= maxLines { cut = true; return }
                let isLast = index == entries.count - 1
                var line = prefix + (isLast ? "└── " : "├── ") + entry.name + (entry.isDirectory ? "/" : "")
                if entry.isDirectory, depth >= maxDepth, entry.childCount > 0 {
                    line += "  [\(entry.childCount)]"
                }
                lines.append(line)
                if entry.isDirectory, depth < maxDepth {
                    emit(current + [entry.rawName], prefix: prefix + (isLast ? "    " : "│   "), depth: depth + 1)
                    if cut { return }
                }
            }
        }
        emit(path, prefix: "", depth: 1)
        if cut { lines.append("… more not shown — `tree <dir>` shows one part, `-L n` sets the depth") }
        return lines
    }

    /// `200  text/html; charset=utf-8  12.3 KB  84 ms`
    static func responseSummary(status: Int, contentType: String?, byteCount: Int, milliseconds: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        // Without this an empty body reads "Zero KB".
        formatter.allowsNonnumericFormatting = false
        let size = formatter.string(fromByteCount: Int64(byteCount))
        return [String(status), contentType ?? "no content-type", size, "\(milliseconds) ms"].joined(separator: "  ")
    }

    /// The few headers worth a line in a CLI. Never a cookie: `Set-Cookie`
    /// can carry a session, and this is a transcript on screen.
    static func headerLines(_ headers: [HTTPHeaderField]) -> [String] {
        let wanted = ["location", "server", "last-modified"]
        return wanted.compactMap { name in
            headers.first { $0.name.lowercased() == name }.map { "\(name): \(oneLine($0.value))" }
        }
    }

    /// The first `maxLines` lines of `text`, each cut to `maxLength`, and a
    /// note of how much was left out.
    static func bodyPreview(_ text: String, maxLines: Int, maxLength: Int) -> [String] {
        var lines: [String] = []
        var remaining = 0
        var count = 0
        text.enumerateLines { line, _ in
            count += 1
            if count <= maxLines {
                lines.append(line.count > maxLength ? String(line.prefix(maxLength)) + "…" : line)
            } else {
                remaining += 1
            }
        }
        if remaining > 0 { lines.append("… \(remaining) more lines — `req` opens this in the request view") }
        return lines
    }

    private static func oneLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    /// Text that came from a server, made safe to put on a line of the
    /// transcript: control characters (escape sequences, bells) and
    /// direction overrides become `·`; a tab becomes a space. The transcript
    /// is a SwiftUI view, not a terminal, so an escape sequence couldn't do
    /// anything — but a newline would still split a line, and an override
    /// could still reorder one.
    static func sanitized(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\t" {
                out.append(" ")
            } else if SitePathTree.isPlainText(String(scalar)) {
                out.append(scalar)
            } else {
                out.append("·")
            }
        }
        return String(out)
    }

    static let helpLines: [String] = [
        "Maps what a site publishes — its robots.txt, the sitemaps that names, and links",
        "in pages you fetch — and lets you walk it like a directory. It never guesses at",
        "paths: `ls` reads the map and asks the site nothing.",
        "",
        "  open <address>    map a site (an address on its own does the same, before one is open;",
        "                    a local server needs its scheme: open http://localhost:3000)",
        "  ls [-l] [path]    list a directory; -l shows where each entry came from",
        "  cd [path]         change directory (.. goes up, / or cd alone goes to the top)",
        "  pwd               where you are",
        "  tree [-L n] [path]  the map below a directory",
        "  find <text>       known paths containing some text",
        "  get [path]        fetch one address and print the response (cat is the same)",
        "  req [path]        load an address into the request builder, without sending",
        "  info              what has been read, and from where",
        "  refresh           read the site's declarations again",
        "  clear             clear the screen",
        "  Tab completes · ↑ ↓ recall · Esc cancels",
        "",
        "ls -l columns:  S sitemap · A robots Allow · D robots Disallow · L found as a link",
        "robots.txt rules are prefixes and are shown as written; patterns with * are left out.",
    ]
}

// MARK: - Completion

enum ExplorerCompleter {
    static let commandNames = [
        "cat", "cd", "clear", "find", "get", "help", "info", "ll", "ls", "open", "pwd", "refresh", "req", "tree",
    ]
    private static let pathCommands: Set<String> = ["cd", "ls", "ll", "dir", "tree", "get", "cat", "req", "request"]

    struct Completion: Equatable {
        /// The whole line, with its last word completed as far as it goes.
        var line: String
        /// When more than one entry matched, what they are.
        var candidates: [String]
    }

    static func complete(line: String, cwd: [String], tree: SitePathTree?) -> Completion? {
        // First word: a command.
        if !line.contains(" ") {
            let matches = commandNames.filter { $0.hasPrefix(line.lowercased()) }
            guard !matches.isEmpty, !line.isEmpty else { return nil }
            if matches.count == 1 { return Completion(line: matches[0] + " ", candidates: []) }
            let common = commonPrefix(matches)
            return Completion(line: common.count > line.count ? common : line, candidates: matches)
        }

        // A later word: a path, for the commands that take one.
        guard let tree, let space = line.lastIndex(of: " ") else { return nil }
        let command = line.split(separator: " ").first.map { String($0).lowercased() } ?? ""
        guard pathCommands.contains(command) else { return nil }
        let head = String(line[...space])
        let word = String(line[line.index(after: space)...])
        // Quotes and escapes are left to the person: completing across them
        // would have to guess where the word ends.
        guard !word.contains("\""), !word.contains("'"), !word.contains("\\") else { return nil }

        let slash = word.lastIndex(of: "/")
        let directoryPart = slash.map { String(word[...$0]) } ?? ""
        let namePrefix = slash.map { String(word[word.index(after: $0)...]) } ?? word
        let directory = tree.resolve(directoryPart.isEmpty ? "." : directoryPart, from: cwd)
        guard let entries = tree.entries(at: directory) else { return nil }

        let matches = entries.filter { $0.name.hasPrefix(namePrefix) && !$0.name.contains("\"") && !$0.name.contains("'") }
        guard !matches.isEmpty else { return nil }

        func display(_ entry: SiteEntry) -> String {
            escaped(entry.name) + (entry.isDirectory ? "/" : "")
        }
        if matches.count == 1 {
            return Completion(line: head + directoryPart + display(matches[0]), candidates: [])
        }
        let common = commonPrefix(matches.map(\.name))
        let completed = common.count > namePrefix.count ? escaped(common) : namePrefix
        return Completion(
            line: head + directoryPart + completed,
            candidates: matches.map { $0.name + ($0.isDirectory ? "/" : "") }
        )
    }

    private static func escaped(_ name: String) -> String {
        name.replacingOccurrences(of: " ", with: "\\ ")
    }

    private static func commonPrefix(_ strings: [String]) -> String {
        guard var prefix = strings.first else { return "" }
        for string in strings.dropFirst() {
            while !string.hasPrefix(prefix) { prefix.removeLast() }
            if prefix.isEmpty { break }
        }
        return prefix
    }
}
