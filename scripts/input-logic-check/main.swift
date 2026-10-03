// Checks the composer's pure logic — the command-line tokenizer, the syntax
// palette, fuzzy matching, the history index and shell-history parsing, and path
// completion, the suggestion state machine, and the assistant helpers (secret
// masking, failure signatures, reply parsing, command warnings) — on their own, so a mistake in any fails in seconds rather than
// after the app build, and so they can be proven off a Mac:
//
//   swiftc -o input-logic-check \
//     Sources/iTERMiNAL/Input/ColorMath.swift \
//     Sources/iTERMiNAL/Input/ShellTokenizer.swift \
//     Sources/iTERMiNAL/Input/SyntaxPalette.swift \
//     Sources/iTERMiNAL/Input/FuzzyMatcher.swift \
//     Sources/iTERMiNAL/Input/CommandHistoryIndex.swift \
//     Sources/iTERMiNAL/Input/PathCompleter.swift \
//     Sources/iTERMiNAL/Input/SuggestionState.swift \
//     Sources/iTERMiNAL/Chrome/ShellHistory.swift \
//     Sources/iTERMiNAL/AI/SecretRedactor.swift \
//     Sources/iTERMiNAL/AI/ContextSanitizer.swift \
//     Sources/iTERMiNAL/AI/FailureSignature.swift \
//     Sources/iTERMiNAL/AI/AssistReply.swift \
//     Sources/iTERMiNAL/AI/CommandRisk.swift \
//     Sources/iTERMiNAL/AI/AssistantDestination.swift \
//     Sources/iTERMiNAL/AI/ErrorHelp.swift \
//     scripts/input-logic-check/main.swift
//   ./input-logic-check
//
// Everything compiled here must import nothing but Foundation.
import Foundation

var failures = 0
var checks = 0

func check(_ condition: Bool, _ message: @autoclosure () -> String) {
    checks += 1
    if !condition {
        failures += 1
        print("FAIL  \(message())")
    }
}

// MARK: Tokenizer

/// Tokens as (kind, text) so a case reads like the command line it describes.
func describe(_ text: String) -> [String] {
    let units = Array(text.utf16)
    return ShellTokenizer.tokenize(text).map { token in
        "\(token.kind) \(String(decoding: units[token.range], as: UTF16.self))"
    }
}

func expect(_ text: String, _ expected: [String], file: String = #file, line: Int = #line) {
    let actual = describe(text)
    check(actual == expected, "\(text.debugDescription)\n      expected \(expected)\n      got      \(actual)")
}

expect("", [])
expect("ls -la", ["command ls", "flag -la"])
expect("git commit -m \"fix: it's\"", ["command git", "flag -m", "string \"fix: it's\""])
expect("echo $HOME/bin", ["command echo", "variable $HOME"])
expect("FOO=bar make test", ["variable FOO", "command make"])
expect("A=1 B=2 cmd", ["variable A", "variable B", "command cmd"])
expect("env FOO=1 node app.js", ["command env", "variable FOO", "command node"])
expect("cat a.txt | grep -i foo > out.txt 2>&1",
       ["command cat", "op |", "command grep", "flag -i", "op >", "op 2>&"])
expect("sudo rm -rf /tmp/x", ["command sudo", "command rm", "flag -rf"])
expect("echo 'unterminated", ["command echo", "string 'unterminated"])
expect("echo \"a $B c\"", ["command echo", "string \"a ", "variable $B", "string  c\""])
expect("echo \"unterminated $X", ["command echo", "string \"unterminated ", "variable $X"])
expect("echo \"a\\\"b\" c", ["command echo", "string \"a\\\"b\""])
expect("# just a comment", ["comment # just a comment"])
expect("ls # trailing", ["command ls", "comment # trailing"])
expect("a; b && c || d",
       ["command a", "op ;", "command b", "op &&", "command c", "op ||", "command d"])
expect("git status&&ls", ["command git", "op &&", "command ls"])
expect("echo hi\nls -l", ["command echo", "command ls", "flag -l"])
expect("ls \\\n -l", ["command ls", "flag -l"])
expect("$(date +%s)", ["op $(", "command date", "op )"])
expect("echo `date`", ["command echo", "op `", "command date", "op `"])
expect("cmd --name=value --x=\"y z\"", ["command cmd", "flag --name=", "flag --x=", "string \"y z\""])
expect("if true; then echo ok; fi",
       ["op if", "command true", "op ;", "op then", "command echo", "op ;", "op fi"])
expect("echo foo\\ bar", ["command echo"])
expect("ls ~/Library", ["command ls"])
expect("echo hi >out", ["command echo", "op >"])
expect("echo hi > out && ls", ["command echo", "op >", "op &&", "command ls"])
expect("cat <<EOF", ["command cat", "op <<"])
expect("cat <&3", ["command cat", "op <&"])
expect("cat <&3 && ls", ["command cat", "op <&", "op &&", "command ls"])
expect("exec 3<&0", ["command exec", "op 3<&"])
expect("cat <&- | wc", ["command cat", "op <&", "op |", "command wc"])
expect("diff <(ls a) <(ls b)",
       ["command diff", "op <(", "command ls", "op )", "op <(", "command ls", "op )"])
expect("echo ${HOME:-x}", ["command echo", "variable ${HOME:-x}"])
expect("echo $? $1 $$", ["command echo", "variable $?", "variable $1", "variable $$"])
expect("export PATH=$HOME/bin:$PATH", ["command export", "variable $HOME", "variable $PATH"])
expect("echo héllo wörld", ["command echo"])

// Ranges are UTF-16 offsets, the unit NSRange uses: an emoji is two of them.
do {
    let tokens = ShellTokenizer.tokenize("echo 😀 | ls")
    check(tokens.map(\.range) == [0..<4, 8..<9, 10..<12],
          "UTF-16 ranges after an emoji: \(tokens.map(\.range))")
}

// Whatever is typed, the tokens must be in order, inside the text, and apart.
do {
    let alphabet = Array(" \t\n\r\\'\"$`#|&;<>(){}-=a1é😀~*?!/.:%@,+[]^_").map(String.init)
    var seed: UInt64 = 0x9E3779B97F4A7C15
    func next() -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int(truncatingIfNeeded: seed >> 33)
    }
    var bad: String?
    for _ in 0..<20_000 {
        let length = next() % 41
        let text = (0..<length).map { _ in alphabet[next() % alphabet.count] }.joined()
        let count = text.utf16.count
        var previousEnd = 0
        for token in ShellTokenizer.tokenize(text) {
            if token.range.isEmpty || token.range.lowerBound < previousEnd || token.range.upperBound > count {
                bad = text
            }
            previousEnd = token.range.upperBound
        }
        if bad != nil { break }
    }
    check(bad == nil, "tokens out of order, empty, or out of bounds for \(String(describing: bad?.debugDescription))")
}

// MARK: Palette

// The opaque field the command is typed in: Theme.darkInputFieldHex and
// Theme.lightInputFieldHex. This file cannot import Theme, so it repeats them.
// Read them from the source and compare, so a change to the field cannot
// silently leave the tuning behind. Run from the repository root, as CI does.
let darkField: UInt32 = 0x1D1D21
let lightField: UInt32 = 0xF1F1F3

do {
    let path = "Sources/iTERMiNAL/Chrome/Theme.swift"
    if let source = try? String(contentsOfFile: path, encoding: .utf8) {
        func declared(_ name: String) -> UInt32? {
            guard let range = source.range(of: "\(name): UInt32 = 0x") else { return nil }
            let digits = source[range.upperBound...].prefix { $0.isHexDigit }
            return UInt32(digits, radix: 16)
        }
        check(declared("darkInputFieldHex") == darkField,
              "Theme.darkInputFieldHex is \(String(describing: declared("darkInputFieldHex"))); the fallbacks were tuned for \(ColorMath.hex(darkField))")
        check(declared("lightInputFieldHex") == lightField,
              "Theme.lightInputFieldHex is \(String(describing: declared("lightInputFieldHex"))); the fallbacks were tuned for \(ColorMath.hex(lightField))")
    } else {
        check(false, "could not read \(path): run this from the repository root")
    }
}

func all(_ c: SyntaxColors) -> [(String, UInt32)] {
    [("command", c.command), ("flag", c.flag), ("string", c.string),
     ("variable", c.variable), ("op", c.op), ("comment", c.comment)]
}

// The fallbacks are what a user sees whenever their terminal theme would not
// read, so they have to read well, not just barely.
for (name, colors, field) in [("dark", SyntaxPalette.darkFallback, darkField),
                              ("light", SyntaxPalette.lightFallback, lightField)] {
    for (kind, color) in all(colors) {
        let ratio = ColorMath.contrast(color, field)
        check(ratio >= 4.5,
              "\(name) fallback \(kind) \(ColorMath.hex(color)) is \(String(format: "%.2f", ratio)):1 on its field")
    }
}

// The floor is WCAG AA for normal text, because the input is 13 pt regular.
check(SyntaxPalette.minimumContrast == 4.5, "minimumContrast is \(SyntaxPalette.minimumContrast), not 4.5")

// A cross-section of the shipped terminal themes (ANSI slots 0–7 are enough:
// the palette reads 2–6), on both fields.
let themes: [(String, [UInt32], UInt32)] = [
    ("codex-dark",
     [0x2B2B2B, 0xE05561, 0x8CC265, 0xD18F52, 0x4AA5F0, 0xC162DE, 0x42B3C2, 0xD7D7D7], 0xECECEC),
    ("codex-light",
     [0x2E2E2E, 0xC91B00, 0x00A250, 0xA07400, 0x0072C3, 0xA018B8, 0x0087A8, 0x5D5D5D], 0x0D0D0D),
    ("solarized-dark",
     [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5], 0x839496),
    ("solarized-light",
     [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5], 0x657B83),
    ("dracula",
     [0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2], 0xF8F8F2),
    ("catppuccin-latte",
     [0x5C5F77, 0xD20F39, 0x40A02B, 0xDF8E1D, 0x1E66F5, 0xEA76CB, 0x179299, 0xACB0BE], 0x4C4F69),
    ("gruvbox-light",
     [0xFBF1C7, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0x7C6F64], 0x3C3836),
    ("nord",
     [0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0], 0xD8DEE9),
]
for (name, ansi, foreground) in themes {
    for (fieldName, field, dark) in [("dark field", darkField, true), ("light field", lightField, false)] {
        let colors = SyntaxPalette.colors(ansi: ansi, foreground: foreground, background: field, darkBackground: dark)
        for (kind, color) in all(colors) {
            let ratio = ColorMath.contrast(color, field)
            check(ratio >= 4.5,
                  "\(name) on the \(fieldName): \(kind) \(ColorMath.hex(color)) is \(String(format: "%.2f", ratio)):1")
        }
    }
}

