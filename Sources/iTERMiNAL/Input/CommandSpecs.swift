import Foundation

/// One flag or one subcommand a tool understands, as the composer lists it.
struct SpecEntry: Equatable {
    /// Every spelling that means it, as typed: `-a`, `--all`. A name that ends
    /// in `=` (`--author=`) has its value written straight after it.
    var names: [String]
    /// The spellings as a list shows them, with what a value looks like:
    /// `-m <message>, --message=<message>`.
    var display: String
    var detail: String
    /// The next word is this flag's value: `-m "text"`.
    var takesSeparateValue: Bool
}

/// What the composer knows about one tool.
struct CommandSpec: Equatable {
    var name: String
    /// The tool's own flags. For a tool with subcommands these are the ones
    /// that come before the subcommand: `git -C dir status`.
    var options: [SpecEntry] = []
    var subcommands: [SpecEntry] = []
    /// A subcommand's flags, by the subcommand's first name.
    var subcommandOptions: [String: [SpecEntry]] = [:]

    var hasSubcommands: Bool { !subcommands.isEmpty }

    func subcommand(named word: String) -> SpecEntry? {
        subcommands.first { $0.names.contains(word) }
    }

    /// The flags that apply after `subcommand`, or the tool's own before one.
    func options(after subcommand: SpecEntry?) -> [SpecEntry] {
        guard let subcommand else { return options }
        return subcommandOptions[subcommand.names[0]] ?? []
    }
}

/// A short table of common tools, for completing their flags and subcommands
/// with a line on what each does.
///
/// It is written by hand, for the versions macOS ships (BSD `ls`, `grep`, `sed`,
/// `tar`; Apple's `open`), and it is not read from the tools: nothing is run to
/// find out. A tool that is not in it gets no completion, and a flag that is not
/// in it is simply not offered. Foundation only, so the table is checked in CI:
/// every line must parse and no name may be given twice.
///
/// One directive to a line, fields separated by ` | `:
///
///     cmd NAME                          starts a tool
///     opt | NAMES | DESCRIPTION         a flag of the tool
///     sub NAMES | DESCRIPTION           a subcommand
///     sopt SUBS | NAMES | DESCRIPTION   a flag of those subcommands
///
/// `NAMES` are comma-separated. `-m <message>` takes the next word as its value;
/// `--author=<pattern>` takes it after the `=`.
enum CommandSpecs {
    static func spec(named name: String) -> CommandSpec? {
        table.specs[name]
    }

    /// Everything wrong with the table; empty when it is sound.
    static var problems: [String] { table.problems }

    /// The tools the table covers.
    static var toolNames: [String] { table.specs.keys.sorted() }

    private static let table = parse(text)

    static let maxDetailLength = 64

    // MARK: Parsing

    static func parse(_ text: String) -> (specs: [String: CommandSpec], problems: [String]) {
        var specs: [String: CommandSpec] = [:]
        var problems: [String] = []
        var current: CommandSpec?

        func finish() {
            guard let spec = current else { return }
            if spec.options.isEmpty && spec.subcommands.isEmpty {
                problems.append("\(spec.name) has nothing in it")
            }
            specs[spec.name] = spec
            current = nil
        }

        let lines = text.components(separatedBy: "\n")
        for (number, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            func problem(_ message: String) {
                problems.append("line \(number + 1): \(message): \(line)")
            }

            let parts = line.components(separatedBy: " | ")
            let head = parts[0].split(separator: " ", maxSplits: 1).map(String.init)
            guard let directive = head.first else { continue }
            let argument = head.count > 1 ? head[1] : ""

            switch directive {
            case "cmd":
                finish()
                guard parts.count == 1, !argument.isEmpty, !argument.contains(" ") else {
                    problem("a cmd line is `cmd name`")
                    continue
                }
                if specs[argument] != nil { problem("\(argument) is described twice") }
                current = CommandSpec(name: argument)

            case "opt":
                guard current != nil, parts.count == 3, argument.isEmpty else {
                    problem("an opt line is `opt | names | description`, inside a cmd")
                    continue
                }
                guard let entry = entry(names: parts[1], detail: parts[2], isOption: true, problem: problem) else { continue }
                if let clash = clashing(entry, with: current!.options) { problem("\(clash) is given twice") }
                current!.options.append(entry)

            case "sub":
                guard current != nil, parts.count == 2, !argument.isEmpty else {
                    problem("a sub line is `sub names | description`, inside a cmd")
                    continue
                }
                guard let entry = entry(names: argument, detail: parts[1], isOption: false, problem: problem) else { continue }
                if let clash = clashing(entry, with: current!.subcommands) { problem("\(clash) is given twice") }
                current!.subcommands.append(entry)

            case "sopt":
                guard current != nil, parts.count == 3, !argument.isEmpty else {
                    problem("a sopt line is `sopt subs | names | description`, inside a cmd")
                    continue
                }
                guard let entry = entry(names: parts[1], detail: parts[2], isOption: true, problem: problem) else { continue }
                for word in argument.components(separatedBy: ", ") {
                    guard let sub = current!.subcommand(named: word) else {
                        problem("\(word) is not a subcommand of \(current!.name) (declare it with sub first)")
                        continue
                    }
                    let key = sub.names[0]
                    let existing = current!.subcommandOptions[key] ?? []
                    if let clash = clashing(entry, with: existing) { problem("\(clash) is given twice for \(key)") }
                    current!.subcommandOptions[key, default: []].append(entry)
                }

            default:
                problem("unknown directive `\(directive)`")
            }
        }
        finish()
        return (specs, problems)
    }

    private static func clashing(_ entry: SpecEntry, with others: [SpecEntry]) -> String? {
        let used = Set(others.flatMap(\.names))
        return entry.names.first { used.contains($0) }
    }

    private static func entry(
        names part: String,
        detail: String,
        isOption: Bool,
        problem: (String) -> Void
    ) -> SpecEntry? {
        var names: [String] = []
        var separateValue = false
        for piece in part.components(separatedBy: ", ") {
            var name = piece
            if let hint = piece.range(of: " <") {
                name = String(piece[..<hint.lowerBound])
                separateValue = true
            } else if let attached = piece.range(of: "=<") {
                name = String(piece[..<piece.index(after: attached.lowerBound)])
            }
            let looksRight = !name.isEmpty && !name.contains(" ") && !name.contains("<")
                && (isOption ? name.hasPrefix("-") : !name.hasPrefix("-"))
            guard looksRight else {
                problem("`\(piece)` is not a \(isOption ? "flag" : "subcommand") name")
                return nil
            }
            names.append(name)
        }
        let described = detail.trimmingCharacters(in: .whitespaces)
        guard !described.isEmpty, described.count <= maxDetailLength, !described.hasSuffix(".") else {
            problem("a description is one line of at most \(maxDetailLength) characters with no full stop")
            return nil
        }
        return SpecEntry(names: names, display: part, detail: described, takesSeparateValue: separateValue)
    }

