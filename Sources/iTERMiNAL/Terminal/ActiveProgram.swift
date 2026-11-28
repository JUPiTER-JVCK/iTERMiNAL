import Foundation

/// What a terminal has in front, as far as the quick reference strip needs to
/// know: a program it has keys for, a command being typed at the prompt, the
/// prompt itself, or something running that it has nothing listed for.
///
/// Worked out from signals the session already has, so it costs no polling:
///
/// - For a shell on this Mac, the kernel's answer to which process group has
///   the terminal (`ForegroundProcess`) — the same thing Terminal.app names its
///   tabs from, and it needs nothing from the shell.
/// - On the far end of ssh, where the kernel only ever sees `ssh`, the
///   alternate screen that full-screen programs switch to, and the last command
///   line typed at a prompt.
///
/// A word the person typed is only ever used once it matches a program the
/// catalog lists, or a command `CommandSpecs` knows. A password typed at a
/// prompt is text like any other here, and it must never end up on screen.
///
/// Foundation only, so the rules are checked off a Mac.
enum ActiveProgram: Equatable {
    /// A program with keys in the catalog. `name` is what it was found as —
    /// "nvim" for Neovim — for the strip's badge.
    case program(ProgramKeySection, name: String)
    /// At a prompt, with a command `CommandSpecs` knows typed and a space after
    /// it.
    case typing(TypedCommand)
    /// At a prompt. `remote` for a shell on the far end of ssh.
    case shell(remote: Bool)
    /// Something is running that the catalog has no keys for: the kernel's
    /// name for it, when there is one.
    case running(String?)

    struct TypedCommand: Equatable {
        /// The command, as `CommandSpecs` names it.
        var command: String
        /// Its subcommand, when it has them and one has been typed: "commit"
        /// in `git commit -`.
        var subcommand: String?
    }

    struct Signals: Equatable {
        /// The processes in the terminal's foreground group, its leader first,
        /// as the kernel names them. Empty when the shell's own group is in
        /// front: a prompt. Nil when the kernel was not asked or could not say.
        var foreground: [String]?
        /// What started the group's leader, when that was not the shell. A man
        /// built on mandoc puts its pager in a group of its own and hands it
        /// the terminal, so while a page is read the group in front is less
        /// alone, and only its parent says it is a manual page.
        var foregroundParent: String?
        /// The script the group's leader runs, when the leader is a shell
        /// running one (`ForegroundGroup.script`).
        var foregroundScript: String?
        /// Whether the terminal shows the alternate screen, which full-screen
        /// programs draw on.
        var alternateScreen = false
        var isRemote = false
        /// The bundled tool a session runs instead of a shell.
        var tool: String?
        /// The last command line given to a shell at a prompt.
        var lastCommandLine: String?
        /// The line being typed at the prompt, when it can be trusted.
        var typedLine: String?
        /// The title the program gave the terminal.
        var title = ""
    }

    /// What the kernel says has a terminal: the foreground group's processes,
    /// its leader first, and the name of what started the leader when that was
    /// not the shell. `ForegroundProcess` reads it; it is here, in plain
    /// Foundation, so the rules that use it can be checked off a Mac.
    struct ForegroundGroup: Equatable {
        var names: [String]
        var parent: String?
        /// The script the leader runs, when the leader is a shell running one:
        /// macOS's man is a shell script, so the kernel names it sh, and only
        /// its arguments say it is man.
        var script: String?
        /// The group's id, so a second look at the same group can keep what
        /// the first found out about its script.
        var id: Int32 = 0

        /// The shell's own group: a prompt.
        static let prompt = ForegroundGroup(names: [], parent: nil)
    }

    /// The arguments in what `KERN_PROCARGS2` hands back for a process: the
    /// argument count as a 32-bit integer, the path that was run, NUL padding,
    /// then each argument ending in a NUL — and after them the environment,
    /// which is not read. Nil when the bytes are not laid out that way.
    static func arguments(fromProcessArguments bytes: [UInt8]) -> [String]? {
        let countSize = MemoryLayout<Int32>.size
        guard bytes.count > countSize else { return nil }
        let count = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0 else { return nil }
        var index = countSize
        // The path that was run, then the padding after it.
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < Int(count), index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments.count == Int(count) ? arguments : nil
    }

