import Foundation

/// The environment that makes ordinary commands print in colour — directories
/// in `ls`, headings and options in `man` — set up from the app rather than from
/// a shell plugin.
///
/// This is what zsh-colored-man-pages, zsh-colors and zsh-colorize do for zsh,
/// done once here: the same variables, handed to whichever shell the terminal
/// starts, so bash and fish get them too and nothing has to be installed.
///
/// Every colour is an ANSI *number*, never an RGB value. The terminal's theme
/// decides what "blue" and "bold red" look like, so the output follows a theme
/// change and reads on a light theme and a dark one alike.
///
/// Two rules keep it polite. A variable that is already set is left alone, and
/// the shell's own startup files run after this, so what a person puts in
/// `.zshrc` wins. And `NO_COLOR` — the convention for "no colour, anywhere" —
/// turns the whole thing off.
struct OutputColors: Equatable {
    /// `ls` and the tools that read `LS_COLORS`: directories, links, scripts.
    var listings: Bool
    /// `man`, and anything else read through `less`.
    var manPages: Bool

    // MARK: What gets coloured

    enum ListingKind: CaseIterable {
        case directory, symlink, socket, pipe, executable
        case blockDevice, characterDevice, setuid, setgid
        case stickyWritableDirectory, writableDirectory
    }

    /// One entry of the listing table: what it is, the key GNU `ls` calls it
    /// by, and the SGR codes it is drawn with.
    struct ListingStyle: Equatable {
        let kind: ListingKind
        let gnuKey: String
        let sgr: String
    }

    /// In the order BSD's `LSCOLORS` wants its eleven pairs. GNU names the same
    /// things by key, so one table is both.
    static let listingStyles: [ListingStyle] = [
        ListingStyle(kind: .directory, gnuKey: "di", sgr: "01;34"),
        ListingStyle(kind: .symlink, gnuKey: "ln", sgr: "01;36"),
        ListingStyle(kind: .socket, gnuKey: "so", sgr: "01;35"),
        ListingStyle(kind: .pipe, gnuKey: "pi", sgr: "33"),
        ListingStyle(kind: .executable, gnuKey: "ex", sgr: "01;32"),
        ListingStyle(kind: .blockDevice, gnuKey: "bd", sgr: "34;46"),
        ListingStyle(kind: .characterDevice, gnuKey: "cd", sgr: "34;43"),
        ListingStyle(kind: .setuid, gnuKey: "su", sgr: "30;41"),
        ListingStyle(kind: .setgid, gnuKey: "sg", sgr: "30;46"),
        ListingStyle(kind: .stickyWritableDirectory, gnuKey: "tw", sgr: "30;42"),
        ListingStyle(kind: .writableDirectory, gnuKey: "ow", sgr: "30;43"),
    ]

    /// Kinds of file named by their ending. Only GNU-style tools read these;
    /// BSD `ls` has no way to colour by extension.
    static let extensionStyles: [(sgr: String, endings: [String])] = [
        ("01;31", ["tar", "tgz", "gz", "bz2", "xz", "zst", "zip", "7z", "rar", "dmg", "pkg", "deb", "rpm", "jar"]),
        ("01;35", ["png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "tiff", "bmp", "ico", "mp4", "mov", "mkv", "avi", "webm"]),
        ("00;36", ["mp3", "m4a", "wav", "flac", "ogg", "aac"]),
    ]

    /// GNU's `LS_COLORS`, from the same table.
    static var gnuLSColors: String {
        var parts = ["rs=0"]
        parts += listingStyles.map { "\($0.gnuKey)=\($0.sgr)" }
        parts += ["or=40;31;01", "mi=00"]
        for group in extensionStyles {
            parts += group.endings.map { "*.\($0)=\(group.sgr)" }
        }
        return parts.joined(separator: ":")
    }

    /// BSD's `LSCOLORS`, from the same table: eleven foreground/background pairs.
    static var bsdLSColors: String {
        listingStyles.map { bsdPair(sgr: $0.sgr) }.joined()
    }

    /// SGR codes as BSD writes them: a letter for the foreground, a letter for
    /// the background, `x` for "leave it", and a capital for bold.
    static func bsdPair(sgr: String) -> String {
        let letters = Array("abcdefgh")
        var bold = false
        var foreground = "x"
        var background = "x"
        for code in sgr.split(separator: ";").compactMap({ Int($0) }) {
            switch code {
            case 1: bold = true
            case 30...37: foreground = String(letters[code - 30])
            case 40...47: background = String(letters[code - 40])
            default: break
            }
        }
        // `x` means "leave it", and has no bold form.
        return (bold && foreground != "x" ? foreground.uppercased() : foreground) + background
    }

    // MARK: Man pages

    /// What `less` does for the three kinds of emphasis a man page has. These
    /// are the choices zsh-colored-man-pages made, which people know: bold —
    /// command and function names, option names — in red, underlined — what
    /// you fill in — in green, and `less`'s own status line in yellow on blue.
    static let manPageStyles: [(variable: String, sgr: String)] = [
        ("LESS_TERMCAP_mb", "1;31"),
        ("LESS_TERMCAP_md", "1;31"),
        ("LESS_TERMCAP_me", "0"),
        ("LESS_TERMCAP_so", "1;33;44"),
        ("LESS_TERMCAP_se", "0"),
        ("LESS_TERMCAP_us", "1;32"),
        ("LESS_TERMCAP_ue", "0"),
    ]

    // MARK: The environment

    /// What to add to a shell's environment. `inherited` is what this app was
    /// started with: a variable already there is not replaced.
    func environment(inheriting inherited: [String: String]) -> [String: String] {
        if let noColor = inherited["NO_COLOR"], !noColor.isEmpty { return [:] }

        var added: [String: String] = [:]
        if listings {
            added["CLICOLOR"] = "1"
            added["LSCOLORS"] = Self.bsdLSColors
            added["LS_COLORS"] = Self.gnuLSColors
        }
        if manPages {
            for style in Self.manPageStyles {
                added[style.variable] = "\u{1B}[\(style.sgr)m"
            }
            // Newer groff writes bold as SGR codes, which `less` shows as
            // junk and cannot recolour. This brings back the overstrikes it
            // understands. Harmless where groff isn't what formats the page.
            added["GROFF_NO_SGR"] = "1"
        }
        return added.filter { inherited[$0.key] == nil }
    }
}
