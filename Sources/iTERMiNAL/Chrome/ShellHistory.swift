import Foundation

/// Reads the user's own shell history to offer recent commands on the landing
/// screen.
///
/// This is a local read of a file the user already owns; nothing is uploaded,
/// and an unreadable or missing file just yields no suggestions.
enum ShellHistory {
    /// Only the tail is parsed — history files grow to megabytes and the
    /// recent end is all that matters.
    private static let tailByteCount = 64 * 1024

    static func recentCommands(limit: Int = 3) -> [String] {
        for url in candidateFiles() {
            let commands = parse(url: url)
            if !commands.isEmpty {
                return Array(commands.prefix(limit))
            }
        }
        return []
    }

    private static func candidateFiles() -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var files: [URL] = []
        if let histfile = ProcessInfo.processInfo.environment["HISTFILE"], !histfile.isEmpty {
            files.append(URL(fileURLWithPath: (histfile as NSString).expandingTildeInPath))
        }
        files.append(home.appendingPathComponent(".zsh_history"))
        files.append(home.appendingPathComponent(".bash_history"))
        return files
    }

    private static func parse(url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(tailByteCount) ? size - UInt64(tailByteCount) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return [] }

        // History files can hold non-UTF8 bytes (zsh metafies them); decoding
        // leniently keeps the readable entries instead of dropping the file.
        let text = String(decoding: data, as: UTF8.self)

        var seen = Set<String>()
        var commands: [String] = []
        // Newest last in the file, so walk backwards.
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
            guard let command = normalize(String(line)) else { continue }
            guard seen.insert(command).inserted else { continue }
            commands.append(command)
            if commands.count >= 20 { break }
        }
        return commands
    }

    /// Strips zsh's extended-history prefix (`: 1690000000:0;cmd`) and skips
    /// entries that make poor suggestions.
    private static func normalize(_ raw: String) -> String? {
        var line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix(":"), let semicolon = line.firstIndex(of: ";") {
            line = String(line[line.index(after: semicolon)...])
        }
        line = line.trimmingCharacters(in: .whitespaces)

        guard !line.isEmpty,
              line.count <= 120,
              !line.hasSuffix("\\"),
              !line.hasPrefix("#") else { return nil }
        return line
    }
}
