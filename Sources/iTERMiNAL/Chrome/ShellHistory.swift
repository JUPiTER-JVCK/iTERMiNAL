import Foundation

/// Reads the user's own shell history, for the landing screen's recent commands
/// and for the composer's suggestions and search.
///
/// This is a local read of a file the user already owns. Nothing here uploads
/// it or keeps it: callers hold what they get in memory for as long as they
/// need it, and an unreadable or missing file just yields nothing.
enum ShellHistory {
    /// Only the tail is parsed — history files grow to megabytes and the
    /// recent end is all that matters.
    private static let landingTailByteCount = 64 * 1024
    private static let searchTailByteCount = 512 * 1024

    /// What a landing-screen suggestion may be, and what a search result may be.
    private static let landingMaxLength = 120
    private static let searchMaxLength = 400

    static func recentCommands(limit: Int = 3) -> [String] {
        for url in candidateFiles() {
            let commands = newestFirst(
                in: readTail(of: url, byteCount: landingTailByteCount),
                maxLength: landingMaxLength,
                limit: 20
            )
            if !commands.isEmpty {
                return Array(commands.prefix(limit))
            }
        }
        return []
    }

    /// The commands in the recent end of the history, newest first, each once.
    /// Reads a file, so call it off the main thread.
    static func search(limit: Int = 5_000) -> [String] {
        search(in: candidateFiles(), tailByteCount: searchTailByteCount, limit: limit)
    }

    /// `search` against given files and tail size, so both can be tested.
    static func search(in files: [URL], tailByteCount: Int, limit: Int) -> [String] {
        for url in files {
            let commands = newestFirst(
                in: readTail(of: url, byteCount: tailByteCount),
                maxLength: searchMaxLength,
                limit: limit
            )
            if !commands.isEmpty { return commands }
        }
        return []
    }

    static func candidateFiles(
        home: URL = URL(fileURLWithPath: NSHomeDirectory()),
        histfile: String? = ProcessInfo.processInfo.environment["HISTFILE"]
    ) -> [URL] {
        var files: [URL] = []
        if let histfile, !histfile.isEmpty {
            files.append(URL(fileURLWithPath: (histfile as NSString).expandingTildeInPath))
        }
        files.append(home.appendingPathComponent(".zsh_history"))
        files.append(home.appendingPathComponent(".bash_history"))
        return files
    }

    /// The last `byteCount` bytes as text. When that cuts into the file, the
    /// line it cuts into is dropped: a fragment of a command is not one.
    private static func readTail(of url: URL, byteCount: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let truncated = size > UInt64(byteCount)
        // One byte more than asked for when cutting: the byte before the tail
        // is a newline exactly when the tail starts on a line, and dropping
        // through the first newline then costs nothing.
        let offset = truncated ? size - UInt64(byteCount) - 1 : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return "" }

        // History files can hold non-UTF8 bytes (zsh metafies them); decoding
        // leniently keeps the readable entries instead of dropping the file.
        var text = String(decoding: data, as: UTF8.self)
        if truncated {
            guard let newline = text.firstIndex(of: "\n") else { return "" }
            text = String(text[text.index(after: newline)...])
        }
        return text
    }

    /// Every command in the text, oldest first.
    static func entries(in text: String, maxLength: Int) -> [String] {
        var commands: [String] = []
        var continuing = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            // zsh stores a command that spans lines as its lines joined by a
            // backslash-newline. The first line ends in the backslash, and the
            // lines after it are not commands of their own.
            let wasContinuing = continuing
            continuing = line.trimmingCharacters(in: .whitespaces).hasSuffix("\\")
            if wasContinuing { continue }
            if let command = normalize(line, maxLength: maxLength) {
                commands.append(command)
            }
        }
        return commands
    }

    static func newestFirst(in text: String, maxLength: Int, limit: Int) -> [String] {
        var seen = Set<String>()
        var commands: [String] = []
        for command in entries(in: text, maxLength: maxLength).reversed() {
            guard seen.insert(command).inserted else { continue }
            commands.append(command)
            if commands.count >= limit { break }
        }
        return commands
    }

    /// Strips zsh's extended-history prefix (`: 1690000000:0;cmd`) and skips
    /// entries that make poor suggestions.
    private static func normalize(_ raw: String, maxLength: Int) -> String? {
        var line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix(":"), let semicolon = line.firstIndex(of: ";") {
            line = String(line[line.index(after: semicolon)...])
        }
        line = line.trimmingCharacters(in: .whitespaces)

        guard !line.isEmpty,
              line.count <= maxLength,
              !line.hasSuffix("\\"),
              !line.hasPrefix("#") else { return nil }
        return line
    }
}
