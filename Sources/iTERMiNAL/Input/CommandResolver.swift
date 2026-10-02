import Foundation

/// Whether a word the composer is colouring as a command names something that
/// exists.
///
/// "Exists" is as far as this app can see. Aliases and functions live in the
/// user's shell, and a GUI app inherits a thinner `PATH` than a login shell, so
/// a command can be perfectly real and still not be found here. The editor
/// therefore uses this only to *add* colour: a found command is painted as a
/// command, and an unfound one is left as plain text — never flagged as an
/// error.
final class CommandResolver {
    static let shared = CommandResolver()

    /// What a shell handles itself, so no file need exist. Bash and zsh both.
    private static let builtins: Set<String> = [
        ".", ":", "[", "alias", "autoload", "bg", "bindkey", "break", "builtin", "cd",
        "command", "compdef", "continue", "declare", "dirs", "disown", "echo", "emulate",
        "eval", "exec", "exit", "export", "false", "fc", "fg", "getopts", "hash", "history",
        "jobs", "kill", "let", "local", "noglob", "popd", "print", "printf", "pushd", "pwd",
        "read", "readonly", "rehash", "return", "set", "setopt", "shift", "source", "test",
        "times", "trap", "true", "type", "typeset", "ulimit", "umask", "unalias", "unset",
        "unsetopt", "vared", "wait", "whence", "where", "zle", "zmodload", "zstyle",
    ]

    /// Where people keep their own tools that a Finder-launched app's `PATH`
    /// often lacks.
    private static let userDirectories = ["~/.local/bin", "~/.cargo/bin", "~/bin", "~/go/bin"]

    /// A miss is remembered only briefly: installing the tool a moment later
    /// should not leave it uncoloured for the rest of the session.
    private static let missLifetime: TimeInterval = 10

    private var cache: [String: (known: Bool, at: Date)] = [:]

    func isKnown(_ word: String, workingDirectory: String?) -> Bool {
        guard !word.isEmpty else { return false }
        if Self.builtins.contains(word) { return true }
        // A path names a file directly, so it depends on the directory the
        // command will run in and is not worth caching.
        if word.contains("/") { return isExecutableFile(word, relativeTo: workingDirectory) }

        if let hit = cache[word], hit.known || Date().timeIntervalSince(hit.at) < Self.missLifetime {
            return hit.known
        }
        let known = SessionLaunch.resolveExecutable(word) != nil
            || Self.userDirectories.contains { directory in
                isExecutableFile((directory as NSString).expandingTildeInPath + "/" + word, relativeTo: nil)
            }
        cache[word] = (known, Date())
        return known
    }

    private func isExecutableFile(_ path: String, relativeTo directory: String?) -> Bool {
        var resolved = (path as NSString).expandingTildeInPath
        if !resolved.hasPrefix("/") {
            guard let directory else { return false }
            resolved = (directory as NSString).appendingPathComponent(resolved)
        }
        var isDirectory: ObjCBool = false
        // A directory has the execute bit too, and is not a command.
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        return FileManager.default.isExecutableFile(atPath: resolved)
    }
}