// When the theme's own colours read, they are used as they are.
do {
    let (_, ansi, foreground) = themes[0]
    let colors = SyntaxPalette.colors(ansi: ansi, foreground: foreground, background: darkField, darkBackground: true)
    check(colors.command == ansi[2] && colors.flag == ansi[6] && colors.string == ansi[3]
          && colors.variable == ansi[5] && colors.op == ansi[4],
          "codex-dark on the dark field should keep its own colours, got \(all(colors).map { ColorMath.hex($0.1) })")
}

// A theme that would vanish on the field is replaced, not trusted.
do {
    let (_, ansi, foreground) = themes[4]   // Dracula's pastels
    let colors = SyntaxPalette.colors(ansi: ansi, foreground: foreground, background: lightField, darkBackground: false)
    check(colors.command == SyntaxPalette.lightFallback.command,
          "dracula green on the light field should fall back, got \(ColorMath.hex(colors.command))")
}

// A palette with too few slots falls back rather than crashing.
do {
    let colors = SyntaxPalette.colors(ansi: [], foreground: 0xFFFFFF, background: darkField, darkBackground: true)
    check(colors.command == SyntaxPalette.darkFallback.command, "empty palette should fall back")
}

// MARK: Fuzzy matching

func fuzzy(_ query: String, _ candidate: String) -> FuzzyMatch? {
    FuzzyMatcher.match(query, in: candidate)
}

check(fuzzy("gst", "git status")?.indices == [0, 4, 5],
      "gst in 'git status' should land on g, s, t: \(String(describing: fuzzy("gst", "git status")))")
check(fuzzy("GIT", "git status")?.indices == [0, 1, 2], "matching ignores case")
check(fuzzy("git st", "git status")?.indices == [0, 1, 2, 4, 5], "spaces in the query are ignored")
check(fuzzy("xyz", "git status") == nil, "no match when a character is missing")
check(fuzzy("tg", "git") == nil, "the characters must come in order")
check(fuzzy("", "anything")?.indices == [], "an empty query matches everything")
check(fuzzy("a", "") == nil, "nothing matches an empty candidate")
// "ab" can match at 0 and 5 or at 3 and 5's neighbour; the tight pair wins.
check(fuzzy("ab", "a xx ab")?.indices == [5, 6], "the tightest match is chosen, got \(String(describing: fuzzy("ab", "a xx ab")))")
// Offsets are in Characters: an emoji is one, however many UTF-16 units it takes.
check(fuzzy("ls", "😀 ls")?.indices == [2, 3], "indices count Characters, got \(String(describing: fuzzy("ls", "😀 ls")))")

func score(_ query: String, _ candidate: String) -> Int { fuzzy(query, candidate)?.score ?? Int.min }
check(score("git", "git status") > score("git", "digit"), "a prefix outranks the same letters inside a word")
check(score("st", "git status") > score("st", "fast tree"), "the start of a word outranks the middle of one")
check(score("ls", "ls") > score("ls", "ls -la"), "an exact match outranks a longer one")
check(score("gs", "git status") > score("gs", "go to far away sleep"), "a closer match outranks a scattered one")
check(score("dep", "dependabot") > score("dep", "npm run deploy"),
      "the start of the command outranks the start of a later word")

// The match must be the best there is. Check it against every way of placing the
// query in the candidate, over many small random cases — not just the cases a
// person thought to write down, which a first-fit search can pass.
do {
    func bestPossible(_ query: String, _ candidate: String) -> Int? {
        let original = Array(candidate)
        let folded = FuzzyMatcher.folded(candidate)
        let needle = FuzzyMatcher.needle(query)
        if needle.isEmpty { return 0 }
        var best: Int?
        func place(_ slot: Int, from start: Int, chosen: [Int]) {
            if slot == needle.count {
                let value = FuzzyMatcher.score(of: chosen, candidateLength: original.count, original: original)
                if best == nil || value > best! { best = value }
                return
            }
            var j = start
            while j < folded.count {
                if folded[j] == needle[slot] { place(slot + 1, from: j + 1, chosen: chosen + [j]) }
                j += 1
            }
        }
        place(0, from: 0, chosen: [])
        return best
    }

    // The cases that a leftmost-end-then-tighten search gets wrong: an early
    // loose match that is not the best one.
    for (query, candidate) in [("ab", "a ----- b ab"), ("bc", "xb ----- c bc"), ("ab", "ab ab"), ("st", "git status status")] {
        let match = fuzzy(query, candidate)
        check(match?.score == bestPossible(query, candidate),
              "\(query) in \(candidate.debugDescription) should score the best possible \(String(describing: bestPossible(query, candidate))), got \(String(describing: match))")
    }
    check(fuzzy("bc", "xb ----- c bc")?.indices == [11, 12], "a tight later match beats a loose earlier one: \(String(describing: fuzzy("bc", "xb ----- c bc")))")

    var seed: UInt64 = 0xFEEDFACE
    func next() -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int(truncatingIfNeeded: seed >> 33)
    }
    let letters = ["a", "b", "A", "B", " ", "-", "/", "é"]
    var wrong: String?
    for _ in 0..<4_000 {
        let candidate = (0..<(next() % 13)).map { _ in letters[next() % letters.count] }.joined()
        let query = (0..<(1 + next() % 4)).map { _ in ["a", "b", " ", "é"][next() % 4] }.joined()
        let match = fuzzy(query, candidate)
        let best = bestPossible(query, candidate)
        let original = Array(candidate)
        let needle = FuzzyMatcher.needle(query)
        var problem: String?
        if match?.score != best {
            problem = "score \(String(describing: match?.score)), best possible \(String(describing: best))"
        } else if let match {
            if match.indices.count != needle.count || zip(match.indices, match.indices.dropFirst()).contains(where: { $0 >= $1 })
                || match.indices.contains(where: { $0 < 0 || $0 >= original.count })
                || zip(match.indices, needle).contains(where: { FuzzyMatcher.fold(original[$0]) != $1 }) {
                problem = "malformed indices \(match.indices)"
            } else if FuzzyMatcher.score(of: match.indices, candidateLength: original.count, original: original) != match.score {
                problem = "indices \(match.indices) are not worth the score \(match.score)"
            }
        }
        if let problem { wrong = "query \(query.debugDescription) in \(candidate.debugDescription): \(problem)"; break }
    }
    check(wrong == nil, "fuzzy match is not optimal or well-formed: \(wrong ?? "")")
}

// MARK: History index

do {
    // Composer history is oldest first; the shell's is newest first.
    let index = CommandHistoryIndex(
        composer: ["git status", "ls -la", "make test"],
        shell: ["git commit -m x", "ls -la", "cd ~/code", "git status"]
    )
    check(index.entries.map(\.command) == ["make test", "ls -la", "git status", "git commit -m x", "cd ~/code"],
          "merged newest first with duplicates kept once: \(index.entries.map(\.command))")

    check(index.completion(for: "git s") == "tatus", "ghost completes from the newest match: \(String(describing: index.completion(for: "git s")))")
    check(index.completion(for: "git c") == "ommit -m x", "ghost for a different prefix")
    check(index.completion(for: "git status") == nil, "nothing to add when the text is the whole command")
    check(index.completion(for: "") == nil, "no ghost for empty text")
    check(index.completion(for: "   ") == nil, "no ghost for blanks")
    check(index.completion(for: "nope") == nil, "no ghost when nothing starts with it")
    check(index.completion(for: "GIT") == nil, "ghost is case-sensitive: a different case is not what was typed")
    check(index.completion(for: "git s\nx") == nil, "no ghost across lines")
    check(index.completion(for: "ls ") == "-la", "ghost continues after a trailing space")

    // Two commands share a prefix: the ghost follows the newest.
    let shared = CommandHistoryIndex(composer: ["git status", "git stash"], shell: ["git stage ."])
    check(shared.completion(for: "git sta") == "sh", "ghost follows the newest of several matches: \(String(describing: shared.completion(for: "git sta")))")
    check(shared.completion(for: "git stat") == "us", "and a longer prefix narrows to the one that still matches")
    check(shared.completion(for: "git stag") == "e .", "the shell's history is searched too")

    let multi = CommandHistoryIndex(composer: ["echo a\necho b", "echo c"], shell: [])
    check(multi.entries.map(\.command) == ["echo c"], "multi-line commands are not indexed")

    let hits = index.search("gs", limit: 5).map(\.command)
    check(hits.first == "git status", "search ranks the closest first: \(hits)")
    check(index.search("zzz", limit: 5).isEmpty, "search with no match is empty")
    check(index.search("", limit: 2).map(\.command) == ["make test", "ls -la"], "an empty query lists the newest")
    check(index.search("git", limit: 1).count == 1, "search honours its limit")
    check(index.search("git st", limit: 5).first?.indices == [0, 1, 2, 4, 5], "hits carry their matched offsets")

    // Equal scores come back newest first.
    let tie = CommandHistoryIndex(composer: ["echo one", "echo two"], shell: [])
    check(tie.search("echo", limit: 5).map(\.command) == ["echo two", "echo one"], "ties resolve to the newest")

    // The limit applies to what is indexed.
    let capped = CommandHistoryIndex(composer: (0..<50).map { "cmd \($0)" }, shell: [], limit: 10)
    check(capped.entries.count == 10 && capped.entries.first?.command == "cmd 49", "the index is capped at its limit, newest kept")
}