    // MARK: The table

    // swiftlint:disable line_length
    private static let text = """
    # --- git -----------------------------------------------------------------
    cmd git
    opt | -C <path> | Run as if git was started in this folder
    opt | -c <name=value> | Set a configuration value for this command
    opt | --version | Show the git version
    opt | --help | Show help
    opt | --no-pager | Do not pipe output through a pager
    sub add | Stage changes
    sub bisect | Find the commit that introduced a bug
    sub blame | Show who last changed each line
    sub branch | List, create or delete branches
    sub checkout | Switch branches or restore files
    sub cherry-pick | Apply the changes of existing commits
    sub clean | Remove untracked files
    sub clone | Copy a repository
    sub commit | Record staged changes
    sub config | Get and set options
    sub diff | Show changes
    sub fetch | Download from a remote without merging
    sub grep | Search the files git tracks
    sub init | Create an empty repository
    sub log | Show the commit history
    sub merge | Join two or more histories
    sub mv | Move or rename a file
    sub pull | Fetch from a remote, then merge or rebase
    sub push | Send local commits to a remote
    sub rebase | Replay commits on top of another base
    sub reflog | Show where HEAD has been
    sub remote | Manage the remotes
    sub reset | Move HEAD, and optionally the index and files
    sub restore | Restore files in the working tree or index
    sub revert | Undo commits by making new ones
    sub rm | Remove files from the working tree and index
    sub show | Show a commit or other object
    sub stash | Set uncommitted changes aside
    sub status | Show what has changed
    sub submodule | Manage submodules
    sub switch | Switch branches
    sub tag | Create, list or delete tags
    sub worktree | Manage extra working trees
    sopt add | -A, --all | Stage all changes, including deletions
    sopt add | -p, --patch | Choose the hunks to stage
    sopt add | -u, --update | Stage changes to tracked files only
    sopt add | -n, --dry-run | Show what would be staged
    sopt add | -f, --force | Allow adding ignored files
    sopt add | -v, --verbose | Show each file as it is added
    sopt add | -N, --intent-to-add | Record that a file will be added later
    sopt commit | -m <message>, --message=<message> | Use this commit message
    sopt commit | -a, --all | Stage every modified tracked file first
    sopt commit | --amend | Replace the last commit
    sopt commit | --no-edit | Keep the existing message (with --amend)
    sopt commit | -v, --verbose | Show the diff in the message editor
    sopt commit | -n, --no-verify | Skip the pre-commit and commit-msg hooks
    sopt commit | -s, --signoff | Add a Signed-off-by line
    sopt commit | --allow-empty | Allow a commit that changes nothing
    sopt commit | -p, --patch | Choose the hunks to commit
    sopt push | -u, --set-upstream | Remember this remote branch for pull and push
    sopt push | -f, --force | Overwrite the remote branch, even if it loses commits
    sopt push | --force-with-lease | Overwrite only if the remote is as you last saw it
    sopt push | --tags | Push all tags
    sopt push | --delete | Delete the remote branch
    sopt push | -n, --dry-run | Show what would be pushed
    sopt push | --no-verify | Skip the pre-push hook
    sopt push | -v, --verbose | Show more detail
    sopt pull | --rebase | Rebase instead of merging
    sopt pull | --no-rebase | Merge instead of rebasing
    sopt pull | --ff-only | Refuse unless it can fast-forward
    sopt pull | --autostash | Stash local changes around the pull
    sopt pull | -p, --prune | Remove remote branches that are gone
    sopt pull | --all | Fetch from all remotes
    sopt pull | -v, --verbose | Show more detail
    sopt fetch | --all | Fetch from all remotes
    sopt fetch | -p, --prune | Remove remote branches that are gone
    sopt fetch | -t, --tags | Fetch all tags
    sopt fetch | --depth=<n> | Limit the history fetched
    sopt fetch | -v, --verbose | Show more detail
    sopt checkout | -b <branch> | Create a branch and switch to it
    sopt checkout | -B <branch> | Create or reset a branch and switch to it
    sopt checkout | -f, --force | Throw away local changes
    sopt checkout | --detach | Detach HEAD at the commit
    sopt switch | -c <branch>, --create <branch> | Create a branch and switch to it
    sopt switch | -d, --detach | Detach HEAD at the commit
    sopt switch | -f, --force | Throw away local changes
    sopt branch | -a, --all | List local and remote branches
    sopt branch | -r, --remotes | List remote branches
    sopt branch | -d, --delete | Delete a branch that has been merged
    sopt branch | -D | Delete a branch even if it has not been merged
    sopt branch | -m, --move | Rename a branch
    sopt branch | -v, --verbose | Show the latest commit of each branch
    sopt branch | --merged | Only branches merged into HEAD
    sopt branch | --no-merged | Only branches not merged into HEAD
    sopt branch | --show-current | Print the name of the current branch
    sopt branch | -u <upstream>, --set-upstream-to=<upstream> | Set the upstream of a branch
    sopt log | --oneline | One line per commit
    sopt log | --graph | Draw the branch graph
    sopt log | --all | Include every branch
    sopt log | -p, --patch | Show the changes in each commit
    sopt log | --stat | Show which files changed and by how much
    sopt log | -n <number>, --max-count=<number> | Limit the number of commits
    sopt log | --author=<pattern> | Only commits by matching authors
    sopt log | --since=<date> | Only commits after the date
    sopt log | --until=<date> | Only commits before the date
    sopt log | --grep=<pattern> | Only commits whose message matches
    sopt log | --follow | Follow a file across renames
    sopt log | --no-merges | Hide merge commits
    sopt log | --decorate | Show branch and tag names
    sopt log | --name-only | Show only the names of changed files
    sopt diff | --staged, --cached | Show staged changes
    sopt diff | --stat | Show which files changed and by how much
    sopt diff | --name-only | Show only the names of changed files
    sopt diff | --name-status | Show names and the kind of change
    sopt diff | -w, --ignore-all-space | Ignore white space changes
    sopt diff | --word-diff | Show changes word by word
    sopt diff | --check | Warn about white space errors
    sopt status | -s, --short | Short format
    sopt status | -b, --branch | Show the branch and its tracking info
    sopt status | --porcelain | Stable output for scripts
    sopt status | --ignored | Show ignored files too
    sopt stash | -u, --include-untracked | Also stash untracked files
    sopt stash | -a, --all | Also stash ignored files
    sopt stash | -k, --keep-index | Leave staged changes in place
    sopt rebase | -i, --interactive | Edit the list of commits to replay
    sopt rebase | --continue | Resume after resolving conflicts
    sopt rebase | --abort | Stop and go back to how it was
    sopt rebase | --skip | Skip the current commit
    sopt rebase | --onto <newbase> | Replay onto a different base
    sopt rebase | --autosquash | Fold fixup commits in automatically
    sopt rebase | --autostash | Stash local changes around the rebase
    sopt rebase | --root | Rebase all commits from the first
    sopt merge | --no-ff | Always make a merge commit
    sopt merge | --ff-only | Refuse unless it can fast-forward
    sopt merge | --squash | Combine the changes without committing
    sopt merge | --no-commit | Merge but stop before committing
    sopt merge | --abort | Undo a merge in progress
    sopt merge | --continue | Finish a merge after fixing conflicts
    sopt merge | -m <message> | Use this merge commit message
    sopt reset | --soft | Keep changes staged
    sopt reset | --mixed | Keep changes in the working tree, unstaged (default)
    sopt reset | --hard | Discard all uncommitted changes
    sopt restore | -S, --staged | Restore the index (unstage)
    sopt restore | -W, --worktree | Restore the working tree files (the default)
    sopt restore | -s <tree>, --source=<tree> | Restore from this commit
    sopt clone | --depth=<n> | Copy only this many commits
    sopt clone | -b <branch>, --branch=<branch> | Check out this branch
    sopt clone | --recursive, --recurse-submodules | Also clone submodules
    sopt clone | --single-branch | Clone only one branch
    sopt clone | --bare | Make a bare repository
    sopt tag | -a, --annotate | Make an annotated tag
    sopt tag | -d, --delete | Delete a tag
    sopt tag | -l, --list | List tags
    sopt tag | -m <message>, --message=<message> | Use this tag message
    sopt tag | -f, --force | Replace an existing tag
    sopt remote | -v, --verbose | Show the URLs
    sopt show | --stat | Show which files changed and by how much
    sopt show | --name-only | Show only the names of changed files
    sopt show | -s, --no-patch | Hide the diff
    sopt clean | -f, --force | Required before it removes anything
    sopt clean | -d | Also remove untracked folders
    sopt clean | -n, --dry-run | Show what would be removed
    sopt clean | -x | Also remove ignored files
    sopt clean | -i, --interactive | Choose what to remove
    sopt cherry-pick | -x | Add the original commit id to the message
    sopt cherry-pick | -n, --no-commit | Apply without committing
    sopt cherry-pick | --continue | Resume after resolving conflicts
    sopt cherry-pick | --abort | Stop and go back to how it was
    sopt cherry-pick | --skip | Skip the current commit
    sopt revert | --no-edit | Keep the generated message
    sopt revert | -n, --no-commit | Apply without committing
    sopt revert | --continue | Resume after resolving conflicts
    sopt revert | --abort | Stop and go back to how it was
    sopt blame | -L <range> | Only these lines (start,end)
    sopt blame | -w | Ignore white space changes
    sopt grep | -n, --line-number | Show line numbers
    sopt grep | -i, --ignore-case | Ignore upper and lower case
    sopt grep | -l, --files-with-matches | Show only the names of files that match
    sopt grep | -c, --count | Show a count of matches per file
    sopt grep | -w, --word-regexp | Match whole words only
    sopt grep | -E, --extended-regexp | Use extended regular expressions
    sopt grep | -I | Skip binary files
    sopt grep | --untracked | Also search untracked files
    sopt config | --global | Use the user-wide configuration
    sopt config | --local | Use this repository's configuration
    sopt config | -l, --list | Show all settings
    sopt config | -e, --edit | Open the configuration file in an editor

    # --- files and text ------------------------------------------------------
    cmd ls
    opt | -a | Include entries that start with a dot
    opt | -A | Like -a, but without the . and .. entries
    opt | -l | Long format
    opt | -h | Sizes people can read (with -l)
    opt | -t | Sort by time modified, newest first
    opt | -r | Reverse the sort order
    opt | -S | Sort by size, largest first
    opt | -R | List subfolders too
    opt | -1 | One entry per line
    opt | -d | List folders themselves, not what is in them
    opt | -F | Mark folders, programs and links
    opt | -G | Colorize the output
    opt | -i | Show inode numbers
    opt | -s | Show the size in blocks
    opt | -n | Show user and group as numbers (with -l)
    opt | -@ | Show extended attributes (with -l)

    cmd cp
    opt | -R, -r | Copy folders and everything in them
    opt | -i | Ask before overwriting
    opt | -f | Overwrite without asking
    opt | -n | Never overwrite an existing file
    opt | -p | Keep times, modes and ownership
    opt | -v | Show each file as it is copied
    opt | -a | Archive: recursive, keeping attributes and links
    opt | -c | Clone files (copy on write) where the volume can

    cmd mv
    opt | -i | Ask before overwriting
    opt | -f | Overwrite without asking
    opt | -n | Never overwrite an existing file
    opt | -v | Show each file as it is moved

    cmd rm
    opt | -r, -R | Remove folders and everything in them
    opt | -f | Never ask; ignore files that do not exist
    opt | -i | Ask before each removal
    opt | -v | Show each file as it is removed
    opt | -d | Remove empty folders too

    cmd mkdir
    opt | -p | Make parent folders as needed
    opt | -m <mode> | Set the mode of the new folder
    opt | -v | Show each folder as it is made

    cmd ln
    opt | -s | Make a symbolic link
    opt | -f | Replace an existing destination
    opt | -i | Ask before replacing
    opt | -v | Show each link as it is made

    cmd cat
    opt | -n | Number every line
    opt | -b | Number the lines that are not blank
    opt | -s | Squeeze runs of blank lines into one
    opt | -v | Show non-printing characters visibly
    opt | -e | Show $ at the end of each line (implies -v)
    opt | -t | Show tabs as ^I (implies -v)
    opt | -u | Do not buffer the output

    cmd head
    opt | -n <count> | Number of lines to show
    opt | -c <bytes> | Number of bytes to show

    cmd tail
    opt | -n <count> | Number of lines to show
    opt | -c <bytes> | Number of bytes to show
    opt | -f | Keep showing new lines as they are added
    opt | -F | Like -f, but follow a file that is renamed or replaced
    opt | -r | Show the lines in reverse order

    cmd wc
    opt | -l | Count lines
    opt | -w | Count words
    opt | -c | Count bytes
    opt | -m | Count characters

    cmd sort
    opt | -n | Compare as numbers
    opt | -r | Reverse the order
    opt | -u | Keep only the first of equal lines
    opt | -k <key> | Sort on this field (for example 2,2)
    opt | -t <char> | Field separator
    opt | -f | Ignore upper and lower case
    opt | -h | Compare sizes like 2K and 1G
    opt | -V | Sort by version number
    opt | -b | Ignore leading blanks
    opt | -s | Keep equal lines in their original order
    opt | -o <file> | Write the result to a file

    cmd diff
    opt | -u | Unified format
    opt | -r | Compare folders recursively
    opt | -q | Only say whether the files differ
    opt | -w | Ignore all white space
    opt | -b | Ignore changes in the amount of white space
    opt | -i | Ignore upper and lower case

    cmd grep
    opt | -i, --ignore-case | Ignore upper and lower case
    opt | -v, --invert-match | Show lines that do not match
    opt | -n, --line-number | Show line numbers
    opt | -r, -R, --recursive | Search folders recursively
    opt | -l, --files-with-matches | Show only the names of files that match
    opt | -L, --files-without-match | Show only the names of files with no match
    opt | -c, --count | Show a count of matching lines per file
    opt | -w, --word-regexp | Match whole words only
    opt | -x, --line-regexp | Match whole lines only
    opt | -o, --only-matching | Show only the matching part of each line
    opt | -E, --extended-regexp | Use extended regular expressions
    opt | -F, --fixed-strings | Treat the pattern as plain text
    opt | -A <num>, --after-context=<num> | Also show this many lines after each match
    opt | -B <num>, --before-context=<num> | Also show this many lines before each match
    opt | -C <num>, --context=<num> | Also show this many lines around each match
    opt | -h, --no-filename | Do not print file names
    opt | -H, --with-filename | Always print file names
    opt | -q, --quiet, --silent | No output; only the exit status
    opt | -s, --no-messages | Hide errors about unreadable files
    opt | -e <pattern>, --regexp=<pattern> | Use this pattern (can be repeated)
    opt | -f <file>, --file=<file> | Read patterns from a file
    opt | -m <num>, --max-count=<num> | Stop after this many matching lines
    opt | -I | Skip binary files
    opt | --include=<glob> | Search only files whose name matches
    opt | --exclude=<glob> | Skip files whose name matches
    opt | --exclude-dir=<glob> | Skip folders whose name matches
    opt | --color, --colour | Highlight the matches

    cmd sed
    opt | -i <suffix> | Edit files in place (macOS needs a suffix; use '' for none)
    opt | -E | Use extended regular expressions
    opt | -n | Only print what the script prints
    opt | -e <script> | Add this script
    opt | -f <file> | Read the script from a file

    cmd find
    opt | -name <pattern> | Name matches the pattern (case sensitive)
    opt | -iname <pattern> | Name matches the pattern (ignoring case)
    opt | -type <kind> | Kind: f file, d folder, l link
    opt | -maxdepth <levels> | Go no deeper than this
    opt | -mindepth <levels> | Skip entries above this depth
    opt | -mtime <days> | Modified this many days ago (+n older, -n newer)
    opt | -size <size> | Size, for example +10M for over 10 MB
    opt | -newer <file> | Modified more recently than the file
    opt | -perm <mode> | Permissions match the mode
    opt | -empty | An empty file or folder
    opt | -print0 | Separate names with NUL (for xargs -0)
    opt | -delete | Delete what matches (careful)
    opt | -not | Reverse the next test

    cmd tar
    opt | -c | Create an archive
    opt | -x | Extract an archive
    opt | -t | List what is in an archive
    opt | -f <file> | The archive to use
    opt | -v | List files as they are processed
    opt | -z | Compress with gzip
    opt | -j | Compress with bzip2
    opt | -J | Compress with xz
    opt | -a | Pick the compression from the file name
    opt | -C <dir> | Change to this folder first
    opt | -p | Keep permissions when extracting
    opt | -k | Do not overwrite existing files
    opt | --exclude=<pattern> | Leave out files that match
    opt | --strip-components=<n> | Drop this many leading folders when extracting

    cmd unzip
    opt | -l | List what is in the archive
    opt | -d <dir> | Extract into this folder
    opt | -o | Overwrite without asking
    opt | -n | Never overwrite existing files
    opt | -q | Quiet

    cmd du
    opt | -h | Sizes people can read
    opt | -s | Show only a total for each argument
    opt | -d <depth> | Go this many levels down
    opt | -a | Show files as well as folders
    opt | -c | Add a grand total
    opt | -x | Stay on one file system
    opt | -k | Sizes in kilobytes

    cmd df
    opt | -h | Sizes people can read (powers of 1024)
    opt | -H | Sizes people can read (powers of 1000)
    opt | -k | Sizes in kilobytes
    opt | -i | Show inode counts

    cmd jq
    opt | -r | Print strings without quotes
    opt | -c | Compact output, one value per line
    opt | -s | Read all the input into one array
    opt | -n | Use null as the input
    opt | -S | Sort the keys of objects

    # --- network and remote --------------------------------------------------
    cmd curl
    opt | -s, --silent | No progress meter or error messages
    opt | -S, --show-error | Show errors even with -s
    opt | -L, --location | Follow redirects
    opt | -o <file>, --output <file> | Write the response to a file
    opt | -O, --remote-name | Save under the name the server gives
    opt | -X <method>, --request <method> | Use this HTTP method
    opt | -H <header>, --header <header> | Add a request header
    opt | -d <data>, --data <data> | Send this data in a POST
    opt | -F <name=content>, --form <name=content> | Send a multipart form field
    opt | -T <file>, --upload-file <file> | Upload a file
    opt | -I, --head | Fetch the headers only
    opt | -i, --include | Include the response headers in the output
    opt | -v, --verbose | Show the whole exchange
    opt | -u <user:password>, --user <user:password> | Log in as user:password (shows up in ps)
    opt | -A <name>, --user-agent <name> | Send this User-Agent
    opt | -k, --insecure | Skip certificate checks (unsafe)
    opt | -f, --fail | Fail on HTTP errors instead of printing them
    opt | -m <seconds>, --max-time <seconds> | Give up after this many seconds
    opt | --connect-timeout <seconds> | Give up connecting after this many seconds
    opt | --compressed | Ask for a compressed response
    opt | --retry <n> | Retry this many times on a temporary error

    cmd ssh
    opt | -p <port> | Port to connect to
    opt | -i <file> | Private key to use
    opt | -l <user> | Log in as this user
    opt | -L <spec> | Forward a local port (port:host:hostport)
    opt | -R <spec> | Forward a remote port (port:host:hostport)
    opt | -D <port> | Forward a local port as a SOCKS proxy
    opt | -J <host> | Connect through a jump host
    opt | -o <option> | Set an option, as in ssh_config (Name=value)
    opt | -F <file> | Use this config file
    opt | -N | Do not run a command (for forwarding only)
    opt | -f | Go to the background before running the command
    opt | -t | Force a terminal, even for a command
    opt | -T | Do not allocate a terminal
    opt | -A | Forward the authentication agent
    opt | -a | Do not forward the authentication agent
    opt | -C | Compress the connection
    opt | -q | Quiet: hide warnings and messages
    opt | -v | Verbose: show what is happening (repeat for more)
    opt | -4 | Use IPv4 only
    opt | -6 | Use IPv6 only

    cmd scp
    opt | -r | Copy folders recursively
    opt | -P <port> | Port to connect to
    opt | -i <file> | Private key to use
    opt | -J <host> | Connect through a jump host
    opt | -o <option> | Set an option, as in ssh_config (Name=value)
    opt | -F <file> | Use this ssh config file
    opt | -C | Compress the transfer
    opt | -p | Keep times and modes
    opt | -q | Quiet: hide the progress meter
    opt | -v | Verbose

    cmd ssh-keygen
    opt | -t <type> | Key type: ed25519, rsa or ecdsa
    opt | -b <bits> | Key size in bits (rsa, ecdsa)
    opt | -C <comment> | Comment stored with the key
    opt | -f <file> | File to write the key to, or read
    opt | -l | Show the fingerprint of a key
    opt | -y | Print the public key for a private key
    opt | -p | Change the passphrase of a key
    opt | -R <host> | Remove a host from known_hosts
    opt | -E <hash> | Hash for fingerprints: sha256 or md5

    # --- macOS ---------------------------------------------------------------
    cmd open
    opt | -a <app> | Open with this application
    opt | -b <bundle-id> | Open with the application that has this bundle id
    opt | -e | Open in TextEdit
    opt | -t | Open in the default text editor
    opt | -R | Reveal in Finder instead of opening
    opt | -n | Open a new instance of the application
    opt | -W | Wait until the application quits
    opt | -g | Do not bring the application to the front

    cmd defaults
    sub read | Print a setting, or all the settings of a domain
    sub write | Set a setting
    sub delete | Remove a setting
    sub domains | List the domains that have settings
    sub find | Search every domain for a word
    sub rename | Rename a key
    sub export | Write a domain out as a plist
    sub import | Read a domain from a plist
    sub read-type | Print the type of a setting

    # --- macOS system tools --------------------------------------------------
    # Written from Apple's published manual pages for these tools, and checked
    # against them: every flag and subcommand below is one the page documents,
    # with one exception, `ipconfig getiflist`, which the tool's own usage text
    # prints and tldr-pages uses though its page does not list it. Apple's pages
    # are for one release, so a Mac may have more than is here; the Cheatsheet
    # also shows the manual page installed on the Mac itself.
    cmd ipconfig
    sub getiflist | List the network interfaces
    sub getifaddr | Print the IPv4 address of an interface
    sub ifcount | Print how many interfaces can be configured
    sub getsummary | Show the IP configuration of an interface
    sub getoption | Print one DHCP option the interface was given
    sub getpacket | Print the DHCP packet the interface was given
    sub getv6packet | Print the DHCPv6 packet the interface was given
    sub getra | Print the IPv6 router advertisement received
    sub getdhcpduid | Print this Mac's DHCP unique identifier
    sub getdhcpiaid | Print the DHCPv6 identity association id of an interface
    sub waitall | Wait until every network service has finished configuring
    sub set | Give an interface a temporary configuration (needs root)
    sub setverbose | Turn verbose agent logging on or off (needs root)

    cmd ifconfig
    opt | -a | Show every interface, including ones that are down
    opt | -l | List only the names of the interfaces
    opt | -u | With -a or -l, only interfaces that are up
    opt | -d | With -a or -l, only interfaces that are down
    opt | -v | Show more detail
    opt | -L | Show how long each address is valid
    opt | -m | Show the media types an interface supports
    opt | -r | Show routing information for the interface

    cmd networksetup
    opt | -listallnetworkservices | List every network service
    opt | -listallhardwareports | List hardware ports with their devices and MAC addresses
    opt | -listnetworkserviceorder | List the services in the order they are tried
    opt | -getinfo <service> | Show a service's IP address, subnet mask, router and MAC
    opt | -getdnsservers <service> | Show the DNS servers a service uses
    opt | -setdnsservers <service> | Set a service's DNS servers (Empty clears them)
    opt | -getsearchdomains <service> | Show a service's search domains
    opt | -setdhcp <service> | Use DHCP on a service
    opt | -setmanual <service> | Give a service a fixed address, mask and router
    opt | -getwebproxy <service> | Show a service's HTTP proxy
    opt | -setwebproxy <service> | Set a service's HTTP proxy
    opt | -setwebproxystate <service> | Turn a service's HTTP proxy on or off
    opt | -setsecurewebproxystate <service> | Turn a service's HTTPS proxy on or off
    opt | -getairportpower <device> | Show whether Wi-Fi is on
    opt | -setairportpower <device> | Turn Wi-Fi on or off
    opt | -getairportnetwork <device> | Show the Wi-Fi network joined
    opt | -setairportnetwork <device> | Join a Wi-Fi network
    opt | -listpreferredwirelessnetworks <device> | List the Wi-Fi networks remembered
    opt | -setnetworkserviceenabled <service> | Turn a network service on or off
    opt | -getcomputername | Show this Mac's computer name
    opt | -setcomputername | Set this Mac's computer name
    opt | -detectnewhardware | Look for network hardware that was added

    cmd scutil
    opt | --get <pref> | Print a name: ComputerName, LocalHostName or HostName
    opt | --set <pref> | Set one of those names
    opt | --dns | Show the DNS configuration
    opt | --proxy | Show the proxy configuration
    opt | --nc | Work with network connections such as VPNs
    opt | --renew <interface> | Renew the DHCP lease on an interface
    opt | -r <host> | Check whether a host or address is reachable
    opt | -W | With -r, keep watching and report changes
    opt | -w <key> | Wait for a dynamic store key to appear
    opt | -t <seconds> | How long -w waits

    cmd route
    opt | -n | Show addresses as numbers, without looking up names
    opt | -v | Print more detail
    opt | -q | Print nothing
    opt | -d | Debug: do not change the routing tables
    opt | -t | Test: do not send the change to the kernel
    sub get | Show the route used to reach a destination
    sub add | Add a route
    sub delete | Delete a route
    sub change | Change a route
    sub flush | Delete all gateway routes
    sub monitor | Watch routing changes as they happen
    sopt add, delete, change, get | -net | The destination is a network
    sopt add, delete, change, get | -host | The destination is a host
    sopt add, delete, change, get | -inet6 | Use IPv6 addresses
    sopt add, delete, change | -netmask <mask> | The netmask of the destination
    sopt add, delete, change | -interface | The gateway is an interface of this Mac

    cmd arp
    opt | -a | Show every entry in the ARP table
    opt | -n | Show addresses as numbers, without looking up names
    opt | -d <host> | Delete an entry (use -a instead of a host for all)
    opt | -s <host> | Add a static entry: the host, then its Ethernet address
    opt | -S <host> | Like -s, but replace an entry that is already there
    opt | -i <interface> | Limit to one interface
    opt | -l | Show link-layer reachability
    opt | -x | Show the extended link-layer reachability
    opt | -f <file> | Add the entries listed in a file

    cmd netstat
    opt | -a | Show all sockets, including listening ones
    opt | -n | Show addresses and ports as numbers
    opt | -r | Show the routing table
    opt | -i | Show the network interfaces and their traffic
    opt | -I <interface> | Limit to one interface
    opt | -s | Show statistics for each protocol
    opt | -p <protocol> | Show one protocol, such as tcp or udp
    opt | -f <family> | Show one address family: inet, inet6 or unix
    opt | -b | With -i, show the bytes in and out
    opt | -m | Show memory buffer (mbuf) statistics
    opt | -L | Show the sizes of the listen queues
    opt | -w <seconds> | Repeat the interface display at this interval
    opt | -v | Show more detail

    cmd traceroute
    opt | -n | Print addresses as numbers, without looking up names
    opt | -m <max_ttl> | The most hops to try
    opt | -q <nqueries> | How many probes to send for each hop
    opt | -w <seconds> | How long to wait for each reply
    opt | -I | Use ICMP echo requests instead of UDP
    opt | -P <protocol> | Send probes using this protocol
    opt | -p <port> | The port to probe
    opt | -f <first_ttl> | Start at this hop
    opt | -s <address> | Use this source address
    opt | -i <interface> | Send probes from this interface
    opt | -a | Look up the AS number of each hop
    opt | -S | Summarise how many probes went unanswered for each hop
    opt | -v | Show every ICMP packet received

    cmd pmset
    opt | -g | Show settings and state: try batt, log, assertions or sched
    opt | -a | Apply settings to every power source
    opt | -b | Apply settings to battery power
    opt | -c | Apply settings to the charger
    opt | -u | Apply settings to the UPS
    sub sleepnow | Sleep right now
    sub displaysleepnow | Turn the display off right now
    sub schedule | Schedule a one-time sleep, wake or power on
    sub repeat | Schedule a repeating sleep, wake or power on
    sub noidle | Keep the Mac from idle sleeping while this runs
    sub restoredefaults | Put every power setting back to its default

    cmd launchctl
    sub list | List the jobs that are loaded
    sub print | Print the state of a service, a domain or the whole system
    sub print-disabled | List the services that are disabled in a domain
    sub bootstrap | Load a service from a property list into a domain
    sub bootout | Unload a service from a domain
    sub enable | Let a service load
    sub disable | Stop a service loading, and remember that across restarts
    sub kickstart | Start a service now
    sub kill | Send a signal to a service
    sub load | Load a property list (the older form of bootstrap)
    sub unload | Unload a property list (the older form of bootout)
    sub start | Start a job by its label
    sub stop | Stop a job by its label
    sub remove | Remove a job by its label
    sub blame | Say why a service was started
    sub error | Explain an error code
    sopt kickstart | -k | Kill the service first if it is running
    sopt kickstart | -p | Print the process id afterwards
    sopt load, unload | -w | Also record that the job is enabled or disabled

    cmd mdutil
    opt | -s | Show the indexing status
    opt | -a | Apply to every volume
    opt | -i <on|off> | Turn Spotlight indexing on or off
    opt | -E | Erase the index and rebuild it
    opt | -d | Turn Spotlight searches off for the volume
    opt | -p | Publish the index of a network volume
    opt | -v | Print more detail

    cmd softwareupdate
    opt | -l, --list | List the updates that are available
    opt | -i, --install | Install the updates named, or those chosen by the flags below
    opt | -d, --download | Download updates without installing them
    opt | -a, --all | Every update that applies to this Mac
    opt | -r, --recommended | Only the recommended updates
    opt | -R, --restart | Restart afterwards if the install needs it
    opt | --os-only | Only macOS updates
    opt | --safari-only | Only Safari updates
    opt | --list-full-installers | List the full macOS installers on offer
    opt | --install-rosetta | Install Rosetta, for apps built for Intel
    opt | --agree-to-license | With --install-rosetta, accept the licence

    cmd tmutil
    sub startbackup | Start a backup
    sub stopbackup | Stop the backup that is running
    sub enable | Turn automatic backups on
    sub disable | Turn automatic backups off
    sub listbackups | List the backups on the destination
    sub latestbackup | Print the path of the newest backup
    sub destinationinfo | Show the backup destinations
    sub localsnapshot | Make a local snapshot now
    sub listlocalsnapshots | List the local snapshots of a volume
    sub deletelocalsnapshots | Delete the local snapshot made on a given date
    sub thinlocalsnapshots | Free space by thinning local snapshots
    sub addexclusion | Leave a file or folder out of backups
    sub removeexclusion | Put an excluded file or folder back
    sub isexcluded | Say whether a file or folder is excluded
    sub restore | Restore a file or folder from a backup
    sub compare | Compare a backup with the current files
    sopt startbackup | -a, --auto | Behave like an automatic backup
    sopt startbackup | -b, --block | Wait until the backup finishes
    sopt addexclusion | -p | Exclude by path, so it applies wherever the item moves

    cmd hdiutil
    sub attach | Mount a disk image
    sub detach | Unmount and eject a disk image
    sub create | Make a new disk image
    sub convert | Convert a disk image to another format
    sub resize | Change the size of a disk image
    sub verify | Check a disk image for errors
    sub info | Show the images that are attached
    sub imageinfo | Show information about a disk image
    sub eject | Eject a disk image or disk
    sub compact | Reclaim space from a sparse image
    sub checksum | Print the checksum of a disk image
    sub chpass | Change the password of an encrypted image
    sopt attach | -readonly | Mount it read-only
    sopt attach | -mountpoint <path> | Mount it here
    sopt attach | -nobrowse | Keep it out of Finder's sidebar
    sopt attach | -noverify | Skip checking the image first
    sopt detach | -force | Eject even if files are open
    sopt create | -size <size> | How big the image is
    sopt create | -srcfolder <path> | Fill it from this folder
    sopt create | -volname <name> | The volume name
    sopt create | -fs <filesystem> | The filesystem, such as APFS or HFS+
    sopt create | -format <format> | The image format, such as UDZO
    sopt create | -encryption | Encrypt the image
    sopt create | -ov | Overwrite a file that is already there
    sopt convert | -format <format> | The format to convert to
    sopt convert | -o <file> | Where to write the result

    cmd plutil
    opt | -p | Print a property list in a readable form
    opt | -lint | Check a property list for errors
    opt | -convert <format> | Convert to xml1, binary1, json, swift, objc or raw
    opt | -extract <keypath> <format> | Print the value at a key path
    opt | -insert <keypath> | Add a value at a key path
    opt | -replace <keypath> | Replace the value at a key path
    opt | -remove <keypath> | Remove the value at a key path
    opt | -type <keypath> | Print the type of the value at a key path
    opt | -create <format> | Create an empty property list
    opt | -o <file> | Write the result to this file
    opt | -s | Print nothing when it succeeds
    opt | -r | Add whitespace to JSON output to make it readable

    cmd xattr
    opt | -l | Print the names and the values
    opt | -p <name> | Print one attribute
    opt | -w <name> | Set an attribute to the value that follows
    opt | -d <name> | Delete one attribute
    opt | -c | Clear every attribute
    opt | -r | Go into folders
    opt | -s | Act on a symbolic link itself, not what it points to
    opt | -v | Always print the file name
    opt | -x | Read and print values as hexadecimal

    cmd say
    opt | -v <voice>, --voice=<voice> | The voice to use (-v '?' lists them)
    opt | -r <rate>, --rate=<rate> | The speed, in words per minute
    opt | -f <file>, --input-file=<file> | Speak the contents of a file
    opt | -o <file>, --output-file=<file> | Write the speech to an audio file
    opt | -a <device>, --audio-device=<device> | Play through this audio device
    opt | --file-format=<format> | The format of the file to write
    opt | --progress | Show a progress meter
    opt | -i, --interactive | Print the text and highlight words as they are spoken

    cmd screencapture
    opt | -c | Send the picture to the clipboard
    opt | -i | Pick an area or a window with the mouse
    opt | -x | Do not play the shutter sound
    opt | -T <seconds> | Wait this long before taking it
    opt | -t <format> | The image format, such as png or jpg
    opt | -w | Only allow choosing a window
    opt | -s | Only allow choosing an area
    opt | -R <x,y,w,h> | Capture this rectangle
    opt | -l <windowid> | Capture the window with this id
    opt | -m | Only capture the main display
    opt | -C | Include the pointer
    opt | -o | Leave the window's shadow out
    opt | -P | Open the picture in Preview afterwards

    cmd sips
    opt | -g <key>, --getProperty <key> | Print a property such as pixelWidth or format
    opt | -s <key> <value>, --setProperty <key> <value> | Set a property
    opt | -z <height> <width>, --resampleHeightWidth <height> <width> | Resize to a height and width
    opt | -Z <size>, --resampleHeightWidthMax <size> | Fit within a size, keeping the proportions
    opt | -r <degrees>, --rotate <degrees> | Rotate clockwise
    opt | -f <direction>, --flip <direction> | Flip horizontally or vertically
    opt | -c <height> <width>, --cropToHeightWidth <height> <width> | Crop to a height and width
    opt | -o <path>, --out <path> | Write the result here and leave the original alone

    cmd diskutil
    sub list | List the disks and their partitions
    sub info | Show details of a disk or volume
    sub mount | Mount a volume
    sub mountDisk | Mount every volume on a disk
    sub unmount | Unmount a volume
    sub unmountDisk | Unmount every volume on a disk
    sub eject | Eject a disk
    sub eraseDisk | Erase a whole disk and give it a new format
    sub eraseVolume | Erase a volume and give it a new format
    sub partitionDisk | Divide a disk into partitions
    sub rename | Rename a volume
    sub verifyVolume | Check a volume for errors
    sub repairVolume | Repair a volume
    sub verifyDisk | Check a disk's partition map
    sub repairDisk | Repair a disk's partition map
    sub apfs | Work with APFS containers and volumes
    sub listFilesystems | List the formats a disk can be given
    sopt list, info | -plist | Print as a property list

    cmd caffeinate
    opt | -d | Keep the display from sleeping
    opt | -i | Keep the Mac from idle sleeping
    opt | -m | Keep the disk from idle sleeping
    opt | -s | Keep the Mac from sleeping while on the charger
    opt | -u | Say the user is active, which wakes the display
    opt | -t <seconds> | Stop after this long
    opt | -w <pid> | Stop when this process ends

    # --- build tools ---------------------------------------------------------
    cmd make
    opt | -j, --jobs | Run jobs in parallel (give a number, for example -j8)
    opt | -n, --just-print, --dry-run | Print the commands without running them
    opt | -k, --keep-going | Keep going after an error
    opt | -s, --silent, --quiet | Do not echo the commands
    opt | -B, --always-make | Rebuild everything
    opt | -C <dir>, --directory=<dir> | Change to this folder first
    opt | -f <file>, --file=<file> | Use this makefile

    cmd swift
    opt | --version | Show the Swift version
    sub build | Build the package
    sub run | Build and run an executable
    sub test | Build and run the tests
    sub package | Manage the package: resolve, update, init
    sopt build, run, test | -c <configuration>, --configuration <configuration> | debug or release
    sopt build, run, test | -v, --verbose | Show more detail
    sopt build, run, test | --build-path <path> | Where to put the build output
    sopt build | --show-bin-path | Print where the built products go
    sopt build | --target <name> | Build only this target
    sopt build | --product <name> | Build only this product
    sopt build | --build-tests | Build the test targets too
    sopt test | --filter <regex> | Run only the tests that match
    sopt test | --parallel | Run tests in parallel

    cmd cargo
    sub build, b | Compile the current package
    sub check, c | Check for errors without building
    sub run, r | Build and run the program
    sub test, t | Run the tests
    sub bench | Run the benchmarks
    sub clippy | Lint with Clippy
    sub fmt | Format the code
    sub doc, d | Build the documentation
    sub new | Create a package in a new folder
    sub init | Create a package in this folder
    sub add | Add a dependency
    sub remove, rm | Remove a dependency
    sub update | Update the dependencies in Cargo.lock
    sub clean | Delete the target folder
    sub publish | Upload the package to crates.io
    sub install | Install a program from crates.io
    sub search | Search crates.io
    sub tree | Show the dependency tree
    sopt build, check, run, test, clippy, doc | -r, --release | Build with optimizations
    sopt build, check, run, test, clippy, doc | -p <spec>, --package <spec> | Only this package
    sopt build, check, test, clippy, doc | --workspace | Every package in the workspace
    sopt build, check, run, test, clippy, doc | -F <features>, --features <features> | Features to enable
    sopt build, check, run, test, clippy, doc | --all-features | Enable every feature
    sopt build, check, run, test, clippy, doc | --no-default-features | Leave out the default features
    sopt build, check, run, test, clippy, doc | -q, --quiet | Print less
    sopt build, check, run, test, clippy, doc | -v, --verbose | Print more
    sopt build, check, run, test, clippy, doc | --offline | Do not use the network
    sopt build, check, run, test, clippy, doc | --locked | Require Cargo.lock to be up to date
    sopt run | --bin <name> | Run this binary
    sopt run | --example <name> | Run this example
    sopt test | --no-run | Compile the tests but do not run them
    sopt test | --doc | Run only the documentation tests
    sopt doc | --open | Open the documentation in a browser
    sopt fmt | --check | Report differences instead of changing files
    sopt add | --dev | Add as a dev dependency
    sopt add | --build | Add as a build dependency
    sopt new, init | --lib | Make a library

    cmd npm
    opt | -v, --version | Show the npm version
    opt | -h, --help | Show help
    sub install, i, add | Install packages
    sub ci | Clean install from the lockfile
    sub uninstall, remove, rm | Remove packages
    sub update, up | Update packages
    sub run, run-script | Run a script from package.json
    sub start | Run the start script
    sub test, t | Run the test script
    sub init | Create a package.json
    sub list, ls | List installed packages
    sub outdated | Show packages that have newer versions
    sub audit | Check dependencies for known vulnerabilities
    sub publish | Publish a package
    sub pack | Make a tarball of the package
    sub link, ln | Link a local package
    sub exec | Run a command from a package
    sub version | Bump the package version
    sub view, info | Show a package's details from the registry
    sub search | Search the registry
    sub cache | Manage the cache
    sub config | Manage npm configuration
    sopt install | -g, --global | Install globally
    sopt install | -D, --save-dev | Save as a dev dependency
    sopt install | -E, --save-exact | Save the exact version
    sopt install | --no-save | Do not change package.json
    sopt install | --legacy-peer-deps | Ignore peer dependency conflicts
    sopt uninstall | -g, --global | Remove a global package
    sopt update | -g, --global | Update global packages
    sopt list | -g, --global | List global packages
    sopt list | --depth=<n> | Limit how deep to list
    sopt outdated | -g, --global | Check global packages
    sopt publish | --access <level> | public or restricted
    sopt publish | --tag <tag> | Publish under this tag
    sopt publish | --dry-run | Show what would be published

    cmd brew
    sub install | Install a formula or cask
    sub uninstall, remove, rm | Remove a formula or cask
    sub update | Fetch the latest Homebrew and formulae
    sub upgrade | Upgrade installed formulae and casks
    sub list, ls | List installed formulae and casks
    sub search | Search for formulae and casks
    sub info | Show details about a formula or cask
    sub outdated | Show what has a newer version
    sub cleanup | Remove old versions and cache files
    sub doctor | Check for problems
    sub services | Manage background services
    sub tap | Add a third-party repository
    sub untap | Remove a tap
    sub link | Link a formula's files into place
    sub unlink | Unlink a formula's files
    sub pin | Hold a formula at its version
    sub unpin | Let a pinned formula upgrade again
    sub autoremove | Remove dependencies nothing uses
    sub deps | Show a formula's dependencies
    sub uses | Show what depends on a formula
    sub leaves | List formulae that nothing else needs
    sub bundle | Install from a Brewfile
    sub home | Open a formula's homepage
    sub fetch | Download a formula's files
    sub config | Show Homebrew's configuration
    sopt install | --cask | Treat the name as a cask
    sopt install | --formula | Treat the name as a formula
    sopt install | -v, --verbose | Show more detail
    sopt install | --HEAD | Install the development version
    sopt install | -s, --build-from-source | Compile instead of using a bottle
    sopt uninstall | --cask | Treat the name as a cask
    sopt uninstall | --zap | Also remove all the files a cask left behind
    sopt uninstall | -f, --force | Remove every installed version
    sopt upgrade | --cask | Upgrade casks only
    sopt upgrade | --formula | Upgrade formulae only
    sopt upgrade | --greedy | Also upgrade casks that update themselves
    sopt list | --cask | Show only casks
    sopt list | --formula | Show only formulae
    sopt list | --versions | Show the installed versions
    sopt search | --cask | Search casks only
    sopt search | --formula | Search formulae only
    sopt search | --desc | Search descriptions too
    sopt info | --cask | Treat the name as a cask
    sopt info | --formula | Treat the name as a formula
    sopt outdated | --cask | Check casks only
    sopt outdated | --formula | Check formulae only
    sopt outdated | --greedy | Include casks that update themselves
    sopt cleanup | -n, --dry-run | Show what would be removed
    sopt cleanup | -s | Scrub the cache, including downloads of the latest versions

    cmd docker
    opt | -v, --version | Show the Docker version
    opt | --help | Show help
    sub build | Build an image from a Dockerfile
    sub run | Create and start a container
    sub exec | Run a command in a running container
    sub ps | List containers
    sub images | List images
    sub pull | Download an image
    sub push | Upload an image
    sub logs | Show a container's output
    sub start | Start stopped containers
    sub stop | Stop running containers
    sub restart | Restart containers
    sub rm | Remove containers
    sub rmi | Remove images
    sub cp | Copy files between a container and this Mac
    sub inspect | Show low-level details
    sub tag | Give an image another name
    sub login | Sign in to a registry
    sub logout | Sign out of a registry
    sub compose | Run multi-container applications
    sub network | Manage networks
    sub volume | Manage volumes
    sub system | Manage Docker itself (info, prune)
    sub container | Manage containers
    sub image | Manage images
    sopt run | -d, --detach | Run in the background
    sopt run | -i, --interactive | Keep standard input open
    sopt run | -t, --tty | Allocate a terminal
    sopt run | --rm | Remove the container when it exits
    sopt run | -p <ports>, --publish <ports> | Publish a port (host:container)
    sopt run | -v <mount>, --volume <mount> | Mount a volume or folder
    sopt run | -e <name=value>, --env <name=value> | Set an environment variable
    sopt run | --name <name> | Name the container
    sopt run | -w <dir>, --workdir <dir> | Working folder inside the container
    sopt run | --network <network> | Connect to a network
    sopt run | --platform <platform> | Platform, for example linux/amd64
    sopt run | --entrypoint <command> | Replace the image's entrypoint
    sopt exec | -i, --interactive | Keep standard input open
    sopt exec | -t, --tty | Allocate a terminal
    sopt exec | -e <name=value>, --env <name=value> | Set an environment variable
    sopt exec | -w <dir>, --workdir <dir> | Working folder inside the container
    sopt exec | -u <user>, --user <user> | Run as this user
    sopt ps | -a, --all | Include stopped containers
    sopt ps | -q, --quiet | Show only container IDs
    sopt images | -a, --all | Include intermediate images
    sopt images | -q, --quiet | Show only image IDs
    sopt build | -t <name:tag>, --tag <name:tag> | Name and tag the image
    sopt build | -f <file>, --file <file> | The Dockerfile to use
    sopt build | --no-cache | Do not use cached layers
    sopt build | --platform <platform> | Platform, for example linux/amd64
    sopt build | --build-arg <name=value> | Set a build argument
    sopt logs | -f, --follow | Keep showing new output
    sopt logs | --tail <n> | Show only the last n lines
    sopt logs | -t, --timestamps | Show timestamps
    sopt rm | -f, --force | Remove even if running
    sopt rm | -v, --volumes | Also remove anonymous volumes
    sopt rmi | -f, --force | Force removal
    """
    // swiftlint:enable line_length
}
