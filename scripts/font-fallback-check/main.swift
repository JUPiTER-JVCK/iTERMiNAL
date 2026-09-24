// Proves on a real Mac that Nerd Font icons resolve to the bundled symbols
// face, through the same code the app uses: SymbolsFont.swift is compiled in
// beside this file, not copied. CI runs it against the font inside the built
// app:
//
//   swiftc -o font-check Sources/iTERMiNAL/Terminal/SymbolsFont.swift \
//     scripts/font-fallback-check/main.swift
//   ./font-check iTERMiNAL.app/Contents/Resources/Fonts/SymbolsNerdFontMono-Regular.ttf
//
// Each sample is laid out the way SwiftTerm draws a row — a CTLine over an
// attributed string — so the font CoreText picks for the icon's run is the
// font the terminal will draw it with. Exits non-zero if any icon falls
// through to another font, or if the fallback takes over a character the
// terminal font already has.
import AppKit
import CoreText

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    print("usage: font-check PATH-TO-SymbolsNerdFontMono-Regular.ttf")
    exit(2)
}
guard let symbols = SymbolsFont.register(URL(fileURLWithPath: arguments[1])),
      let symbolsName = NSFont(descriptor: symbols, size: 13)?.fontName else {
    print("error: could not register or load \(arguments[1])")
    exit(1)
}
print("registered \(symbolsName)")

// One icon from each block superfile, prompts and ls replacements draw from.
let icons: [(label: String, scalar: UInt32)] = [
    ("folder (Font Awesome)", 0xF07B),
    ("branch (Powerline)", 0xE0A0),
    ("config file (Seti)", 0xE615),
    ("folder (Material Design, supplementary plane)", 0xF024B),
]

/// The PostScript name of the font CoreText uses for `scalar` when it sits
/// between two letters set in `font`.
func drawingFont(for scalar: UInt32, in font: NSFont) -> String? {
    guard let icon = Unicode.Scalar(scalar) else { return nil }
    let text = "a\(Character(icon))b"
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: text, attributes: [.font: font])
    )
    let iconStart = ("a" as NSString).length
    for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
        let range = CTRunGetStringRange(run)
        guard range.location <= iconStart, iconStart < range.location + range.length else { continue }
        let attributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any] ?? [:]
        return (attributes[.font] as? NSFont)?.fontName
    }
    return nil
}

var failed = false

// SF Mono is the app's default; Menlo stands in for a font the user picks.
let bases: [NSFont] = [
    NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
    NSFont(name: "Menlo", size: 13)!,
]
for base in bases {
    let font = base.cascading(to: symbols)
    for icon in icons {
        let got = drawingFont(for: icon.scalar, in: font) ?? "nothing"
        if got == symbolsName {
            print("ok    \(base.fontName): \(icon.label) -> \(got)")
        } else {
            print("FAIL  \(base.fontName): \(icon.label) -> \(got), expected \(symbolsName)")
            failed = true
        }
    }
    // The cascade is consulted only for missing characters. If it ever took
    // over letters, every line in every terminal would change font.
    let letterFont = drawingFont(for: 0x57, in: font) ?? "nothing" // "W"
    if letterFont == font.fontName {
        print("ok    \(base.fontName): letters stay in \(letterFont)")
    } else {
        print("FAIL  \(base.fontName): letters moved to \(letterFont), expected \(font.fontName)")
        failed = true
    }

    // SwiftTerm derives bold, italic and bold-italic itself, through
    // NSFontManager, from the font it is given. Whether those keep the cascade
    // is up to AppKit, not this app, so it is reported rather than enforced:
    // superfile draws its icons in regular weight, but a prompt that bolds an
    // icon depends on this.
    let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    let boldGot = drawingFont(for: icons[0].scalar, in: bold) ?? "nothing"
    print("info  \(bold.fontName) (bold, derived as SwiftTerm does): \(icons[0].label) -> \(boldGot)")
}

exit(failed ? 1 : 0)