// MARK: Shell history parsing

do {
    let zsh = ": 1690000000:0;ls -la\n: 1690000001:0;git status\n: 1690000002:0;ls -la\n"
    check(ShellHistory.entries(in: zsh, maxLength: 400) == ["ls -la", "git status", "ls -la"],
          "zsh extended history loses its timestamp prefix: \(ShellHistory.entries(in: zsh, maxLength: 400))")
    check(ShellHistory.newestFirst(in: zsh, maxLength: 400, limit: 10) == ["ls -la", "git status"],
          "newest first, each command once, at its newest position")

    let bash = "#1690000000\nls -la\n#1690000001\ngit status\n"
    check(ShellHistory.newestFirst(in: bash, maxLength: 400, limit: 10) == ["git status", "ls -la"],
          "bash timestamp lines are skipped: \(ShellHistory.newestFirst(in: bash, maxLength: 400, limit: 10))")

    // zsh writes a command spanning lines as backslash-newline.
    let spanning = ": 1:0;echo a\\\nb\n: 2:0;ls\n"
    check(ShellHistory.entries(in: spanning, maxLength: 400) == ["ls"],
          "the lines of a multi-line command are not commands: \(ShellHistory.entries(in: spanning, maxLength: 400))")

    let long = String(repeating: "x", count: 121)
    check(ShellHistory.entries(in: long + "\n", maxLength: 120).isEmpty, "the landing screen's length limit still applies")
    check(ShellHistory.entries(in: long + "\n", maxLength: 400) == [long], "search allows longer commands")
    check(ShellHistory.newestFirst(in: "a\nb\nc\n", maxLength: 400, limit: 2) == ["c", "b"], "the limit keeps the newest")
    check(ShellHistory.entries(in: "\n\n  \n", maxLength: 400).isEmpty, "blank lines are nothing")

    // Reading a file: only its tail, and never a fragment of a line.
    let directory = NSTemporaryDirectory() + "history-check-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let file = URL(fileURLWithPath: directory + "/history")
    // alpha\n bravo\n charlie\n — 6 + 6 + 8 = 20 bytes.
    try? "alpha\nbravo\ncharlie\n".write(to: file, atomically: true, encoding: .utf8)
    check(ShellHistory.search(in: [file], tailByteCount: 1_000, limit: 10) == ["charlie", "bravo", "alpha"],
          "a small file is read whole")
    // The tail starts exactly on "charlie": nothing is lost.
    check(ShellHistory.search(in: [file], tailByteCount: 8, limit: 10) == ["charlie"],
          "a tail that begins on a line keeps that line: \(ShellHistory.search(in: [file], tailByteCount: 8, limit: 10))")
    // The tail starts inside "bravo": that fragment is dropped, whole lines stay.
    check(ShellHistory.search(in: [file], tailByteCount: 12, limit: 10) == ["charlie"],
          "a tail that begins mid-line drops the fragment: \(ShellHistory.search(in: [file], tailByteCount: 12, limit: 10))")
    check(ShellHistory.search(in: [file], tailByteCount: 14, limit: 10) == ["charlie", "bravo"],
          "a tail that reaches back to a line start keeps it: \(ShellHistory.search(in: [file], tailByteCount: 14, limit: 10))")
    check(ShellHistory.search(in: [file], tailByteCount: 3, limit: 10).isEmpty, "a tail inside one line is no commands")
    // A cut can land inside a command that spans lines. What is left of it is
    // not a command, whichever of its lines the cut starts on.
    func tail(_ content: String, _ bytes: Int, name: String) -> [String] {
        let url = URL(fileURLWithPath: directory + "/" + name)
        try? content.write(to: url, atomically: true, encoding: .utf8)
        return ShellHistory.search(in: [url], tailByteCount: bytes, limit: 10)
    }
    // ": 1:0;echo first\" newline "continued" newline "ls" newline — 31 bytes.
    let spanning2 = ": 1:0;echo first\\\ncontinued\nls\n"
    check(tail(spanning2, 13, name: "span-a") == ["ls"],
          "a tail that starts on the last line of a multi-line command skips it: \(tail(spanning2, 13, name: "span-a"))")
    check(tail(spanning2, 31, name: "span-b") == ["ls"], "and the whole file reads the same way: \(tail(spanning2, 31, name: "span-b"))")
    check(tail(spanning2, 12, name: "span-c") == ["ls"], "a tail starting inside that line gives the same: \(tail(spanning2, 12, name: "span-c"))")
    // Three lines: ": 1:0;echo a\" / "b\" / "c" / "ls" — 22 bytes. Cut on each.
    let spanning3 = ": 1:0;echo a\\\nb\\\nc\nls\n"
    for bytes in [3, 4, 5, 6, 7, 8, 9, 10, 22] {
        let result = tail(spanning3, bytes, name: "span-3-\(bytes)")
        check(result == ["ls"], "a cut \(bytes) bytes from the end of a three-line command leaves only ls: \(result)")
    }
    // A command right before the multi-line one is still found when the cut is clean.
    let before = "pwd\n" + spanning2
    check(tail(before, before.utf8.count, name: "span-d") == ["ls", "pwd"], "commands either side of a multi-line one are kept")
    check(tail(before, 31, name: "span-e") == ["ls"], "cutting exactly at the multi-line command: \(tail(before, 31, name: "span-e"))")
    check(ShellHistory.search(in: [URL(fileURLWithPath: directory + "/missing")], tailByteCount: 100, limit: 10).isEmpty,
          "a missing file yields nothing")
    let second = URL(fileURLWithPath: directory + "/second")
    try? "later\n".write(to: second, atomically: true, encoding: .utf8)
    check(ShellHistory.search(in: [URL(fileURLWithPath: directory + "/missing"), second], tailByteCount: 100, limit: 10) == ["later"],
          "the first readable file wins")

    let candidates = ShellHistory.candidateFiles(home: URL(fileURLWithPath: "/h"), histfile: "~/custom_hist").map(\.path)
    check(candidates.count == 3 && candidates[1] == "/h/.zsh_history" && candidates[2] == "/h/.bash_history"
          && candidates[0].hasSuffix("custom_hist") && !candidates[0].hasPrefix("~"),
          "HISTFILE comes first, then zsh, then bash: \(candidates)")
    check(ShellHistory.candidateFiles(home: URL(fileURLWithPath: "/h"), histfile: "").count == 2, "an empty HISTFILE is ignored")
}

// MARK: Path completion

