import Foundation

/// Where a cheat came from, so the page can credit the ones that are not ours.
enum CheatSource: String, Equatable {
    /// Written for this app.
    case curated
    /// From tldr-pages (CC BY 4.0), reformatted.
    case tldr
}

/// One thing to type, and what it does.
struct CheatExample: Equatable {
    /// What it does, in a line, without a full stop: "Undo the last commit".
    var description: String
    /// The command as it would be typed, with `{{placeholders}}` where the
    /// reader's own values go. One line.
    var command: String
    var source: CheatSource = .curated
    /// Other words someone might search for that the description does not
    /// say — "uncommit rollback" for a reset. Searched, never shown.
    var intent: String = ""
    /// A named group on the program's page ("Branches"), or nil.
    var section: String?
}

/// One program's page.
struct CheatProgram: Equatable {
    var name: String
    /// One line on what the program is.
    var summary: String
    /// How it is called: `git <command> [<args>]`.
    var syntax: [String] = []
    /// Words the program goes by that its name does not say.
    var tags: [String] = []
    var examples: [CheatExample] = []
    /// Written for this app, as against taken from tldr-pages.
    var isCurated = true
    /// Where to read more: an http or https address, or nil.
    var url: String?

    /// A run of examples under one heading.
    struct Group: Equatable {
        var section: String?
        /// Each example with its place in `examples`, which is what a search
        /// hit refers to.
        var items: [Item]

        struct Item: Equatable {
            var index: Int
            var example: CheatExample
        }
    }

    /// The examples under their headings, in the order they are written. An
    /// example with no heading is grouped with the other headless ones that
    /// follow it. `only` limits it to those indices.
    func groups(only indices: Set<Int>? = nil) -> [Group] {
        var result: [Group] = []
        for (index, example) in examples.enumerated() {
            if let indices, !indices.contains(index) { continue }
            let item = Group.Item(index: index, example: example)
            if let last = result.indices.last, result[last].section == example.section {
                result[last].items.append(item)
            } else {
                result.append(Group(section: example.section, items: [item]))
            }
        }
        return result
    }
}

/// Every program the cheatsheet knows, by name.
struct CheatLibrary {
    /// Sorted by name, ignoring case, one to a name.
    let programs: [CheatProgram]

    init(programs: [CheatProgram]) {
        self.programs = programs.sorted {
            let a = $0.name.lowercased(), b = $1.name.lowercased()
            return a != b ? a < b : $0.name < $1.name
        }
    }

    func program(named name: String) -> CheatProgram? {
        programs.first { $0.name == name }
    }

    var exampleCount: Int { programs.reduce(0) { $0 + $1.examples.count } }

    /// The heading that tldr-pages' own examples sit under on a page that also
    /// has ones written for this app, so the two are not run together.
    static let moreExamplesHeading = "More examples"

    /// The pages written for this app, with tldr-pages' examples added.
    ///
    /// Where both have a page for a program, ours is kept — its summary, its
    /// syntax and its recipes, in the order they were written — and tldr's
    /// examples follow, without any that give a command we already have. A
    /// program only tldr knows keeps its page as it is.
    static func merging(curated: [CheatProgram], tldr: [CheatProgram]) -> CheatLibrary {
        var others = Dictionary(tldr.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var programs: [CheatProgram] = []
        programs.reserveCapacity(curated.count + others.count)
        for var program in curated {
            if let other = others.removeValue(forKey: program.name) {
                var seen = Set(program.examples.map { normalized($0.command) })
                for var example in other.examples where seen.insert(normalized(example.command)).inserted {
                    if example.section == nil { example.section = moreExamplesHeading }
                    program.examples.append(example)
                }
                if program.url == nil { program.url = other.url }
            }
            programs.append(program)
        }
        programs.append(contentsOf: others.values)
        return CheatLibrary(programs: programs)
    }

    /// A command with its runs of spaces made single, so two spellings of the
    /// same command are the same one.
    private static func normalized(_ command: String) -> String {
        command.split(separator: " ").joined(separator: " ")
    }
}

/// A command split for showing: which stretches are a `{{placeholder}}` to
/// replace, and which characters a search matched.
enum CheatCommand {
    struct Run: Equatable {
        var text: String
        var isPlaceholder: Bool
        var isMatch: Bool
    }

    /// `command` in runs of one look each. The placeholder's braces stay in
    /// the text, so what is shown is what is inserted. `matched` are
    /// `Character` offsets into `command`, as `FuzzyMatcher` returns them.
    static func runs(_ command: String, matched: [Int] = []) -> [Run] {
        let characters = Array(command)
        let hits = Set(matched)
        var placeholder = [Bool](repeating: false, count: characters.count)
        for range in placeholderRanges(in: characters) {
            for k in range { placeholder[k] = true }
        }

        var runs: [Run] = []
        for (offset, character) in characters.enumerated() {
            let isPlaceholder = placeholder[offset]
            let isMatch = hits.contains(offset)
            if let last = runs.indices.last,
               runs[last].isPlaceholder == isPlaceholder, runs[last].isMatch == isMatch {
                runs[last].text.append(character)
            } else {
                runs.append(Run(text: String(character), isPlaceholder: isPlaceholder, isMatch: isMatch))
            }
        }
        return runs
    }

    /// Each `{{…}}`, braces included, as the offsets it covers. A `{{` with no
    /// `}}` after it is just text.
    private static func placeholderRanges(in characters: [Character]) -> [ClosedRange<Int>] {
        var ranges: [ClosedRange<Int>] = []
        var i = 0
        while i + 1 < characters.count {
            guard characters[i] == "{", characters[i + 1] == "{" else {
                i += 1
                continue
            }
            var j = i + 2
            var close: Int?
            while j + 1 < characters.count {
                if characters[j] == "}", characters[j + 1] == "}" {
                    close = j
                    break
                }
                j += 1
            }
            if let close {
                ranges.append(i...(close + 1))
                i = close + 2
            } else {
                i += 1
            }
        }
        return ranges
    }

    /// The names inside the placeholders of a command, in order.
    static func placeholders(in command: String) -> [String] {
        let characters = Array(command)
        return placeholderRanges(in: characters).map { range in
            let first = range.lowerBound + 2, last = range.upperBound - 2
            return first <= last ? String(characters[first...last]) : ""
        }
    }
}
