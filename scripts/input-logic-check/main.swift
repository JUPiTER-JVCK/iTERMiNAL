// Checks the composer's pure logic — the command-line tokenizer and the syntax
// palette — on their own, so a mistake in either fails in seconds rather than
// after the app build, and so they can be proven off a Mac:
//
//   swiftc -o input-logic-check \
//     Sources/iTERMiNAL/Input/ColorMath.swift \
//     Sources/iTERMiNAL/Input/ShellTokenizer.swift \
//     Sources/iTERMiNAL/Input/SyntaxPalette.swift \
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

let darkCard: UInt32 = 0x25252B     // Theme.darkFloatingSurfaceHex
let lightCard: UInt32 = 0xFDFDFE    // Theme.lightFloatingSurfaceHex

// This file cannot import Theme, so it repeats the two card colours the
// fallbacks are tuned against. Read them from the source and compare, so a
// change to the card cannot silently leave the tuning behind. Run from the
// repository root, as CI does.
do {
    let path = "Sources/iTERMiNAL/Chrome/Theme.swift"
    if let source = try? String(contentsOfFile: path, encoding: .utf8) {
        func declared(_ name: String) -> UInt32? {
            guard let range = source.range(of: "\(name): UInt32 = 0x") else { return nil }
            let digits = source[range.upperBound...].prefix { $0.isHexDigit }
            return UInt32(digits, radix: 16)
        }
        check(declared("darkFloatingSurfaceHex") == darkCard,
              "Theme.darkFloatingSurfaceHex is \(String(describing: declared("darkFloatingSurfaceHex"))); the fallbacks were tuned for \(ColorMath.hex(darkCard))")
        check(declared("lightFloatingSurfaceHex") == lightCard,
              "Theme.lightFloatingSurfaceHex is \(String(describing: declared("lightFloatingSurfaceHex"))); the fallbacks were tuned for \(ColorMath.hex(lightCard))")
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
for (name, colors, card) in [("dark", SyntaxPalette.darkFallback, darkCard),
                             ("light", SyntaxPalette.lightFallback, lightCard)] {
    for (kind, color) in all(colors) {
        let ratio = ColorMath.contrast(color, card)
        check(ratio >= (kind == "comment" ? 3.0 : 4.5),
              "\(name) fallback \(kind) \(ColorMath.hex(color)) is \(String(format: "%.2f", ratio)):1 on its card")
    }
}

// A cross-section of the shipped terminal themes (ANSI slots 0–7 are enough:
// the palette reads 2–6), on both cards.
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
    for (cardName, card, dark) in [("dark card", darkCard, true), ("light card", lightCard, false)] {
        let colors = SyntaxPalette.colors(ansi: ansi, foreground: foreground, card: card, darkCard: dark)
        for (kind, color) in all(colors) {
            let ratio = ColorMath.contrast(color, card)
            check(ratio >= SyntaxPalette.minimumContrast,
                  "\(name) on the \(cardName): \(kind) \(ColorMath.hex(color)) is \(String(format: "%.2f", ratio)):1")
        }
    }
}

// When the theme's own colours read, they are used as they are.
do {
    let (_, ansi, foreground) = themes[0]
    let colors = SyntaxPalette.colors(ansi: ansi, foreground: foreground, card: darkCard, darkCard: true)
    check(colors.command == ansi[2] && colors.flag == ansi[6] && colors.string == ansi[3]
          && colors.variable == ansi[5] && colors.op == ansi[4],
          "codex-dark on the dark card should keep its own colours, got \(all(colors).map { ColorMath.hex($0.1) })")
}

// A theme that would vanish on the card is replaced, not trusted.
do {
    let (_, ansi, foreground) = themes[4]   // Dracula's pastels
    let colors = SyntaxPalette.colors(ansi: ansi, foreground: foreground, card: lightCard, darkCard: false)
    check(colors.command == SyntaxPalette.lightFallback.command,
          "dracula green on the light card should fall back, got \(ColorMath.hex(colors.command))")
}

// A palette with too few slots falls back rather than crashing.
do {
    let colors = SyntaxPalette.colors(ansi: [], foreground: 0xFFFFFF, card: darkCard, darkCard: true)
    check(colors.command == SyntaxPalette.darkFallback.command, "empty palette should fall back")
}

print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
