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

    /// The last `byteCount` bytes as text, and what the cut did to its start.
    private struct Tail {
        var text: String
        /// The text begins part-way through a line, so that first line is a
        /// fragment of a command, not one.
        var startsMidLine = false
        /// The line before the text ended in a backslash, so the first line
        /// is the rest of a command that began earlier.
        var continuesFromPrevious = false
    }

    private static func readTail(of url: URL, byteCount: Int) -> Tail {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Tail(text: "") }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let truncated = size > UInt64(byteCount)
        // Two bytes more than asked for when cutting. The one just before the
        // tail is a newline exactly when the tail starts on a line; the one
        // before that, if it is a backslash, says that line carries on from
        // the one before it. Neither is part of the text.
        let lead = truncated ? Int(min(UInt64(2), size - UInt64(byteCount))) : 0
        let offset = truncated ? size - UInt64(byteCount) - UInt64(lead) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), data.count > lead else { return Tail(text: "") }

        // History files can hold non-UTF8 bytes (zsh metafies them); decoding
        // leniently keeps the readable entries instead of dropping the file.
        let text = String(decoding: data.dropFirst(lead), as: UTF8.self)
        guard truncated else { return Tail(text: text) }
        let before = Array(data.prefix(lead))
        let newline = UInt8(ascii: "\n")
        let backslash = UInt8(ascii: "\\")
        if before.last == newline {
            // The tail starts on a line. That line carries on from the one
            // before it if that one ended in a backslash.
            return Tail(text: text, startsMidLine: false, continuesFromPrevious: before.count == 2 && before[0] == backslash)
        }
        if data[lead] == newline {
            // The cut fell exactly on a line's newline: what is cut off of it
            // is nothing, and the line after starts clean. The line that just
            // ended is the byte before.
            return Tail(text: text, startsMidLine: false, continuesFromPrevious: before.last == backslash)
        }
        return Tail(text: text, startsMidLine: true, continuesFromPrevious: false)
    }

    /// Every command in the text, oldest first.
    ///
    /// `startsMidLine` and `continuesFromPrevious` describe a text that was cut
    /// out of the middle of a file (see `Tail`): the first line is then not a
    /// command to offer, though it still says whether the line after it is a
    /// continuation, because only its start was cut, not its end.
    static func entries(
        in text: String,
        maxLength: Int,
        startsMidLine: Bool = false,
        continuesFromPrevious: Bool = false
    ) -> [String] {
        var commands: [String] = []
        var continuing = continuesFromPrevious
        var first = true
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            // zsh stores a command that spans lines as its lines joined by a
            // backslash-newline. The first line ends in the backslash, and the
            // lines after it are not commands of their own.
            let skip = continuing || (first && startsMidLine)
            continuing = line.trimmingCharacters(in: .whitespaces).hasSuffix("\\")
            first = false
            if skip { continue }
            if let command = normalize(line, maxLength: maxLength) {
                commands.append(command)
            }
        }
        return commands
    }

    private static func newestFirst(in tail: Tail, maxLength: Int, limit: Int) -> [String] {
        newestFirst(
            entries(in: tail.text, maxLength: maxLength, startsMidLine: tail.startsMidLine,
                    continuesFromPrevious: tail.continuesFromPrevious),
            limit: limit
        )
    }

    static func newestFirst(in text: String, maxLength: Int, limit: Int) -> [String] {
        newestFirst(entries(in: text, maxLength: maxLength), limit: limit)
    }

    /// Newest first, each command once, at its newest position.
    private static func newestFirst(_ oldestFirst: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var commands: [String] = []
        for command in oldestFirst.reversed() {
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