    /// The script a shell's arguments say it is running — `/usr/bin/man` in
    /// `/bin/sh /usr/bin/man ls`, which is how the kernel starts a script —
    /// by its name. Nil for a shell given its commands inline (`sh -c …`) or
    /// none at all: an interactive one.
    static func script(inShellArguments arguments: [String]) -> String? {
        for argument in arguments.dropFirst() {
            if argument == "-c" { return nil }
            if argument.hasPrefix("-") || argument.hasPrefix("+") { continue }
            let name = ProgramKeyCatalog.normalizedProgramName(argument)
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// Programs that run another one named after them: `sudo vim` is Vim.
    static let wrappers: Set<String> = ["sudo", "doas", "env", "nice", "nohup", "time", "command", "exec", "caffeinate"]

    static func resolve(_ signals: Signals) -> ActiveProgram {
        if let tool = signals.tool {
            if let section = ProgramKeyCatalog.section(forProgram: tool) {
                return .program(section, name: ProgramKeyCatalog.normalizedProgramName(tool))
            }
            return .running(ProgramKeyCatalog.normalizedProgramName(tool))
        }
        if !signals.isRemote, let foreground = signals.foreground {
            guard let leader = foreground.first else { return atPrompt(signals, remote: false) }
            switch ProgramKeyCatalog.section(forProgram: leader) {
            case .shell?:
                return shellLeads(signals, group: foreground)
            case .ssh?:
                // A shell on the far end, reached from this one.
                return farEnd(signals, remote: true)
            case .pager? where signals.foregroundParent.flatMap(ProgramKeyCatalog.section(forProgram:)) == .man:
                // The pager man started: what is being read is a manual page.
                return .program(.man, name: "man")
            case let section?:
                return .program(section, name: ProgramKeyCatalog.normalizedProgramName(leader))
            case nil:
                break
            }
            // A pipeline, or a program that runs another in its own group:
            // `git log` shows its output in less, `git commit` opens the editor.
            for member in foreground.dropFirst() {
                guard let section = ProgramKeyCatalog.section(forProgram: member),
                      section != .shell, section != .ssh else { continue }
                return .program(section, name: ProgramKeyCatalog.normalizedProgramName(member))
            }
            let leaderName = ProgramKeyCatalog.normalizedProgramName(leader)
            if wrappers.contains(leaderName), let found = program(in: signals.lastCommandLine),
               found.section != .shell, found.section != .ssh {
                return .program(found.section, name: found.name)
            }
            return .running(leaderName.isEmpty ? nil : leaderName)
        }
        return farEnd(signals, remote: signals.isRemote)
    }

    /// A shell leading the group in front is one of two things. Started from
    /// the prompt to be used — `bash` typed in zsh — it is at a prompt of its
    /// own, alone in its group: an interactive shell gives every command it
    /// runs a group of its own. Running a script, it is not: the script's
    /// commands share its group. macOS's man is such a script, with mandoc and
    /// less beside it, and was read as a prompt until this told them apart.
    private static func shellLeads(_ signals: Signals, group: [String]) -> ActiveProgram {
        if let script = signals.foregroundScript, let section = listedSection(script) {
            return .program(section, name: script)
        }
        guard group.count > 1 || signals.foregroundScript != nil else {
            return atPrompt(signals, remote: false)
        }
        // A script that is no program listed: what it runs may be.
        for member in group.dropFirst() {
            if let section = listedSection(member) {
                return .program(section, name: ProgramKeyCatalog.normalizedProgramName(member))
            }
        }
        let running = signals.foregroundScript
            ?? group.dropFirst().first { ProgramKeyCatalog.section(forProgram: $0) != .shell }
                .map(ProgramKeyCatalog.normalizedProgramName)
        return .running(running ?? ProgramKeyCatalog.normalizedProgramName(group[0]))
    }

    /// A section for a program with keys of its own: not a shell, not ssh.
    private static func listedSection(_ name: String) -> ProgramKeySection? {
        guard let section = ProgramKeyCatalog.section(forProgram: name), section != .shell, section != .ssh else { return nil }
        return section
    }

    /// Where the kernel cannot see what runs: the far end of ssh, or a session
    /// it could not be asked about.
    private static func farEnd(_ signals: Signals, remote: Bool) -> ActiveProgram {
        guard signals.alternateScreen else { return atPrompt(signals, remote: remote) }
        if let found = program(in: signals.lastCommandLine), found.section != .shell, found.section != .ssh {
            return .program(found.section, name: found.name)
        }
        if let found = program(inTitle: signals.title) {
            return .program(found.section, name: found.name)
        }
        return .running(nil)
    }

    private static func atPrompt(_ signals: Signals, remote: Bool) -> ActiveProgram {
        if let line = signals.typedLine, let typed = typing(in: line) {
            return .typing(typed)
        }
        return .shell(remote: remote)
    }

    /// The program a command line runs, when the catalog lists it: past
    /// assignments (`TERM=xterm vim`), wrappers (`sudo vim`) and the wrappers'
    /// own flags and values (`sudo -u root vim`).
    static func program(in line: String?) -> (section: ProgramKeySection, name: String)? {
        guard let line else { return nil }
        var sawWrapper = false
        for token in words(line) {
            if isAssignment(token) { continue }
            if token.hasPrefix("-") {
                if sawWrapper { continue }
                return nil
            }
            let name = ProgramKeyCatalog.normalizedProgramName(token)
            if wrappers.contains(name) {
                sawWrapper = true
                continue
            }
            if let section = ProgramKeyCatalog.section(forProgram: name) {
                return (section, name)
            }
            // After a wrapper, a word that is no program is a flag's value.
            if sawWrapper { continue }
            return nil
        }
        return nil
    }

    /// A program the title names at either end: "vim notes.txt", or Vim's own
    /// "notes.txt (~) - VIM". Only the ends, so a title that merely mentions a
    /// program in passing is not taken for it.
    static func program(inTitle title: String) -> (section: ProgramKeySection, name: String)? {
        let tokens = words(title)
        for token in [tokens.first, tokens.last].compactMap({ $0 }) {
            let name = ProgramKeyCatalog.normalizedProgramName(token)
            if let section = ProgramKeyCatalog.section(forProgram: name), section != .shell, section != .ssh {
                return (section, name)
            }
        }
        return nil
    }

    /// The command being typed, once its name is finished — followed by a
    /// space — and `CommandSpecs` knows it. A subcommand is taken the same way,
    /// once it too has a space after it.
    static func typing(in line: String) -> TypedCommand? {
        guard let lastSpace = line.lastIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
        let finished = words(String(line[..<lastSpace]))
        var index = 0
        var sawWrapper = false
        while index < finished.count {
            let token = finished[index]
            if isAssignment(token) || (sawWrapper && token.hasPrefix("-")) {
                index += 1
                continue
            }
            if wrappers.contains(ProgramKeyCatalog.normalizedProgramName(token)) {
                sawWrapper = true
                index += 1
                continue
            }
            break
        }
        guard index < finished.count else { return nil }
        let name = ProgramKeyCatalog.normalizedProgramName(finished[index])
        guard let spec = CommandSpecs.spec(named: name) else { return nil }
        var subcommand: String?
        if spec.hasSubcommands, index + 1 < finished.count, let entry = spec.subcommand(named: finished[index + 1]) {
            subcommand = entry.names.first
        }
        return TypedCommand(command: spec.name, subcommand: subcommand)
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
    }

    /// `NAME=value`, which sets a variable for the command after it.
    private static func isAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "="), equals != token.startIndex else { return false }
        let name = token[..<equals]
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
