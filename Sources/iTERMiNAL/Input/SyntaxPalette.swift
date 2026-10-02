/// The colours the composer paints a command line in.
struct SyntaxColors: Equatable {
    var command: UInt32
    var flag: UInt32
    var string: UInt32
    var variable: UInt32
    var op: UInt32
    var comment: UInt32
}

/// Chooses those colours so a command reads on the field it is typed in.
///
/// They come from the terminal theme's own palette, so the input matches the
/// transcript above it and follows a theme change. But the input field follows
/// the *app's* appearance, not the terminal theme's: Dracula's pastels on the
/// light field are nearly invisible, and Solarized Light's on the dark one are
/// no better. So each colour is checked against the field's background, and one
/// that would not read is replaced by a value tuned for it instead.
///
/// That background must be a single opaque colour — `Theme.inputFieldHex` — for
/// the check to mean anything: against a translucent fill the real background
/// would depend on what is behind the composer.
enum SyntaxPalette {
    /// WCAG AA for normal text. The input is 13 pt regular, which is not the
    /// large text that the lower 3:1 floor is for, so this applies to every
    /// colour here, comments included.
    static let minimumContrast = 4.5

    /// ANSI slots: green commands, cyan flags, yellow strings, magenta
    /// variables, blue operators. Unquoted arguments keep the body colour.
    static func colors(ansi: [UInt32], foreground: UInt32, background: UInt32, darkBackground: Bool) -> SyntaxColors {
        let fallback = darkBackground ? darkFallback : lightFallback

        func pick(_ slot: Int, _ backup: UInt32) -> UInt32 {
            guard ansi.indices.contains(slot),
                  ColorMath.contrast(ansi[slot], background) >= minimumContrast else { return backup }
            return ansi[slot]
        }

        // Quieter than the body text, but still readable.
        let muted = ColorMath.mix(foreground, background, 0.45)
        let comment = ColorMath.contrast(muted, background) >= minimumContrast ? muted : fallback.comment

        return SyntaxColors(
            command: pick(2, fallback.command),
            flag: pick(6, fallback.flag),
            string: pick(3, fallback.string),
            variable: pick(5, fallback.variable),
            op: pick(4, fallback.op),
            comment: comment
        )
    }

    /// Tuned against `Theme.darkInputFieldHex`.
    static let darkFallback = SyntaxColors(
        command: 0x7DD3A0,
        flag: 0x6CC7D9,
        string: 0xE6C07B,
        variable: 0xC792EA,
        op: 0x82AAFF,
        comment: 0x8A8A94
    )

    /// Tuned against `Theme.lightInputFieldHex`.
    static let lightFallback = SyntaxColors(
        command: 0x1A7448,
        flag: 0x0B7285,
        string: 0x8A5A00,
        variable: 0x8E3FB5,
        op: 0x2F5BD2,
        comment: 0x666670
    )
}
