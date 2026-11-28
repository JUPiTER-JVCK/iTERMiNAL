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
    /// "nvim" for Neovim — for the strip's badge. `host` is a multiplexer it
    /// runs inside, whose keys are wanted beside its own: Vim in a tmux pane.
    case program(ProgramKeySection, name: String, host: ProgramKeySection? = nil)
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
        /// The arguments the group's leader was started with, when they were
        /// read: for a shell, to tell a script from a prompt — macOS's man is a
        /// shell script — and for Python or Node, a prompt from a program.
        var foregroundArguments: [String]?
        /// The command in the current pane of the tmux in front, when tmux on
        /// this Mac was asked (`TmuxQuery`).
        var tmuxPaneCommand: String?
        /// Whether the group in front is a shell the kernel cannot see into —
        /// a container's, a VM's, sudo's — as decided once, when the group
        /// first came to the front (`hiddenShell(leader:line:)`). Decided then
        /// because the line that started it is the last one typed only until
        /// something is typed into the shell itself.
        var hiddenShell: HiddenShell?
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
        /// The leader's arguments, read when the leader is a shell or an
        /// interpreter (`ProgramKeySection.readsArguments`): macOS's man is a
        /// shell script, so the kernel names it sh and only its arguments say
        /// it is man; `python3 app.py` is a program, `python3` a prompt.
        var arguments: [String]?
        /// The group's id, so a second look at the same group can keep what
        /// the first found out about its arguments.
        var id: Int32 = 0
        /// The tmux client leading the group, for asking its server which
        /// program its pane has and which prefix is set.
        var tmux: TmuxClient?

        /// The shell's own group: a prompt.
        static let prompt = ForegroundGroup(names: [], parent: nil)
    }

    /// A tmux client, as the kernel shows it: the binary it runs, and the
    /// arguments that pick its server (`-L name`, `-S path`) — the same ones
    /// have to be passed to reach the same server.
    struct TmuxClient: Equatable {
        var executable: String
        var socketArguments: [String]
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

    /// Whether an interpreter's arguments start its prompt rather than run a
    /// program: `python3` and `python3 -i app.py` are prompts, `python3
    /// app.py`, `python3 -m http.server` and `node -e …` are not. Arguments not
    /// read count as a prompt.
    static func isInteractiveInterpreter(_ arguments: [String]?) -> Bool {
        guard let arguments else { return true }
        for argument in arguments.dropFirst() {
            if argument == "-i" || argument == "--interactive" { return true }
            if ["-c", "-m", "-e", "-p", "--eval", "--print", "-"].contains(argument) { return false }
            if argument.hasPrefix("-") { continue }
            return false
        }
        return true
    }

    /// The arguments in a tmux client's own that choose its server — `-L name`
    /// or `-S path`, written apart or together — to be passed on unchanged.
    static func tmuxSocketArguments(_ arguments: [String]) -> [String] {
        var found: [String] = []
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-L" || argument == "-S" {
                if index + 1 < arguments.count { found += [argument, arguments[index + 1]] }
                index += 2
            } else if argument.count > 2, argument.hasPrefix("-L") || argument.hasPrefix("-S") {
                found += [String(argument.prefix(2)), String(argument.dropFirst(2))]
                index += 1
            } else if ["-f", "-c", "-T"].contains(argument) {
                index += 2
            } else if argument.hasPrefix("-") {
                index += 1
            } else {
                break
            }
        }
        return found
    }

    /// A key as tmux writes it (`show-options -gv prefix`: "C-a", "M-a",
    /// "C-Space", "`"), as a key cap: "⌃A". Nil for "None", and for a key the
    /// strip could not show and type, such as "F12" or "C-M-a".
    static func capForTmuxKey(_ key: String) -> String? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key != "None" else { return nil }
        for (spelling, symbol) in [("C-", "⌃"), ("M-", "⌥")] where key.hasPrefix(spelling) {
            let rest = String(key.dropFirst(spelling.count))
            if symbol == "⌃", rest == "Space" { return "⌃Space" }
            guard rest.count == 1, let character = rest.first, character.isASCII, !character.isWhitespace else { return nil }
            return symbol + rest.uppercased()
        }
        guard key.count == 1, let character = key.first, character.isASCII, !character.isWhitespace,
              !character.isLetter || character.isLowercase else { return nil }
        return key
    }

    /// The command key a ~/.screenrc sets with `escape` (or `defescape`), as
    /// a key cap: "escape ^Tt" makes it ⌃T, "escape ``" makes it `. The last
    /// such line wins, as it does for screen. Nil when none is set.
    static func screenEscape(fromScreenrc text: String) -> String? {
        var found: String?
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, parts[0] == "escape" || parts[0] == "defescape" else { continue }
            let value = parts[1]
            if value.hasPrefix("^"), value.count >= 2 {
                let key = value[value.index(after: value.startIndex)]
                if key.isASCII, key.isLetter { found = "⌃" + String(key).uppercased() }
            } else if let key = value.first, key.isASCII, !key.isLetter {
                found = String(key)
            }
        }
        return found
    }

    /// A shell the kernel cannot see into, because it runs on a terminal of
    /// its own: somewhere else — mosh, `docker exec -it`, `kubectl exec -it`,
    /// `vagrant ssh` — or as root, behind `sudo -i`.
    enum HiddenShell: Equatable {
        case remote
        case root
    }

    /// Whether the group led by `leader`, started by `line`, is a hidden shell.
    static func hiddenShell(leader: String, line: String?) -> HiddenShell? {
        let leader = ProgramKeyCatalog.normalizedProgramName(leader)
        if opensRemoteShell(leader: leader, line: line) { return .remote }
        if wrappers.contains(leader), opensRootShell(line) { return .root }
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
            let leaderName = ProgramKeyCatalog.normalizedProgramName(leader)
            switch signals.hiddenShell {
            case .remote?:
                // A shell somewhere else, reached from this one: mosh, or a
                // container's or a VM's shell (`docker exec -it … sh`).
                return farEnd(signals, remote: true)
            case .root?:
                // sudo -i, sudo -s, sudo su, doas -s: a root shell, which sudo
                // runs on a terminal of its own. On this Mac, so a command's
                // flags still apply.
                return farEnd(signals, remote: false)
            case nil:
                break
            }
            switch ProgramKeyCatalog.section(forProgram: leader) {
            case .shell?:
                return shellLeads(signals, group: foreground)
            case .ssh?:
                return farEnd(signals, remote: true)
            case .pager? where signals.foregroundParent.flatMap(ProgramKeyCatalog.section(forProgram:)) == .man:
                // The pager man started: what is being read is a manual page.
                return .program(.man, name: "man")
            case .tmux?:
                return insideTmux(signals, name: leaderName)
            case let section? where section.isInterpreter:
                return isInteractiveInterpreter(signals.foregroundArguments)
                    ? .program(section, name: leaderName) : .running(leaderName)
            case let section?:
                return .program(section, name: leaderName)
            case nil:
                break
            }
            // A pipeline, or a program that runs another in its own group:
            // `git log` shows its output in less, `git commit` opens the editor.
            for member in foreground.dropFirst() {
                guard let section = listedSection(member), !section.isInterpreter else { continue }
                return .program(section, name: ProgramKeyCatalog.normalizedProgramName(member))
            }
            if leaderName == "git", let subcommand = patchSubcommand(in: signals.lastCommandLine) {
                return .program(.gitPatch, name: "git \(subcommand) -p")
            }
            if wrappers.contains(leaderName) {
                if let found = program(in: signals.lastCommandLine), found.section != .ssh, found.section != .shell {
                    if found.section.isInterpreter, !isInteractiveInterpreter([found.name] + found.arguments) {
                        return .running(found.name)
                    }
                    return .program(found.section, name: found.name)
                }
            }
            return .running(leaderName.isEmpty ? nil : leaderName)
        }
        return farEnd(signals, remote: signals.isRemote)
    }

    /// tmux in front: the program in its current pane, with tmux's keys beside
    /// it, when tmux could be asked and the pane has one listed; tmux's own
    /// keys otherwise — at a shell in the pane, say.
    private static func insideTmux(_ signals: Signals, name: String) -> ActiveProgram {
        if let pane = signals.tmuxPaneCommand, let section = listedSection(pane), section != .tmux {
            return .program(section, name: ProgramKeyCatalog.normalizedProgramName(pane), host: .tmux)
        }
        return .program(.tmux, name: name)
    }

    /// A shell leading the group in front is one of two things. Started from
    /// the prompt to be used — `bash` typed in zsh — it is at a prompt of its
    /// own, alone in its group: an interactive shell gives every command it
    /// runs a group of its own. Running a script, it is not: the script's
    /// commands share its group. macOS's man is such a script, with mandoc and
    /// less beside it, and was read as a prompt until this told them apart.
    private static func shellLeads(_ signals: Signals, group: [String]) -> ActiveProgram {
        let script = signals.foregroundArguments.flatMap(script(inShellArguments:))
        if let script, let section = listedSection(script) {
            return .program(section, name: script)
        }
        guard group.count > 1 || script != nil else {
            return atPrompt(signals, remote: false)
        }
        // A script that is no program listed: what it runs may be.
        for member in group.dropFirst() {
            if let section = listedSection(member) {
                return .program(section, name: ProgramKeyCatalog.normalizedProgramName(member))
            }
        }
        let running = script
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

    /// At a prompt: the shell's keys, or the flags of the command being typed.
    /// Not on a shell somewhere else: the flags come from this Mac's own tools,
    /// and the far end's differ — GNU `sed -i` is not macOS's.
    private static func atPrompt(_ signals: Signals, remote: Bool) -> ActiveProgram {
        if !remote, let line = signals.typedLine, let typed = typing(in: line) {
            return .typing(typed)
        }
        return .shell(remote: remote)
    }

    /// The program a command line runs, when the catalog lists it: past
    /// assignments (`TERM=xterm vim`), wrappers (`sudo vim`) and the wrappers'
    /// own flags and values (`sudo -u root vim`) — and the words after it.
    static func program(in line: String?) -> (section: ProgramKeySection, name: String, arguments: [String])? {
        guard let line else { return nil }
        var sawWrapper = false
        let tokens = words(line)
        for (index, token) in tokens.enumerated() {
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
                return (section, name, Array(tokens[(index + 1)...]))
            }
            // After a wrapper, a word that is no program is a flag's value.
            if sawWrapper { continue }
            return nil
        }
        return nil
    }

    /// Whether a command line asks sudo or doas for a shell: `-i`, `-s`,
    /// `--login`, `--shell`, or a shell or `su` as the command.
    static func opensRootShell(_ line: String?) -> Bool {
        guard let line else { return false }
        let tokens = words(line).filter { !isAssignment($0) }
        guard let first = tokens.firstIndex(where: { ["sudo", "doas"].contains(ProgramKeyCatalog.normalizedProgramName($0)) }) else {
            return false
        }
        // The flags that take a value of their own: what follows them is not
        // the command.
        let takesValue: Set<String> = ["-u", "-g", "-h", "-p", "-C", "-D", "-r", "-t", "-U", "-T"]
        var index = first + 1
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" { index += 1; break }
            if token == "--login" || token == "--shell" { return true }
            if token.hasPrefix("--") { index += 1; continue }
            if token.hasPrefix("-"), token.count > 1 {
                let letters = token.dropFirst()
                if letters.contains("i") || letters.contains("s") { return true }
                index += takesValue.contains(token) ? 2 : 1
                continue
            }
            break
        }
        guard index < tokens.count else { return false }
        let command = ProgramKeyCatalog.normalizedProgramName(tokens[index])
        return command == "su" || ProgramKeyCatalog.section(forProgram: command) == .shell
    }

    /// Whether the program in front, by the line that started it, is a shell
    /// somewhere else: mosh, or a container's or a VM's — `docker exec -it`,
    /// `docker run -it`, `kubectl exec -it`, `vagrant ssh`. A `docker logs -f`
    /// is not, and is left alone.
    static func opensRemoteShell(leader: String, line: String?) -> Bool {
        if leader == "mosh-client" || leader == "mosh" { return true }
        guard let line else { return false }
        let tokens = words(line).filter { !isAssignment($0) }
        guard let at = tokens.firstIndex(where: { ProgramKeyCatalog.normalizedProgramName($0) == leader }) else { return false }
        let rest = Array(tokens[(at + 1)...])
        let subcommand = rest.first { !$0.hasPrefix("-") }
        let flags = rest.filter { $0.hasPrefix("-") }
        let interactive = flags.contains { flag in
            flag == "-i" || flag == "--interactive" || flag == "--stdin"
                || (!flag.hasPrefix("--") && flag.contains("i") && flag.contains("t"))
        }
        switch leader {
        case "docker", "podman", "nerdctl":
            if subcommand == "attach" { return true }
            return (subcommand == "exec" || subcommand == "run") && interactive
        case "kubectl", "oc":
            return ["exec", "run", "attach", "debug"].contains(subcommand ?? "") && interactive
        case "lxc", "incus":
            return subcommand == "exec" || subcommand == "shell"
        case "vagrant":
            return subcommand == "ssh"
        case "multipass", "limactl", "orb", "orbctl":
            return subcommand == "shell"
        default:
            return false
        }
    }

    /// The git subcommand a line runs in patch mode, asking about each hunk:
    /// `git add -p`, and checkout, reset, restore, stash and commit with `-p`
    /// or `--patch`.
    static func patchSubcommand(in line: String?) -> String? {
        guard let line else { return nil }
        let tokens = words(line).filter { !isAssignment($0) }
        guard let git = tokens.firstIndex(where: { ProgramKeyCatalog.normalizedProgramName($0) == "git" }) else { return nil }
        var index = git + 1
        // git's own options, before the subcommand: -C and -c take a value.
        while index < tokens.count, tokens[index].hasPrefix("-") {
            index += (tokens[index] == "-C" || tokens[index] == "-c") ? 2 : 1
        }
        guard index < tokens.count else { return nil }
        let subcommand = tokens[index]
        guard ["add", "checkout", "reset", "restore", "stash", "commit"].contains(subcommand) else { return nil }
        let rest = tokens[(index + 1)...]
        return rest.contains("-p") || rest.contains("--patch") ? subcommand : nil
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
