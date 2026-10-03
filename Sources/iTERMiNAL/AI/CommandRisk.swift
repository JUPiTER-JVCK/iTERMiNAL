import Foundation

/// A short, plain warning for commands that are easy to regret.
///
/// Advice, shown beside a suggested command that is about to be put in the
/// input. It is not a safety check: it reads the text for a handful of
/// well-known dangers and says nothing about anything else, so no warning does
/// not mean safe.
enum CommandRisk {
    static func warnings(for command: String) -> [String] {
        var found: [String] = []
        func add(_ warning: String) { if !found.contains(warning) { found.append(warning) } }

        let parts = parse(command)
        for (index, part) in parts.enumerated() {
            var words = part.words
            var sawSudo = false
            // Leading environment assignments and wrappers, which are not the
            // command that runs.
            while let first = words.first {
                if first.contains("="), !first.hasPrefix("-"), first.first?.isLetter == true || first.first == "_" {
                    words.removeFirst()
                } else if first == "sudo" || first == "doas" {
                    sawSudo = true
                    words.removeFirst()
                    words = dropFlags(words, taking: ["-u", "-g", "-h", "-p", "-C", "-D", "-r", "-t", "-T", "-U"])
                } else if ["env", "command", "builtin", "nice", "nohup", "time", "exec"].contains(first) {
                    words.removeFirst()
                    words = dropFlags(words, taking: ["-u", "-n", "-S"])
                } else if first == "xargs" {
                    words.removeFirst()
                    words = dropFlags(words, taking: ["-n", "-I", "-P", "-L", "-d", "-s", "-E", "-J"])
                } else {
                    break
                }
            }
            if sawSudo { add("Runs with administrator rights.") }
            if part.truncatesFile { add("Overwrites the file it writes to.") }
            guard let name = words.first.map({ ($0 as NSString).lastPathComponent }) else { continue }
            let rest = Array(words.dropFirst())
            let flags = rest.filter { $0.hasPrefix("-") && $0 != "-" }
            let letters = flags.filter { !$0.hasPrefix("--") }.flatMap { Array($0.dropFirst()) }
            let longFlags = Set(flags.filter { $0.hasPrefix("--") })
            let arguments = rest.filter { !$0.hasPrefix("-") }

            switch name {
            case "rm":
                let recursive = letters.contains("r") || letters.contains("R") || longFlags.contains("--recursive")
                let forced = letters.contains("f") || longFlags.contains("--force")
                if recursive {
                    add(forced
                        ? "Deletes folders and everything in them, without asking."
                        : "Deletes folders and everything in them.")
                    if arguments.contains(where: { ["/", "/*", "~", "~/", "$HOME", "\"$HOME\"", ".", "..", "*", "./*"].contains($0) }) {
                        add("Aims at a very broad location.")
                    }
                }
            case "dd":
                if arguments.contains(where: { $0.hasPrefix("of=") }) {
                    add("Writes raw data straight to a file or device.")
                }
            case "mkfs", "newfs", "newfs_hfs", "newfs_msdos", "newfs_apfs":
                add("Erases a disk or volume.")
            case _ where name.hasPrefix("mkfs.") || name.hasPrefix("newfs_"):
                add("Erases a disk or volume.")
            case "diskutil":
                if let verb = arguments.first, ["eraseDisk", "eraseVolume", "erasevolume", "erasedisk", "partitionDisk", "partitiondisk", "reformat", "apfs"].contains(verb) {
                    add("Erases or repartitions a disk.")
                }
            case "chmod", "chown", "chgrp":
                if letters.contains("R") || longFlags.contains("--recursive") {
                    add("Changes permissions or ownership across a whole folder tree.")
                }
            case "git":
                gitWarnings(arguments: arguments, letters: letters, longFlags: longFlags, add: add)
            case "find":
                if flags.contains("-delete") { add("Deletes every file it finds.") }
            case "shutdown", "reboot", "halt":
                add("Shuts down or restarts this Mac.")
            case "sh", "bash", "zsh", "dash", "ksh", "fish":
                if part.pipedFromPrevious, index > 0 {
                    let source = parts[index - 1].words.first.map { ($0 as NSString).lastPathComponent } ?? ""
                    add(["curl", "wget", "fetch"].contains(source)
                        ? "Runs a script straight from the network."
                        : "Runs whatever is piped into it as commands.")
                }
            default:
                break
            }
        }
        if command.contains(":(){") { add("Looks like a fork bomb.") }
        return found
    }

    // MARK: Git

