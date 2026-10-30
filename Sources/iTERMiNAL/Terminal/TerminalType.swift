import Foundation

/// What a session tells the programs in it its terminal is — the `TERM`
/// environment variable. It decides which escape sequences a program sends and
/// which capabilities (colours, italics, a title) it believes it has.
///
/// The engine underneath is xterm-compatible whatever is chosen here, so this
/// is a statement made *to programs*, not a change in what the terminal can
/// do. Naming a type the host has no terminfo entry for does not make the
/// terminal more capable: it makes `less`, `vim` and `tput` print "unknown
/// terminal type" or fall back to a dumb one. That is why a type is only a
/// choice and never the default, and why `TerminfoLookup` can say whether *this*
/// Mac knows the name. It cannot say it for a remote host, and the settings
/// copy says so rather than implying it can.
enum TerminalType: String, CaseIterable, Identifiable {
    case xterm256 = "xterm-256color"
    case ghostty = "xterm-ghostty"
    case xterm = "xterm"
    case xtermColor = "xterm-color"
    case screen256 = "screen-256color"
    case tmux256 = "tmux-256color"
    case vt220 = "vt220"
    case vt100 = "vt100"
    case linux = "linux"

    static let `default`: TerminalType = .xterm256

    var id: String { rawValue }

    /// The value written to `TERM`.
    var termValue: String { rawValue }

    var label: String {
        switch self {
        case .xterm256: return "xterm-256color"
        case .ghostty: return "xterm-ghostty"
        case .xterm: return "xterm"
        case .xtermColor: return "xterm-color"
        case .screen256: return "screen-256color"
        case .tmux256: return "tmux-256color"
        case .vt220: return "vt220"
        case .vt100: return "vt100"
        case .linux: return "linux"
        }
    }

    /// One line on what choosing it means.
    var detail: String {
        switch self {
        case .xterm256:
            return "The common choice. Every host has it."
        case .ghostty:
            return "Tells programs they are in Ghostty. This terminal is not Ghostty, though: programs may use features it lacks, and it can show as stray characters. Use xterm-256color unless something needs this name."
        case .xterm:
            return "Plain xterm: 8 colours. For old hosts."
        case .xtermColor:
            return "xterm with 8 colours, the name some old systems expect."
        case .screen256:
            return "For GNU screen's world; understood nearly everywhere."
        case .tmux256:
            return "For use with tmux; needs a recent terminfo database."
        case .vt220:
            return "A DEC VT220: no colour."
        case .vt100:
            return "A DEC VT100: the lowest common denominator."
        case .linux:
            return "The Linux console."
        }
    }

    /// Whether `COLORTERM=truecolor` goes along. It is a claim about 24-bit
    /// colour, so it is made only for types that claim colour at all.
    var advertisesTrueColor: Bool {
        switch self {
        case .xterm256, .ghostty, .screen256, .tmux256: return true
        case .xterm, .xtermColor, .vt220, .vt100, .linux: return false
        }
    }

    /// What to run on the host to teach it this type, when it can be taught
    /// and the name is not one every host ships. Nil otherwise.
    var installHint: String? {
        switch self {
        case .ghostty:
            return "infocmp -x xterm-ghostty | ssh HOST tic -x -"
        default:
            return nil
        }
    }

    /// The type a stored tag names; the default for anything this build does
    /// not know, such as a tag written by a newer one.
    static func resolve(_ tag: String) -> TerminalType {
        TerminalType(rawValue: tag) ?? .default
    }
}

/// Whether a terminfo entry exists on *this* Mac, looked for the way ncurses
/// looks: `<dir>/<first letter>/<name>`, and the hexadecimal-directory layout
/// macOS's own database uses (`<dir>/78/xterm-256color`).
///
/// Only a file's existence is checked. A file that exists and is damaged would
/// pass, which is acceptable here: this is a hint in a settings page, not a
/// gate in front of a launch.
enum TerminfoLookup {
    /// Where a terminfo database may be, most specific first. `TERMINFO`, when
    /// set, comes first because ncurses reads it first.
    static func directories(home: String, environment: [String: String]) -> [String] {
        var list: [String] = []
        if let own = environment["TERMINFO"], !own.isEmpty { list.append(own) }
        list.append(home + "/.terminfo")
        list.append(contentsOf: [
            "/usr/share/terminfo",
            "/usr/share/lib/terminfo",
            "/opt/homebrew/share/terminfo",
            "/opt/homebrew/opt/ncurses/share/terminfo",
            "/usr/local/share/terminfo",
            "/usr/local/opt/ncurses/share/terminfo",
            "/Applications/Ghostty.app/Contents/Resources/terminfo",
        ])
        return list
    }

    /// The file paths that would hold `name` under `directory`. Empty for a
    /// name that is not plainly a terminal name: it is joined into a path, so
    /// a slash or a dot-dot in it must never get that far.
    static func candidates(for name: String, in directory: String) -> [String] {
        guard isPlainName(name), let first = name.unicodeScalars.first else { return [] }
        let letter = String(Character(first))
        let hex = String(first.value, radix: 16)
        let base = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        return ["\(base)/\(letter)/\(name)", "\(base)/\(hex)/\(name)"]
    }

    /// `exists` is passed in so the rule is checked without a file system.
    static func isInstalled(
        _ name: String,
        directories: [String],
        exists: (String) -> Bool
    ) -> Bool {
        for directory in directories {
            for path in candidates(for: name, in: directory) where exists(path) {
                return true
            }
        }
        return false
    }

    /// This Mac's answer.
    static func isInstalledLocally(_ type: TerminalType) -> Bool {
        let list = directories(
            home: NSHomeDirectory(),
            environment: ProcessInfo.processInfo.environment
        )
        return isInstalled(type.termValue, directories: list) {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    private static func isPlainName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64, !name.hasPrefix(".") else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39)
                || (scalar.value >= 0x41 && scalar.value <= 0x5A)
                || (scalar.value >= 0x61 && scalar.value <= 0x7A)
                || "-_+.".unicodeScalars.contains(scalar)
        } && !name.contains("..")
    }
}