do {
    let root = NSTemporaryDirectory() + "path-check-\(UUID().uuidString)"
    let fm = FileManager.default
    func make(_ path: String, directory: Bool = false) {
        let full = root + "/" + path
        if directory {
            try? fm.createDirectory(atPath: full, withIntermediateDirectories: true)
        } else {
            try? fm.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            _ = fm.createFile(atPath: full, contents: Data())
        }
    }
    defer { try? fm.removeItem(atPath: root) }
    for directory in ["Documents", "Downloads", "my folder", "reports", "home/user"] { make(directory, directory: true) }
    for file in ["Documents/notes.txt", ".hidden", "my file.txt", "readme.md", "README.txt", "report-2024.txt",
                 "report-2025.txt", "a$b&c", "Documents/Résumé.pdf", "it's.txt", "home/user/.profile", "home/user/todo.txt"] {
        make(file)
    }
    try? fm.createSymbolicLink(atPath: root + "/link-to-docs", withDestinationPath: root + "/Documents")

    for number in 1...100 { make("big/fooa" + String(format: "%03d", number)) }
    make("big/foob001")
    for number in 1...101 { make("many/longprefix-" + String(format: "%03d", number)) }
    func complete(_ text: String, caret: Int? = nil, wd: String? = root, home: String = root + "/home/user") -> PathCompletion? {
        PathCompleter.complete(text: text, caret: caret ?? text.utf16.count, workingDirectory: wd, home: home)
    }
    func names(_ completion: PathCompletion?) -> [String] { completion?.candidates.map(\.name) ?? [] }

    // Plain names.
    check(names(complete("ls Do")) == ["Documents", "Downloads"], "two matches: \(names(complete("ls Do")))")
    check(complete("ls Do")?.sharedInsertion == nil, "no shared extension when they diverge here")
    check(complete("ls Do")?.range == 3..<5, "range covers the word: \(String(describing: complete("ls Do")?.range))")
    check(complete("ls Doc")?.candidates == [.init(name: "Documents", isDirectory: true, insertion: "Documents/")],
          "a single directory gets its slash: \(String(describing: complete("ls Doc")))")
    check(complete("ls Documents/n")?.candidates.first?.insertion == "Documents/notes.txt", "completes inside a directory")
    check(complete("ls Documents/n")?.range == 3..<14, "range covers the directory part too")
    check(complete("ls readme")?.candidates.first?.isDirectory == false, "a file is not a directory")

    // More matches than are kept: what they share comes from all of them.
    let big = complete("ls big/foo")
    check(big?.matchCount == 101 && big?.candidates.count == PathCompleter.maxCandidates,
          "101 matches keep \(PathCompleter.maxCandidates) and say how many there were: \(String(describing: big?.matchCount)), \(String(describing: big?.candidates.count))")
    check(big?.sharedInsertion == nil,
          "a name past the cut that diverges keeps the shared prefix from reaching 'fooa': \(String(describing: big?.sharedInsertion))")
    check(complete("ls big/fooa")?.sharedInsertion == nil, "the hundred that agree on 'fooa' have nothing more in common: \(String(describing: complete("ls big/fooa")?.sharedInsertion))")
    let many = complete("ls many/lo")
    check(many?.matchCount == 101 && many?.sharedInsertion == "many/longprefix-",
          "what all 101 share is filled in: \(String(describing: many?.sharedInsertion)), \(String(describing: many?.matchCount))")
    check(complete("ls Do")?.matchCount == 2 && complete("ls Doc")?.matchCount == 1, "match counts for small directories")

    // The empty word lists the directory, without dot files.
    let all = names(complete("ls "))
    check(all.contains("Documents") && all.contains("my file.txt") && !all.contains(".hidden"), "hidden files stay hidden: \(all)")
    check(all == all.sorted { $0.lowercased() != $1.lowercased() ? $0.lowercased() < $1.lowercased() : $0 < $1 },
          "listed in case-insensitive order: \(all)")
    check(names(complete("ls .h")) == [".hidden"], "a leading dot asks for hidden files")
    check(complete("ls ")?.range == 3..<3, "an empty word has an empty range at the caret")

    // Shared extension.
    check(complete("ls rep")?.sharedInsertion == "report", "shared prefix of report-2024, report-2025 and reports")
    check(complete("ls report-")?.sharedInsertion == "report-202", "the shared prefix goes as far as it can")
    check(complete("ls report-2024")?.candidates.count == 1 && complete("ls report-2024")?.sharedInsertion == nil,
          "a single match has no shared insertion")

    // Case: literal first, then forgiving.
    check(names(complete("ls RE")) == ["README.txt"], "an exact-case match wins: \(names(complete("ls RE")))")
    check(names(complete("ls re")) == ["readme.md", "report-2024.txt", "report-2025.txt", "reports"],
          "exact case again, and README.txt is not offered: \(names(complete("ls re")))")
    check(names(complete("ls doc")) == ["Documents"], "with no exact match, another case counts: \(names(complete("ls doc")))")

    // Escaping.
    check(complete("ls my\\ fi")?.candidates.first?.insertion == "my\\ file.txt",
          "a space is escaped on the way back: \(String(describing: complete("ls my\\ fi")))")
    check(complete("ls my\\ fi")?.range == 3..<9, "the range covers the escaped word")
    check(names(complete("ls my\\ f")) == ["my file.txt", "my folder"], "an escaped space completes: \(names(complete("ls my\\ f")))")
    check(complete("ls my\\ f")?.sharedInsertion == nil, "my file / my folder share nothing past what is typed")
    check(complete("ls a")?.candidates.first?.insertion == "a\\$b\\&c", "shell characters are escaped: \(String(describing: complete("ls a")?.candidates.first?.insertion))")
    check(complete("ls it")?.candidates.first?.insertion == "it\\'s.txt", "a quote is escaped")
    check(complete("ls my\\ folder/") == nil, "an empty directory completes to nothing")

    // Quotes.
    check(complete("ls \"my fi")?.candidates.first?.insertion == "\"my file.txt\"", "inside double quotes, nothing is escaped and the quote closes: \(String(describing: complete("ls \"my fi")))")
    check(complete("ls \"my fo")?.candidates.first?.insertion == "\"my folder/", "a directory leaves its quote open to keep typing")
    check(complete("ls 'my fi")?.candidates.first?.insertion == "'my file.txt'", "single quotes work the same")
    check(complete("ls \"a")?.candidates.first?.insertion == "\"a\\$b&c\"", "inside double quotes $ is escaped but & is not: \(String(describing: complete("ls \"a")?.candidates.first?.insertion))")
    check(complete("ls 'it") == nil, "a name with a single quote cannot go in single quotes")
    check(complete("ls \"Doc")?.range == 3..<7, "the range includes the opening quote")
    check(complete("ls a\"b") == nil, "a quote in the middle of a word is not guessed at")
    check(complete("ls \"my file.txt\" Do")?.range == 17..<19, "a closed quoted word before it does not matter")

    // What is not a path.
    check(complete("gi") == nil, "the command position completes nothing")
    check(complete("./Doc")?.candidates.first?.insertion == "./Documents/", "a path at the command position does complete: \(String(describing: complete("./Doc")))")
    check(complete("cat a | gr") == nil, "the command after a pipe is a command")
    check(complete("ls && gi") == nil, "and after &&")
    check(complete("cat a > Do")?.range == 8..<10, "a redirect target is a path")
    check(complete("ls -l") == nil, "a flag is not a path")
    check(complete("echo $HO") == nil, "a variable is not a path")
    check(complete("echo ~bob/x") == nil, "another user's home is not guessed")

    // Home and absolute paths.
    check(complete("cd ~")?.candidates == [.init(name: "~", isDirectory: true, insertion: "~/")], "a bare ~ becomes ~/")
    check(names(complete("ls ~/")) == ["todo.txt"], "home is the home argument, not the working directory: \(names(complete("ls ~/")))")
    check(complete("ls ~/t")?.candidates.first?.insertion == "~/todo.txt", "~/ is kept as typed: \(String(describing: complete("ls ~/t")))")
    check(complete("ls ~/.p")?.candidates.first?.insertion == "~/.profile", "hidden files under home")
    check(complete("ls \(root)/Doc", wd: nil)?.candidates.first?.insertion == "\(root)/Documents/", "an absolute path needs no working directory")
    check(complete("ls Doc", wd: nil) == nil, "a relative path with no working directory (a remote session) completes to nothing")
    check(complete("ls ../")?.range == 3..<6 && complete("ls ../")?.candidates.allSatisfy { $0.insertion.hasPrefix("../") } == true,
          "a relative .. path completes against the parent: \(String(describing: complete("ls ../")?.range))")
    check(complete("ls Doc", wd: root + "/nonexistent") == nil, "an unreadable directory completes to nothing")
    check(complete("ls link-to")?.candidates.first?.isDirectory == true, "a symlink to a directory is a directory")
    check(complete("ls link-to")?.candidates.first?.insertion == "link-to-docs/", "and gets a slash")
    check(complete("ls nothing-like-this") == nil, "no match is nil")

    // Caret in the middle of a line, and in a multi-byte one.
    check(complete("ls Doc foo", caret: 6)?.range == 3..<6, "completes the word at the caret, not the end")
    check(complete("ls Doc foo", caret: 6)?.candidates.first?.insertion == "Documents/", "and ignores what follows")
    check(complete("echo 😀 Do")?.range == 8..<10, "ranges are UTF-16 offsets: \(String(describing: complete("echo 😀 Do")?.range))")
    check(complete("ls Do", caret: 99)?.range == 3..<5, "a caret past the end is clamped")
    check(complete("ls Do", caret: -4) == nil || complete("ls Do", caret: -4)?.range.lowerBound == 0, "a negative caret is clamped")
    check(complete("ls Doc\nls Do", caret: 12)?.range == 10..<12, "a newline starts a new command")
    check(complete("") == nil, "empty text completes nothing")
    check(complete("ls | ") == nil, "an empty word after a pipe is a command position")
    check(complete("ls && ") == nil, "and after &&")
    check(complete("echo $(") == nil, "and after $(")
    check(complete("diff <(") == nil, "and after process substitution")
    check(complete("if true; then ") == nil, "and after then")
    check(names(complete("cat < ")).contains("Documents"), "an empty word after a redirect is a path: \(names(complete("cat < ")))")
    check(names(complete("cat a > ")).contains("Documents"), "after > too")
    check(names(complete("ls -l ")).contains("Documents"), "an empty word after a flag is a path")
    check(names(complete("sudo ls ")).contains("Documents"), "an empty word after a command with a prefix is a path")
    check(complete("ls Résu")?.candidates.first?.name == nil, "no crash on accents; directory has none here")
    check(complete("ls Documents/Rés")?.candidates.first?.name == "Résumé.pdf", "accented names complete")

    // Whatever the text and caret, a completion is well-formed.
    var seed: UInt64 = 0xC0FFEE
    func next() -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int(truncatingIfNeeded: seed >> 33)
    }
    let alphabet = Array(" \\'\"$|&;<>()~/.-DoRe*é😀\n").map(String.init)
    var broken: String?
    for _ in 0..<5_000 {
        let text = (0..<(next() % 24)).map { _ in alphabet[next() % alphabet.count] }.joined()
        let count = text.utf16.count
        let caret = next() % (count + 1)
        if let completion = complete(text, caret: caret) {
            if completion.range.lowerBound < 0 || completion.range.upperBound != caret
                || completion.range.lowerBound > completion.range.upperBound || completion.candidates.isEmpty {
                broken = "\(text.debugDescription) caret \(caret): \(completion)"
                break
            }
        }
    }
    check(broken == nil, "malformed completion for \(broken ?? "")")
}

// MARK: Suggestion state

