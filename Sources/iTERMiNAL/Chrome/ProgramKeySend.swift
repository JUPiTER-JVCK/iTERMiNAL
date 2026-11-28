import Foundation

/// What pressing key caps, as `ProgramKeyCatalog` writes them, sends to a
/// program in a terminal — for the quick reference strip, where a click types
/// the keys it shows.
///
/// Written for the keys the catalog uses, and no wider: Control and a key,
/// Option as Meta (esc, then the key, which is what the terminal sends with
/// Option as Meta on, and what every program here reads as Meta), Shift and a
/// letter, esc, space, tab, and keys typed as they are written. Arrows, page
/// keys and function keys are not sent: what they send depends on modes the
/// program sets, and guessing wrong types something else. Nor is anything with
/// ⌘, which the app keeps for itself.
///
/// Foundation only, so what each cap sends is checked off a Mac.
enum ProgramKeySend {
    /// What pressing `caps` in turn sends, or nil when one of them cannot be
    /// sent from here.
    ///
    /// A return at the end is left off: the person sees what was typed and
    /// presses return to go ahead. A return anywhere else makes the whole thing
    /// nil, because it would run whatever was already typed on the line.
    ///
    /// `lowercaseLetters` sends a letter alone on its cap as the lowercase key,
    /// for a program whose list writes ⌃X U for the u key, the way a menu
    /// prints it.
    static func text(for caps: [String], lowercaseLetters: Bool = false) -> String? {
        var caps = caps
        if caps.last == "↩" { caps.removeLast() }
        guard !caps.isEmpty else { return nil }
        var sent = ""
        for cap in caps {
            guard let piece = text(forCap: cap, lowercaseLetters: lowercaseLetters) else { return nil }
            sent += piece
        }
        return sent
    }

    /// What one cap sends, or nil when it cannot be sent from here.
    static func text(forCap cap: String, lowercaseLetters: Bool = false) -> String? {
        switch cap {
        case "esc": return "\u{1B}"
        case "space": return " "
        case "⇥": return "\t"
        case "↩": return nil
        default: break
        }
        if cap.hasPrefix("⌃") {
            return control(String(cap.dropFirst()))
        }
        if cap.hasPrefix("⇧") {
            // Shift and a letter is the capital. Shift with anything else —
            // ⇧⇥, ⇧← — is a sequence of its own, and not sent.
            let key = String(cap.dropFirst())
            guard key.count == 1, let letter = key.first, letter.isASCII, letter.isLetter else { return nil }
            return key.uppercased()
        }
        if cap.hasPrefix("⌥") {
            let key = String(cap.dropFirst())
            guard key.count == 1, let character = key.first, character.isASCII,
                  !character.isWhitespace, !character.isNewline else { return nil }
            // Meta keys are read case-blind by the programs listed, and the
            // letter on a cap is a capital the way menus print it.
            return "\u{1B}" + key.lowercased()
        }
        // Typed as written: ":wq", "dd", "%". Anything outside printable ASCII
        // is a symbol for a key — an arrow, ⇞ — rather than text.
        guard !cap.isEmpty, cap.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else { return nil }
        if isFunctionKey(cap) { return nil }
        if lowercaseLetters, cap.count == 1, let letter = cap.first, letter.isUppercase {
            return cap.lowercased()
        }
        return cap
    }

    /// Control and a key, as a terminal sends it: the key's code with its top
    /// bits cleared, and the few that are not letters by their usual codes.
    private static func control(_ key: String) -> String? {
        if key == "Space" { return "\u{0}" }
        let scalars = Array(key.unicodeScalars)
        guard scalars.count == 1 else { return nil }
        let scalar = scalars[0]
        let code: UInt8
        switch scalar {
        case "a"..."z", "A"..."Z":
            code = UInt8(scalar.value & 0x1F)
        case "@": code = 0x00
        case "[": code = 0x1B
        case "\\": code = 0x1C
        case "]": code = 0x1D
        case "^", "6": code = 0x1E
        case "_", "/": code = 0x1F
        case "?": code = 0x7F
        default: return nil
        }
        return String(UnicodeScalar(code))
    }

    /// F1, F10: not text, though they are written in ASCII. F alone is a key.
    private static func isFunctionKey(_ cap: String) -> Bool {
        guard cap.count >= 2, cap.first == "F" else { return false }
        return cap.dropFirst().allSatisfy { $0.isNumber }
    }
}