    private static func gitWarnings(
        arguments: [String],
        letters: [Character],
        longFlags: Set<String>,
        add: (String) -> Void
    ) {
        guard let verb = arguments.first else { return }
        switch verb {
        case "push":
            if letters.contains("f") || longFlags.contains("--force") || arguments.dropFirst().contains(where: { $0.hasPrefix("+") }) {
                add("Overwrites history on the remote.")
            }
        case "reset":
            if longFlags.contains("--hard") { add("Throws away uncommitted changes.") }
        case "clean":
            if letters.contains("f") || longFlags.contains("--force") { add("Deletes files git is not tracking.") }
        case "checkout", "restore":
            if arguments.dropFirst().contains(".") { add("Throws away uncommitted changes.") }
        case "branch":
            if letters.contains("D") { add("Deletes a branch even if it was never merged.") }
        default:
            break
        }
    }

    // MARK: Reading the text

    private struct Part {
        var words: [String] = []
        var pipedFromPrevious = false
        var truncatesFile = false
    }

    /// Skips a wrapper's own flags, and the value of those that take one.
    private static func dropFlags(_ words: [String], taking valued: Set<String>) -> [String] {
        var rest = words[...]
        while let first = rest.first, first.hasPrefix("-"), first != "-" {
            rest = rest.dropFirst()
            if valued.contains(first), !rest.isEmpty { rest = rest.dropFirst() }
        }
        return Array(rest)
    }

    /// A rough split into commands and their words, honouring quotes. Enough to
    /// know what runs and what it was given; not a shell.
    private static func parse(_ command: String) -> [Part] {
        var parts: [Part] = []
        var part = Part()
        var word = ""
        var hasWord = false
        var quote: Character?
        var redirectTarget = false
        let characters = Array(command)
        var index = 0

        func endWord() {
            guard hasWord else { return }
            if redirectTarget {
                redirectTarget = false
                if !word.hasPrefix("/dev/") { part.truncatesFile = true }
            } else {
                part.words.append(word)
            }
            word = ""
            hasWord = false
        }
        func endPart(pipe: Bool) {
            endWord()
            if !part.words.isEmpty || part.truncatesFile { parts.append(part) }
            part = Part()
            part.pipedFromPrevious = pipe
        }

        while index < characters.count {
            let c = characters[index]
            if let open = quote {
                if c == open {
                    quote = nil
                } else if c == "\\", open == "\"", index + 1 < characters.count {
                    index += 1
                    word.append(characters[index])
                } else {
                    word.append(c)
                }
            } else {
                switch c {
                case "'", "\"":
                    quote = c
                    hasWord = true
                case "\\":
                    if index + 1 < characters.count {
                        index += 1
                        word.append(characters[index])
                        hasWord = true
                    }
                case " ", "\t":
                    endWord()
                case "\n", ";":
                    endPart(pipe: false)
                case "&":
                    // `&&` and a lone `&` both end a command. The `&` of `2>&1`
                    // never gets here: the `>` before it takes it.
                    endPart(pipe: false)
                    if characters[safe: index + 1] == "&" { index += 1 }
                case "|":
                    if characters[safe: index + 1] == "|" {
                        endPart(pipe: false)
                        index += 1
                    } else {
                        endPart(pipe: true)
                    }
                case ">":
                    if characters[safe: index + 1] == ">" {
                        // Appending does not overwrite.
                        index += 1
                        if word.allSatisfy(\.isNumber) { word = ""; hasWord = false } else { endWord() }
                        redirectTarget = false
                        // Its target is a word to skip, not a command word.
                        skipTarget(&index, in: characters)
                    } else if characters[safe: index + 1] == "&" {
                        // Duplicating a descriptor: >&2, 2>&1.
                        if word.allSatisfy(\.isNumber) { word = ""; hasWord = false } else { endWord() }
                        index += 1
                        skipTarget(&index, in: characters)
                    } else {
                        // A lone digit string before it names a descriptor.
                        if hasWord, word.allSatisfy(\.isNumber) { word = ""; hasWord = false } else { endWord() }
                        if characters[safe: index + 1] == "|" { index += 1 }
                        redirectTarget = true
                    }
                default:
                    word.append(c)
                    hasWord = true
                }
            }
            index += 1
        }
        endPart(pipe: false)
        return parts
    }

    /// Moves past the blanks and the word after a redirection that does not
    /// overwrite anything, leaving `index` on its last character.
    private static func skipTarget(_ index: inout Int, in characters: [Character]) {
        var next = index + 1
        while next < characters.count, characters[next] == " " || characters[next] == "\t" { next += 1 }
        while next < characters.count, !" \t\n;|&".contains(characters[next]) { next += 1 }
        index = next - 1
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