do {
    let root = NSTemporaryDirectory() + "state-check-\(UUID().uuidString)"
    let fm = FileManager.default
    try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: root) }
    func touch(_ name: String, directory: Bool = false) {
        if directory {
            try? fm.createDirectory(atPath: root + "/" + name, withIntermediateDirectories: true)
        } else {
            _ = fm.createFile(atPath: root + "/" + name, contents: Data())
        }
    }
    for name in ["Documents", "Downloads"] { touch(name, directory: true) }
    touch("notes.txt")
    for number in 1...12 { touch(String(format: "f%02d", number)) }
    touch("solo-file.txt")
    touch("pair-a.txt")
    touch("pair-b.txt")
    try? fm.createDirectory(atPath: root + "/big", withIntermediateDirectories: true)
    for number in 1...100 { _ = fm.createFile(atPath: root + "/big/fooa" + String(format: "%03d", number), contents: Data()) }
    _ = fm.createFile(atPath: root + "/big/foob001", contents: Data())

    func state(composer: [String] = ["git status", "git stash", "ls -la", "make test", "npm run build", "echo hi"],
               shell: [String] = []) -> SuggestionState {
        var s = SuggestionState()
        s.setIndex(CommandHistoryIndex(composer: composer, shell: shell))
        return s
    }
    func press(_ s: inout SuggestionState, _ key: SuggestionState.Key, text: String = "", caret: Int? = nil,
               directory: String? = root) -> SuggestionState.Outcome {
        s.handle(key, text: text, caret: caret ?? text.utf16.count, directory: directory)
    }

    // The ghost.
    do {
        var s = state()
        check(s.ghost(for: "git sta") == "sh", "ghost is the newest completion: \(s.ghost(for: "git sta"))")
        check(s.ghost(for: "zzz") == "", "no ghost when nothing matches")
        var o = press(&s, .dismiss, text: "git sta")
        check(o.consumed && o.replacement == nil, "dismissing a ghost is handled and puts nothing in the field")
        check(s.ghost(for: "git sta") == "", "a dismissed ghost stays gone for that text")
        check(s.ghost(for: "git stat") == "us", "and not for other text")
        s.refresh(text: "git stat", caret: 8, directory: root)
        check(s.dismissedGhost == nil, "changing the text clears the dismissal")
        check(s.ghost(for: "git sta") == "sh", "so the ghost for the earlier text is back")
        o = press(&s, .historySearch)
        check(s.ghost(for: "git sta") == "", "no ghost while a list is open")
        _ = press(&s, .dismiss)
        check(s.ghost(for: "git sta") == "sh", "and it returns when the list closes")
    }

    // History search.
    do {
        var s = state()
        var o = press(&s, .up)
        check(!o.consumed && s.mode == nil, "up is left to the text view while nothing is open")
        o = press(&s, .down)
        check(!o.consumed, "so is down")
        o = press(&s, .accept)
        check(!o.consumed, "and Return")

        o = press(&s, .historySearch)
        check(o.consumed && o.replacement == nil && s.mode == .history, "⌃R opens history")
        check(s.rows.map(\.text) == ["echo hi", "npm run build", "make test", "ls -la", "git stash", "git status"],
              "an empty query lists everything, newest first: \(s.rows.map(\.text))")
        check(s.selected == 0, "the newest is selected")
        _ = press(&s, .down)
        _ = press(&s, .down)
        check(s.selected == 2, "down moves the selection")
        _ = press(&s, .up)
        check(s.selected == 1, "up moves it back")
        for _ in 0..<20 { _ = press(&s, .up) }
        check(s.selected == 0, "up stops at the first row")
        for _ in 0..<20 { _ = press(&s, .down) }
        check(s.selected == 5, "down stops at the last row: \(s.selected)")
        _ = press(&s, .historySearch)
        check(s.selected == 5, "⌃R again at the end stays put")

        s.refresh(text: "git", caret: 3, directory: root)
        check(s.rows.map(\.text) == ["git stash", "git status"], "typing narrows the list: \(s.rows.map(\.text))")
        check(s.selected == 1, "the selection is kept where it still exists")
        s.refresh(text: "git status", caret: 10, directory: root)
        check(s.rows.map(\.text) == ["git status"] && s.selected == 0, "and clamped when the list shrinks past it")

        o = press(&s, .accept, text: "git status")
        check(o.consumed && o.replacement == .init(range: nil, text: "git status"), "Return inserts the chosen command over the whole text")
        check(s.mode == nil && s.rows.isEmpty, "and closes the list")
    }
    do {
        var s = state()
        _ = press(&s, .historySearch, text: "git")
        check(s.rows.map(\.text) == ["git stash", "git status"], "⌃R filters by what is already typed")
        check(s.rows.first?.emphasized == [0, 1, 2], "matched characters are marked: \(String(describing: s.rows.first?.emphasized))")
        _ = press(&s, .historySearch, text: "git")
        check(s.selected == 1, "⌃R again moves to the next, older, match")
        let o = press(&s, .dismiss, text: "git")
        check(o.consumed && s.mode == nil, "esc closes it")
        check(o.replacement == nil, "and puts nothing in the field")
    }
    do {
        var s = state()
        _ = press(&s, .historySearch, text: "qqq")
        check(s.mode == .history && s.rows.isEmpty, "a query with no match leaves an open, empty list")
        let o = press(&s, .accept, text: "qqq")
        check(o.consumed && o.replacement == nil && s.mode == nil, "Return on an empty list just closes it, and sends nothing")
        _ = press(&s, .historySearch, text: "qqq")
        s.refresh(text: "git", caret: 3, directory: root)
        check(s.rows.count == 2, "an empty list recovers when the query matches again")
        s.setIndex(CommandHistoryIndex(composer: ["git new"], shell: []))
        check(s.rows.map(\.text) == ["git new"], "a list refreshes when the history behind it changes: \(s.rows.map(\.text))")
    }
    do {
        var s = state(composer: (0..<30).map { "cmd \($0)" })
        _ = press(&s, .historySearch)
        check(s.rows.count == SuggestionState.maxRows && s.rows.first?.text == "cmd 29", "the list shows at most \(SuggestionState.maxRows) rows")
        check(s.rows.map(\.id) == Array(0..<SuggestionState.maxRows), "rows are numbered from 0")
    }

    // Tab: files.
    do {
        var s = state()
        var o = press(&s, .tab, text: "ls Doc")
        check(o.consumed && o.replacement == .init(range: NSRange(location: 3, length: 3), text: "Documents/"),
              "a single match is filled in: \(String(describing: o.replacement))")
        check(s.mode == nil, "without opening a list")

        o = press(&s, .tab, text: "ls pair-")
        check(o.replacement == nil && s.mode == .path && s.rows.map(\.text) == ["pair-a.txt", "pair-b.txt"],
              "two matches open a list: \(s.rows.map(\.text))")

        s = state()
        o = press(&s, .tab, text: "ls so")
        check(o.replacement?.text == "solo-file.txt", "one file is filled in whole")

        s = state()
        o = press(&s, .tab, text: "ls p")
        check(o.replacement == .init(range: NSRange(location: 3, length: 1), text: "pair-"),
              "what the candidates share is filled in first: \(String(describing: o.replacement))")
        check(s.mode == nil, "and the list waits for the next Tab")

        s = state()
        o = press(&s, .tab, text: "ls D")
        check(o.replacement == .init(range: NSRange(location: 3, length: 1), text: "Do") && s.mode == nil,
              "what Documents and Downloads share is filled in first: \(String(describing: o.replacement))")

        s = state()
        o = press(&s, .tab, text: "ls Do")
        check(s.mode == .path && s.rows.map(\.text) == ["Documents/", "Downloads/"] && s.rows.allSatisfy(\.isDirectory),
              "directories are listed with their slash: \(s.rows.map(\.text))")
        _ = press(&s, .down)
        o = press(&s, .accept, text: "ls Do")
        check(o.replacement == .init(range: NSRange(location: 3, length: 2), text: "Downloads/"),
              "choosing replaces the word, not the line: \(String(describing: o.replacement))")
        check(s.mode == nil, "and closes the list")

        s = state()
        _ = press(&s, .tab, text: "ls Do")
        o = press(&s, .tab, text: "ls Do")
        check(o.replacement == .init(range: NSRange(location: 3, length: 2), text: "Documents/"), "Tab in the list chooses the selected row")

        s = state()
        o = press(&s, .tab, text: "ls D", directory: nil)
        check(o.consumed && o.replacement == nil && s.mode == nil, "no files are offered for a remote session, but Tab is still not typed")
        o = press(&s, .tab, text: "ls nothing-here")
        check(o.consumed && o.replacement == nil && s.mode == nil, "nothing to complete: handled, nothing changes")
        o = press(&s, .tab, text: "gi")
        check(o.consumed && o.replacement == nil, "a command name is not completed")

        s = state()
        _ = press(&s, .tab, text: "ls f")
        check(s.mode == .path && s.rows.count == SuggestionState.maxRows && s.hiddenCount == 4,
              "twelve files show eight and say there are four more: \(s.rows.count) shown, \(s.hiddenCount) hidden")

        s = state()
        o = press(&s, .tab, text: "ls big/foo")
        check(s.mode == .path && s.rows.count == SuggestionState.maxRows && s.hiddenCount == 101 - SuggestionState.maxRows,
              "the count of what is not shown is of all the matches, not of the ones kept: \(s.hiddenCount)")
        check(o.replacement == nil, "and nothing is filled in when the matches past the cap diverge")

        // The list follows the word.
        s = state()
        _ = press(&s, .tab, text: "ls Do")
        s.refresh(text: "ls Dow", caret: 6, directory: root)
        check(s.mode == .path && s.rows.map(\.text) == ["Downloads/"], "typing narrows the file list: \(s.rows.map(\.text))")
        s.refresh(text: "ls Dowx", caret: 7, directory: root)
        check(s.mode == nil, "and it closes when nothing matches")
        _ = press(&s, .tab, text: "ls Do")
        s.refresh(text: "ls Do", caret: 0, directory: root)
        check(s.mode == nil, "moving the caret out of the word closes it")
        _ = press(&s, .tab, text: "ls Do")
        s.refresh(text: "ls Do", caret: 5, directory: nil)
        check(s.mode == nil, "so does the destination turning out to be remote")

        // A history list is not turned into a file list by Tab.
        s = state()
        _ = press(&s, .historySearch, text: "ls")
        o = press(&s, .tab, text: "ls")
        check(o.replacement == .init(range: nil, text: "ls -la"), "Tab in the history list chooses from it, not from the files: \(String(describing: o.replacement))")
        check(s.mode == nil, "and closes it")
    }
    do {
        // ⌃R from a file list switches to history.
        var s = state()
        _ = press(&s, .tab, text: "ls Do")
        _ = press(&s, .historySearch, text: "ls Do")
        check(s.mode == .history, "⌃R replaces a file list with history")
    }
    do {
        // choose() is what a click does.
        var s = state()
        _ = press(&s, .historySearch)
        let row = s.rows[2]
        let replacement = s.choose(row)
        check(replacement == .init(range: nil, text: "make test") && s.mode == nil, "clicking a row chooses it: \(String(describing: replacement))")
        check(s.choose(nil) == nil, "choosing nothing is nothing")
    }
}

// MARK: Secret masking

