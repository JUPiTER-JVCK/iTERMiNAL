import Foundation

/// The cheatsheet pages written for this app: what a program is, how it is
/// called, and the commands people reach for, each with a line on what it does.
///
/// A program's flags are not here. The composer already keeps them in
/// `CommandSpecs`, and the page reads them from there, so a flag is written
/// down once.
///
/// It is written by hand, for the tools macOS ships (BSD `sed`, `find`, `tar`,
/// `du`; Apple's `open` and `defaults`), and nothing is run to find out. Foundation
/// only, so the table is checked in CI: every line must parse, no program or
/// command may be given twice, and a program with nothing in it is an error.
///
/// One thing to a line. A command can contain ` | `, so fields are not
/// separated by it; a recipe is three lines instead.
///
///     prog NAME | SUMMARY       starts a program
///     use SYNTAX                how it is called; opens with the program's name or a tag
///     tags WORD WORD            other names it goes by
///     sec HEADING               the heading the recipes below sit under
///     ? WHAT IT DOES            a recipe: what it does, without a full stop
///     $ COMMAND                 ...and the command, `{{placeholders}}` for values
///     ~ WORDS                   optional: other words to find it by
///
/// Lines starting with `#` are notes to whoever edits the table.
enum CheatsheetCurated {
    static var library: CheatLibrary { table.library }

    /// Everything wrong with the table; empty when it is sound.
    static var problems: [String] { table.problems }

    private static let table: (library: CheatLibrary, problems: [String]) = {
        let parsed = parse(text)
        return (CheatLibrary(programs: parsed.programs), parsed.problems)
    }()

    static let maxDescriptionLength = 90
    static let maxSummaryLength = 80

    // MARK: Parsing

    static func parse(_ text: String) -> (programs: [CheatProgram], problems: [String]) {
        var programs: [CheatProgram] = []
        var problems: [String] = []
        var current: CheatProgram?
        var names = Set<String>()
        var commands = Set<String>()
        var section: String?
        var pending: String?          // a `?` line waiting for its `$`
        var allowIntent = false       // the line before was a `$`

        func finishProgram() {
            guard let program = current else { return }
            if program.examples.isEmpty { problems.append("\(program.name) has no recipes") }
            // A syntax line is for the program or a tool it is filed with (`killall` under
            // `kill`), so it opens with the one or the other: a typo shows up here.
            for line in program.syntax {
                let first = line.split(separator: " ").first.map(String.init) ?? ""
                if first != program.name && !program.tags.contains(first) {
                    problems.append("\(program.name): the use line \"\(line)\" starts with neither the program's name nor one of its tags")
                }
            }
            programs.append(program)
            current = nil
        }

        for (number, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            func problem(_ message: String) {
                problems.append("line \(number + 1): \(message): \(line)")
            }

            let directive: String
            let rest: String
            if let marker = line.first, "?$~".contains(marker) {
                directive = String(marker)
                rest = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else {
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                directive = parts[0]
                rest = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            }

            let intentAllowed = allowIntent
            allowIntent = false
            if let waiting = pending, directive != "$" {
                problem("the recipe \"\(waiting)\" has no $ command under it")
                pending = nil
            }

            switch directive {
            case "prog":
                finishProgram()
                section = nil
                let parts = rest.components(separatedBy: " | ")
                guard parts.count == 2 else {
                    problem("a prog line is `prog name | summary`")
                    continue
                }
                let name = parts[0].trimmingCharacters(in: .whitespaces)
                let summary = parts[1].trimmingCharacters(in: .whitespaces)
                guard isProgramName(name) else {
                    problem("`\(name)` is not a program name")
                    continue
                }
                if !names.insert(name).inserted { problem("\(name) is described twice") }
                if summary.isEmpty || summary.count > maxSummaryLength || summary.hasSuffix(".") {
                    problem("a summary is one line of at most \(maxSummaryLength) characters with no full stop")
                }
                current = CheatProgram(name: name, summary: summary)

            case "use":
                guard current != nil, !rest.isEmpty else {
                    problem("a use line is `use syntax`, inside a prog")
                    continue
                }
                current!.syntax.append(rest)

            case "tags":
                guard current != nil, !rest.isEmpty else {
                    problem("a tags line is `tags word word`, inside a prog")
                    continue
                }
                current!.tags.append(contentsOf: rest.split(separator: " ").map { $0.lowercased() })

            case "sec":
                guard current != nil, !rest.isEmpty else {
                    problem("a sec line is `sec heading`, inside a prog")
                    continue
                }
                section = rest

            case "?":
                guard current != nil else {
                    problem("a recipe belongs inside a prog")
                    continue
                }
                if rest.isEmpty || rest.count > maxDescriptionLength || rest.hasSuffix(".") {
                    problem("a description is one line of at most \(maxDescriptionLength) characters with no full stop")
                }
                pending = rest

            case "$":
                guard current != nil, let description = pending else {
                    problem("a $ command goes directly under its ? description")
                    continue
                }
                pending = nil
                if rest.isEmpty {
                    problem("a $ line needs a command")
                    continue
                }
                if let message = placeholderProblem(in: rest) { problem(message) }
                let key = current!.name + "\u{0}" + rest
                if !commands.insert(key).inserted { problem("this command is given twice for \(current!.name)") }
                current!.examples.append(CheatExample(
                    description: description,
                    command: rest,
                    source: .curated,
                    intent: "",
                    section: section
                ))
                allowIntent = true

            case "~":
                guard intentAllowed, current != nil, !rest.isEmpty else {
                    problem("a ~ line gives other words for the recipe directly above it")
                    continue
                }
                current!.examples[current!.examples.count - 1].intent = rest

            default:
                problem("unknown directive `\(directive)`")
            }
        }
        if let waiting = pending { problems.append("the recipe \"\(waiting)\" has no $ command under it") }
        finishProgram()
        return (programs, problems)
    }

    private static func isProgramName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._+-".contains($0)) }
    }

    /// A `{{` with no `}}` to close it, or a placeholder with nothing in it.
    private static func placeholderProblem(in command: String) -> String? {
        let opened = command.components(separatedBy: "{{").count - 1
        let names = CheatCommand.placeholders(in: command)
        if opened != names.count { return "a {{ without its }}" }
        if names.contains(where: { $0.isEmpty }) { return "an empty {{}}" }
        return nil
    }
}