do {
    check(SecretRedactor.isOperational, "every redaction pattern compiled")
    func masked(_ text: String) -> String { SecretRedactor.redact(text) }
    func same(_ text: String, _ why: String) {
        check(masked(text) == text, "\(why): \(text.debugDescription) became \(masked(text).debugDescription)")
    }
    func gone(_ text: String, secret: String, _ why: String) {
        let result = masked(text)
        check(!result.contains(secret) && result.contains("[redacted"), "\(why): \(text.debugDescription) became \(result.debugDescription)")
    }

    // Tokens with a shape of their own.
    gone("key AKIAIOSFODNN7EXAMPLE here", secret: "AKIAIOSFODNN7EXAMPLE", "AWS access key id")
    same("AKIA1234 is too short to be a key", "a short AKIA string")
    gone("token ghp_" + String(repeating: "a1B2", count: 9), secret: "ghp_a1B2", "GitHub token")
    same("ghp_abc is not a token", "a short ghp_ string")
    gone("github_pat_11AAAAAAA0123456789_abcdefghijklmnopqrstuvwxyz", secret: "github_pat_11", "fine-grained GitHub token")
    gone("SLACK=xoxb-1234567890-abcdefghijkl", secret: "xoxb-1234567890", "Slack token")
    gone("OPENAI_KEY sk-abcdefghijklmnopqrstuvwx", secret: "sk-abcdefghijklmnopqrstuvwx", "sk- key")
    gone("sk-ant-api03-abcdefghijklmnopqrstuvwxyz", secret: "sk-ant-api03", "Anthropic-style key")
    same("scikit: sk-learn is a package", "a short sk- string")
    same("ask-me-anything-about-this-topic-today", "sk- inside a word")
    same("task-force-reduction-plan-for-2024", "sk- inside another word")
    gone("AIzaSyA-1234567890abcdefghijklmnopqrstu", secret: "AIzaSyA-1234567890", "Google API key")
    same("AIzaSyA-1234567890abcdefghijklmnopqrstuvwxyz", "a Google-key lookalike that is too long")
    gone("sk_live_abcdefghijklmnop1234", secret: "sk_live_abcdefghijklmnop1234", "Stripe key")
    gone("jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijk end", secret: "eyJhbGciOiJIUzI1NiJ9", "JWT")

    // Private keys, whole and cut off.
    let pem = "before\n-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA\nabc\n-----END RSA PRIVATE KEY-----\nafter"
    check(masked(pem) == "before\n[redacted private key]\nafter", "a whole private key goes, its surroundings stay: \(masked(pem).debugDescription)")
    let cut = "ok\n-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASC"
    check(masked(cut) == "ok\n[redacted private key]", "a key cut off mid-way goes to the end: \(masked(cut).debugDescription)")
    same("-----BEGIN PUBLIC KEY-----\nMIIBIjANBg\n-----END PUBLIC KEY-----", "a public key")

    // URLs, headers, flags and assignments.
    check(masked("git clone https://user:hunter2@example.com/repo.git") == "git clone https://user:[redacted]@example.com/repo.git",
          "a password in a URL: \(masked("git clone https://user:hunter2@example.com/repo.git"))")
    same("ssh://git@github.com:22/repo", "a URL with a user and no password")
    same("http://localhost:8080/path@x", "a port is not a password")
    check(masked("Authorization: Bearer abc.def.ghi") == "Authorization: [redacted]", "an Authorization header: \(masked("Authorization: Bearer abc.def.ghi"))")
    check(masked("curl -H \"Authorization: token ghp_x\" url") == "curl -H \"Authorization: [redacted]\" url", "a header in quotes: \(masked("curl -H \"Authorization: token ghp_x\" url"))")
    check(masked("sent Bearer abcdefghij123 ok") == "sent Bearer [redacted] ok", "a bare bearer token")
    same("a bearer of bad news", "the word bearer")
    check(masked("run --password hunter2 now") == "run --password [redacted] now", "a password flag")
    check(masked("run --token=abc123 now") == "run --token=[redacted] now", "a token flag with =")
    same("run --token --verbose", "a token flag followed by a flag")
    same("run --passthrough value", "a flag that merely starts like one")
    check(masked("PASSWORD=hunter2 ./run") == "PASSWORD=[redacted] ./run", "a password assignment")
    check(masked("export API_KEY=\"abc def\"") == "export API_KEY=[redacted]", "a quoted value: \(masked("export API_KEY=\"abc def\""))")
    check(masked("{\"password\": \"hunter2\", \"user\": \"me\"}") == "{\"password\": [redacted], \"user\": \"me\"}",
          "a JSON password: \(masked("{\"password\": \"hunter2\", \"user\": \"me\"}"))")
    check(masked("db_password: s3cret") == "db_password: [redacted]", "a YAML-style secret")
    check(masked("aws_secret_access_key = abcd1234") == "aws_secret_access_key = [redacted]", "a spaced assignment")
    // Near misses: prose, prompts, and unrelated words.
    same("Enter your password to continue", "the word password in prose")
    same("Password:", "a bare password prompt")
    same("Password:\nthe next line stays", "a prompt does not take the next line")
    same("the author = John", "author is not auth")
    same("3 tokens remaining", "tokens in prose")
    same("npm run test -- --watch", "an ordinary command")
    same("drwxr-xr-x  5 me  staff  160 Oct  3 12:00 src\n-rw-r--r--  1 me  staff  1.2K README.md", "a directory listing")
    same("error: cannot find module './config' in /Users/me/app", "an ordinary error")
    // Several at once, and idempotence.
    let mixed = "TOKEN=abc https://u:p@h/x Authorization: Bearer zzz AKIAIOSFODNN7EXAMPLE --password hunter2"
    let once = masked(mixed)
    check(!once.contains("abc") && !once.contains(":p@") && !once.contains("zzz") && !once.contains("AKIAIOSFODNN7EXAMPLE") && !once.contains("hunter2"),
          "several secrets in one line all go: \(once)")
    check(masked(once) == once, "masking twice changes nothing more: \(masked(once)) vs \(once)")
}

// MARK: Sanitising output

do {
    check(ContextSanitizer.stripANSI("\u{1B}[31mred\u{1B}[0m plain") == "red plain", "colour codes are stripped: \(ContextSanitizer.stripANSI("\u{1B}[31mred\u{1B}[0m plain").debugDescription)")
    check(ContextSanitizer.stripANSI("\u{1B}]0;a title\u{07}text") == "text", "an OSC title is stripped")
    check(ContextSanitizer.stripANSI("\u{1B}[2K\u{1B}[1Gprompt") == "prompt", "cursor movement is stripped")
    check(ContextSanitizer.sanitizeRecentOutput("short\nthing") == "short\nthing", "short output is untouched")
    check(ContextSanitizer.sanitizeRecentOutput("a\r\nb\rc") == "a\nb\nc", "line endings are normalised")
    check(ContextSanitizer.sanitizeRecentOutput("\u{1B}[31mkey=abcd1234efgh\u{1B}[0m") == "key=abcd1234efgh" || !ContextSanitizer.sanitizeRecentOutput("secret=\u{1B}[1mhunter2\u{1B}[0m").contains("hunter2"),
          "a secret split by colour codes is still masked")

    let plain = "aaaa\nbbbb\ncccc\ndddd"
    check(ContextSanitizer.sanitizeRecentOutput(plain, limit: 12) == "\u{2026}\ncccc\ndddd", "a cut inside a line drops the fragment: \(ContextSanitizer.sanitizeRecentOutput(plain, limit: 12).debugDescription)")
    check(ContextSanitizer.sanitizeRecentOutput(plain, limit: 9) == "\u{2026}\ncccc\ndddd", "a cut on a line start keeps the line: \(ContextSanitizer.sanitizeRecentOutput(plain, limit: 9).debugDescription)")
    check(ContextSanitizer.sanitizeRecentOutput(plain, limit: 10) == "\u{2026}\ncccc\ndddd", "a cut on the newline itself: \(ContextSanitizer.sanitizeRecentOutput(plain, limit: 10).debugDescription)")
    check(ContextSanitizer.sanitizeRecentOutput(String(repeating: "x", count: 50), limit: 20) == "\u{2026}\n" + String(repeating: "x", count: 20),
          "one long line keeps its tail rather than nothing")
    // On one long line nothing is dropped as a fragment, so the order of masking
    // and cutting is what keeps a half token out.
    let oneLine = "prefix TOKEN=abcd1234efgh5678 suffix text"
    for limit in 8...(oneLine.count - 1) {
        let result = ContextSanitizer.sanitizeRecentOutput(oneLine, limit: limit)
        check(!result.contains("abcd") && !result.contains("efgh") && !result.contains("5678") && !result.contains("1234"),
              "a secret cut by the limit \(limit) on a single line leaves no fragment: \(result.debugDescription)")
    }
    // Masked before it is cut: a token straddling the cut cannot survive as a fragment.
    let straddle = "line one\nTOKEN=abcd1234efgh5678 and more text here\nlast line"
    for limit in 20...48 {
        let result = ContextSanitizer.sanitizeRecentOutput(straddle, limit: limit)
        check(!result.contains("abcd") && !result.contains("efgh") && !result.contains("5678"),
              "a secret cut by the limit \(limit) leaves no fragment: \(result.debugDescription)")
    }
}

// MARK: Failure signatures

do {
    func reason(_ line: String, command: String? = nil) -> String? {
        FailureSignature.firstMatch(in: [line], excludingCommand: command)?.reason
    }
    let positives: [(String, String)] = [
        ("zsh: command not found: foo", "command not found"),
        ("bash: foo: command not found", "command not found"),
        ("ls: /nope: No such file or directory", "no such file or directory"),
        ("zsh: no such file or directory: ./x", "no such file or directory"),
        ("cat: secret.txt: Permission denied", "permission denied"),
        ("zsh: permission denied: ./run.sh", "permission denied"),
        ("me@host: Permission denied (publickey).", "permission denied"),
        ("fatal: not a git repository (or any of the parent directories): .git", "a fatal error"),
        ("fatal error: 'foo.h' file not found", "a fatal error"),
        ("Traceback (most recent call last):", "a Python traceback"),
        ("npm ERR! code ENOENT", "an npm error"),
        ("panic: runtime error: index out of range", "a panic"),
        ("thread 'main' panicked at src/main.rs:2:5:", "a panic"),
        ("zsh: segmentation fault  ./a.out", "a crash"),
        ("Segmentation fault: 11", "a crash"),
        ("make: *** [all] Error 1", "a failed make"),
        ("make[2]: *** [build/x.o] Error 1", "a failed make"),
        ("** BUILD FAILED **", "a failed build"),
        ("   zsh: command not found: indented", "command not found"),
    ]
    for (line, expected) in positives {
        check(reason(line) == expected, "\(line.debugDescription) should read as \(expected), got \(String(describing: reason(line)))")
    }
    let negatives = [
        "Permission denied is what the docs call this",
        "src/a.c:10: // No such file or directory handling",
        "grep: hello world",
        "make: Nothing to be done for 'all'.",
        "make[x]: *** not a make error",
        "makefile is fine",
        "everything is fine, no panic: here",
        "see the Traceback (most recent call last) section of the docs",
        "the fatal: word in the middle of a line",
        "Compiling 14 files... done",
        "total 8",
        "",
        "   ",
    ]
    for line in negatives {
        check(reason(line) == nil, "\(line.debugDescription) is not an error, got \(String(describing: reason(line)))")
    }
    // The shell's echo of the typed command is not output; what it says about it is.
    func lines(_ text: String, command: String) -> FailureSignature.Match? {
        FailureSignature.firstMatch(in: text.components(separatedBy: "\n"), excludingCommand: command)
    }
    check(lines("% echo zsh: command not found: x", command: "echo zsh: command not found: x") == nil, "the echo of a command that mentions an error is not one")
    check(lines("me@host ~ % nosuch\nzsh: command not found: nosuch\nme@host ~ %", command: "nosuch")?.reason == "command not found",
          "the shell's complaint about a command is found even though it contains the command: \(String(describing: lines("me@host ~ % nosuch\nzsh: command not found: nosuch\nme@host ~ %", command: "nosuch")))")
    check(lines("% ./run.sh\nzsh: permission denied: ./run.sh", command: "./run.sh")?.reason == "permission denied", "a refusal that names the script")
    check(lines("% cat missing.txt\ncat: missing.txt: No such file or directory", command: "cat missing.txt")?.reason == "no such file or directory", "a missing file that names the file")
    check(lines("% echo permission denied: x\nfine", command: "echo permission denied: x") == nil, "only the echo is set aside, and nothing else matched")
    check(lines("% git checkout -- nope\nerror: pathspec 'nope' did not match any file(s)\nfatal: not a repo", command: "git checkout -- nope")?.reason == "a fatal error", "later lines are still read")
    check(lines("zsh: command not found: nosuch", command: "nosuch") == nil, "with no echo captured, the first line mentioning the command is taken for it")
    check(lines("nothing here", command: "nosuch") == nil && lines("bash: x: command not found", command: "ls")?.reason == "command not found",
          "a command that never appears sets nothing aside")
    check(FailureSignature.firstMatch(in: ["fine", "bash: x: command not found", "fatal: later"], excludingCommand: nil)?.line == "bash: x: command not found",
          "the first matching line wins")
    check(FailureSignature.firstMatch(in: [], excludingCommand: nil) == nil, "no lines, no match")

    // What is new since the command was sent.
    let before = "$ ls\nfile.txt\nzsh: command not found: old\n$ "
    check(OutputDiff.newLines(baseline: before, current: before).isEmpty, "nothing new when nothing changed")
    check(OutputDiff.newLines(baseline: before, current: before + "\n$ make\nmake: *** [all] Error 1\n$ ") == ["$ make", "make: *** [all] Error 1", "$"],
          "only what was added: \(OutputDiff.newLines(baseline: before, current: before + "\n$ make\nmake: *** [all] Error 1\n$ "))")
    check(FailureSignature.firstMatch(in: OutputDiff.newLines(baseline: before, current: before), excludingCommand: nil) == nil,
          "an error already on screen before the command is not the command's")
    check(OutputDiff.newLines(baseline: before, current: before + "\nzsh: command not found: old") == ["zsh: command not found: old"],
          "the same error printed again is new")
    check(OutputDiff.newLines(baseline: "a\nb\n", current: "a\r\nb  \r\nc\r\n") == ["c"], "line endings and trailing blanks do not make lines new")
    check(OutputDiff.newLines(baseline: "", current: "x\n\n\ny\n") == ["x", "y"], "blank lines are left out")
    // Output scrolling the old lines away is still only the new lines.
    check(OutputDiff.newLines(baseline: "one\ntwo\nthree\n", current: "three\nfour\nfive\n") == ["four", "five"], "scrolled-away lines do not matter")
    check(OutputDiff.newLines(baseline: "x\nx\n", current: "x\nx\nx\n") == ["x"], "a line seen twice before and three times now is new once")
}

// MARK: Replies

do {
    let reply = "The file is missing.\n\n```bash\nls -la src\n```\n\nThen:\n\n```python\nprint('hi')\n```\nDone."
    check(AssistReply.segments(of: reply) == [
        .prose("The file is missing."),
        .code(language: "bash", text: "ls -la src"),
        .prose("Then:"),
        .code(language: "python", text: "print('hi')"),
        .prose("Done."),
    ], "prose and code blocks separate: \(AssistReply.segments(of: reply))")
    check(AssistReply.segments(of: "Try:\n```\nbrew install jq\n```") == [.prose("Try:"), .code(language: nil, text: "brew install jq")], "an untagged block")
    check(AssistReply.segments(of: "```SH\necho hi\n```") == [.code(language: "sh", text: "echo hi")], "the tag is lower-cased")
    check(AssistReply.segments(of: "run ```ls```") == [.prose("run ```ls```")] || AssistReply.segments(of: "```ls```") == [.code(language: nil, text: "ls")],
          "a block opened and closed on one line")
    check(AssistReply.segments(of: "Try:\n```sh\nnpm install\nnpm test") == [.prose("Try:"), .code(language: "sh", text: "npm install\nnpm test")], "a block cut off at the end runs to the end")
    check(AssistReply.segments(of: "just words\nmore words") == [.prose("just words\nmore words")], "no code, one prose segment")
    check(AssistReply.segments(of: "").isEmpty, "an empty reply has no segments")
    check(AssistReply.segments(of: "```\n```").isEmpty, "an empty block is nothing")
    check(AssistReply.segments(of: "a\r\n```sh\r\nls\r\n```\r\n") == [.prose("a"), .code(language: "sh", text: "ls")], "CRLF replies")
    check(AssistReply.segments(of: "  ```sh\n  ls\n  ```") == [.code(language: "sh", text: "ls")], "an indented fence")
    check(AssistReply.segments(of: "```sh\nls\n```\n```sh\npwd\n```").count == 2, "two blocks in a row")
    check(AssistReply.segments(of: "```sh\n$ ls -la\ntotal 0\n$ pwd\n/tmp\n```") == [.code(language: "sh", text: "ls -la\npwd")],
          "a session block keeps the prompted lines and drops the output: \(AssistReply.segments(of: "```sh\n$ ls -la\ntotal 0\n$ pwd\n/tmp\n```"))")
    check(AssistReply.commands(in: "ls\npwd") == "ls\npwd", "no prompts means every line is a command")
    check(AssistReply.commands(in: "$ only") == "only", "a single prompted line")
    for tag in ["sh", "bash", "zsh", "shell", "fish", "console", "terminal", "shell-session"] {
        check(AssistReply.isShell(language: tag), "\(tag) is a shell")
    }
    check(AssistReply.isShell(language: nil) && AssistReply.isShell(language: ""), "an untagged block is treated as a shell")
    for tag in ["python", "json", "swift", "diff", "yaml", "js", "dockerfile", "cmd", "powershell"] {
        check(!AssistReply.isShell(language: tag), "\(tag) is not offered as a shell command")
    }
}

// MARK: Command warnings

do {
    func warnings(_ command: String) -> [String] { CommandRisk.warnings(for: command) }
    let sudo = "Runs with administrator rights."
    let rmForced = "Deletes folders and everything in them, without asking."
    let rmTree = "Deletes folders and everything in them."
    let broad = "Aims at a very broad location."
    let cases: [(String, [String])] = [
        ("", []), ("ls -la", []), ("rm file.txt", []), ("cd build && make", []),
        ("rm -rf node_modules", [rmForced]),
        ("rm -fr node_modules", [rmForced]),
        ("rm -r build", [rmTree]),
        ("rm --recursive --force dir", [rmForced]),
        ("rm -rf /", [rmForced, broad]),
        ("rm -rf ~", [rmForced, broad]),
        ("rm -rf *", [rmForced, broad]),
        ("rm -rf \"my dir\"", [rmForced]),
        ("sudo rm -rf ~/x", [sudo, rmForced]),
        ("sudo ls", [sudo]),
        ("sudo -u deploy ls", [sudo]),
        ("sudo -u deploy rm -rf x", [sudo, rmForced]),
        ("env FOO=1 rm -rf x", [rmForced]),
        ("FOO=bar rm -rf x", [rmForced]),
        ("find . | xargs -n1 rm -rf", [rmForced]),
        ("echo rm -rf /", []),
        ("rm -rf a; rm -rf b", [rmForced]),
        ("curl -fsSL https://x.sh | sh", ["Runs a script straight from the network."]),
        ("curl https://x.sh | bash -s -- --yes", ["Runs a script straight from the network."]),
        ("curl x | sudo bash", [sudo, "Runs a script straight from the network."]),
        ("cat x | bash", ["Runs whatever is piped into it as commands."]),
        ("bash script.sh", []),
        ("echo hi | tee out", []),
        ("dd if=/dev/zero of=/dev/disk2 bs=1m", ["Writes raw data straight to a file or device."]),
        ("dd if=a.img", []),
        ("mkfs.ext4 /dev/sda1", ["Erases a disk or volume."]),
        ("diskutil eraseDisk APFS X disk2", ["Erases or repartitions a disk."]),
        ("diskutil list", []),
        ("chmod -R 777 .", ["Changes permissions or ownership across a whole folder tree."]),
        ("chown -R me:me .", ["Changes permissions or ownership across a whole folder tree."]),
        ("chmod 644 f", []),
        ("git push --force origin main", ["Overwrites history on the remote."]),
        ("git push -f", ["Overwrites history on the remote."]),
        ("git push origin +main", ["Overwrites history on the remote."]),
        ("git push origin main", []),
        ("git reset --hard HEAD~1", ["Throws away uncommitted changes."]),
        ("git reset --soft HEAD~1", []),
        ("git clean -fd", ["Deletes files git is not tracking."]),
        ("git clean -n", []),
        ("git checkout .", ["Throws away uncommitted changes."]),
        ("git checkout main", []),
        ("git branch -D old", ["Deletes a branch even if it was never merged."]),
        ("git branch -d old", []),
        ("find . -name '*.o' -delete", ["Deletes every file it finds."]),
        ("find . -name x", []),
        ("shutdown -h now", ["Shuts down or restarts this Mac."]),
        ("echo hi > out.txt", ["Overwrites the file it writes to."]),
        ("echo hi >out.txt", ["Overwrites the file it writes to."]),
        ("echo hi >> out.txt", []),
        ("echo hi > /dev/null", []),
        ("cmd 2>&1", []),
        ("cmd 2> err.log", ["Overwrites the file it writes to."]),
        ("cmd > /dev/null 2>&1", []),
        ("ls > a.txt && cat a.txt", ["Overwrites the file it writes to."]),
        ("echo \"a > b\"", []),
        (":(){ :|:& };:", ["Looks like a fork bomb."]),
    ]
    for (command, expected) in cases {
        check(warnings(command) == expected, "\(command.debugDescription): expected \(expected), got \(warnings(command))")
    }
}

// MARK: Where a request goes, and what asking says

do {
    check(AssistantDestination.describe(baseURL: "https://api.openai.com/v1") == .init(name: "api.openai.com", staysOnThisMac: false), "a hosted endpoint is named")
    check(AssistantDestination.describe(baseURL: "http://127.0.0.1:11434/v1") == .init(name: "the assistant on this Mac", staysOnThisMac: true), "a loopback address stays on this Mac")
    check(AssistantDestination.describe(baseURL: "http://localhost:11434/v1").staysOnThisMac, "localhost stays on this Mac")
    check(AssistantDestination.describe(baseURL: "http://[::1]:8080/v1").staysOnThisMac, "::1 stays on this Mac: \(AssistantDestination.describe(baseURL: "http://[::1]:8080/v1"))")
    check(!AssistantDestination.describe(baseURL: "http://192.168.1.20:11434/v1").staysOnThisMac, "a LAN address does not")
    check(!AssistantDestination.describe(baseURL: "https://localhost.evil.example/v1").staysOnThisMac, "a name that merely starts with localhost does not")
    check(!AssistantDestination.describe(baseURL: "http://127.0.0.1.evil.example/v1").staysOnThisMac, "nor one that starts with a loopback address")
    check(AssistantDestination.describe(baseURL: "not a url") == .init(name: "the configured assistant endpoint", staysOnThisMac: false), "an unreadable URL is not trusted")
    check(AssistantDestination.describe(baseURL: "").staysOnThisMac == false, "an empty URL is not trusted")
    check(AssistantDestination.describe(baseURL: "  https://api.groq.com/openai/v1 \n").name == "api.groq.com", "whitespace is ignored")

    let key = "AKIAIOSFODNN7EXAMPLE"
    let request = ErrorHelpRequest.make(
        kind: .explain,
        command: "  aws s3 ls --password hunter2  ",
        rawOutput: "\u{1B}[31mAn error occurred\u{1B}[0m\nkey \(key)\nsecond line\n",
        baseURL: "https://api.openai.com/v1"
    )
    check(request.command == "aws s3 ls --password [redacted]", "the command is trimmed and masked: \(String(describing: request.command))")
    check(!request.output.contains(key) && !request.output.contains("\u{1B}") && request.output.contains("An error occurred"), "the output is stripped and masked: \(request.output.debugDescription)")
    check(request.lineCount == 3, "lines are counted after cleaning: \(request.lineCount)")
    check(request.consentMessage == "Send the command and 3 lines of output to api.openai.com? Values that look like keys or passwords are masked first.",
          "the consent question names the host: \(request.consentMessage)")
    let local = ErrorHelpRequest.make(kind: .fix, command: nil, rawOutput: "one line", baseURL: "http://127.0.0.1:11434/v1")
    check(local.command == nil && local.lineCount == 1, "no command, one line")
    check(local.consentMessage == "Send 1 line of output to the assistant on this Mac? It stays on this Mac.", "a local assistant says so: \(local.consentMessage)")
    check(!request.consentMessage.contains("stays on this Mac"), "a hosted one never claims it")

    // The request is what is sent: everything in it is listed in the question and
    // shown in the preview, and nothing is left out of either.
    let withContext = ErrorHelpRequest.make(
        kind: .explain,
        command: "ls",
        rawOutput: "a\nb",
        baseURL: "https://api.openai.com/v1",
        workingDirectory: "/Users/me/clients/acme",
        gitBranch: "feature/x",
        workspaceName: "Acme redesign"
    )
    check(withContext.consentMessage == "Send the command, 2 lines of output, the working directory, the git branch and the workspace name to api.openai.com? Values that look like keys or passwords are masked first.",
          "the question lists every kind of thing sent: \(withContext.consentMessage)")
    check(withContext.preview == "Working directory:\n/Users/me/clients/acme\n\nGit branch:\nfeature/x\n\nWorkspace:\nAcme redesign\n\nCommand:\nls\n\nOutput:\na\nb\n\nRequest:\n" + withContext.prompt,
          "the preview shows every field: \(withContext.preview.debugDescription)")
    let someContext = ErrorHelpRequest.make(kind: .fix, command: nil, rawOutput: "x", baseURL: "http://localhost:11434/v1", workingDirectory: "/tmp", gitBranch: "  ", workspaceName: nil)
    check(someContext.consentMessage == "Send 1 line of output and the working directory to the assistant on this Mac? It stays on this Mac.",
          "only what is present is listed: \(someContext.consentMessage)")
    check(someContext.gitBranch == nil, "a blank field is no field")
    check(someContext.preview == "Working directory:\n/tmp\n\nOutput:\nx\n\nRequest:\n" + someContext.prompt, "and only what is present is shown: \(someContext.preview.debugDescription)")
    check(ErrorHelpRequest.make(kind: .explain, command: nil, rawOutput: "x", baseURL: "https://a.b", workingDirectory: "/Users/me/AKIAIOSFODNN7EXAMPLE").workingDirectory == "/Users/me/[redacted]",
          "context fields are masked like everything else")
    // Every field is in the contents list exactly when it is in the preview.
    for request in [request, local, withContext, someContext] {
        check(request.contents.contains("the command") == request.preview.contains("Command:"), "command listed iff shown")
        check(request.contents.contains("the working directory") == request.preview.contains("Working directory:"), "directory listed iff shown")
        check(request.contents.contains("the git branch") == request.preview.contains("Git branch:"), "branch listed iff shown")
        check(request.contents.contains("the workspace name") == request.preview.contains("Workspace:"), "workspace listed iff shown")
    }
    check(ErrorHelpRequest.make(kind: .explain, command: "   ", rawOutput: "x", baseURL: "https://a.b").command == nil, "a blank command is no command")
    check((ErrorHelpRequest.make(kind: .explain, command: String(repeating: "a", count: 5_000), rawOutput: "x", baseURL: "https://a.b").command?.count ?? 0) <= ErrorHelpRequest.commandLimit,
          "a very long command is cut")
    // A token straddling the command limit is masked whole before the cut.
    let straddling = String(repeating: "a ", count: 495) + "ghp_" + String(repeating: "A1b2", count: 9) + " tail"
    let cutCommand = ErrorHelpRequest.make(kind: .explain, command: straddling, rawOutput: "x", baseURL: "https://a.b").command ?? ""
    check(!cutCommand.contains("ghp_") && !cutCommand.contains("A1b2") && cutCommand.count <= ErrorHelpRequest.commandLimit,
          "a token across the command limit leaves no fragment: \(cutCommand.suffix(30).debugDescription)")
    check(ErrorHelpRequest.make(kind: .explain, command: nil, rawOutput: "x", baseURL: "https://a.b").prompt != ErrorHelpRequest.make(kind: .fix, command: nil, rawOutput: "x", baseURL: "https://a.b").prompt,
          "explain and fix ask different things")
    check(ErrorHelpRequest.make(kind: .fix, command: nil, rawOutput: "x", baseURL: "https://a.b").prompt.contains("fenced code block"), "fix asks for a fenced command")
}

// MARK: Assistant output is never run

// The assistant's words reach the terminal only by a person pressing Return in
// the composer, after they were put in the input for review. Nothing in the AI
// code, the composer's AI views, or the failure watcher may send text to a
// terminal itself. Comments are skipped, so a comment may say so.
do {
    let fm = FileManager.default
    var files: [String] = []
    if let aiFiles = try? fm.contentsOfDirectory(atPath: "Sources/iTERMiNAL/AI") {
        files += aiFiles.filter { $0.hasSuffix(".swift") }.map { "Sources/iTERMiNAL/AI/" + $0 }
    }
    files += ["Sources/iTERMiNAL/Chrome/ComposerAI.swift", "Sources/iTERMiNAL/Chrome/ErrorAssistViews.swift"]
    check(files.count >= 10, "found the AI sources to check (\(files.count)); run from the repository root")
    let forbidden = ["sendFromComposer", ".send(text:", "session.send(", "engine.send("]
    var offenders: [String] = []
    for path in files {
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            if !path.hasSuffix("ErrorAssistViews.swift") { offenders.append("\(path): unreadable") }
            continue
        }
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        for word in forbidden where code.contains(word) { offenders.append("\(path) uses \(word)") }
    }
    check(offenders.isEmpty, "the AI path must not send to a terminal: \(offenders)")
}

print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
