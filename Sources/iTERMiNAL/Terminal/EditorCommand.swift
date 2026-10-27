import Foundation

/// Which text editor "Edit in Terminal" opens a file in, and the command line
/// that does it. Foundation only, so what may and may not reach a shell is
/// checked off a Mac; `WorkspaceStore.editFile` types the line into a new tab.
enum EditorChoice: String, CaseIterable, Identifiable, Codable {
    /// The first of Helix, Neovim, Vim and Nano that this Mac has.
    case automatic
    case helix
    case neovim
    case vim
    case nano
    /// A command the person writes, with the file added at the end.
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .helix: return "Helix"
        case .neovim: return "Neovim"
        case .vim: return "Vim"
        case .nano: return "Nano"
        case .custom: return "Custom command"
        }
    }

    /// The program names looked for, in order.
    var candidates: [String] {
        switch self {
        case .automatic: return ["hx", "helix", "nvim", "vim", "nano"]
        case .helix: return ["hx", "helix"]
        case .neovim: return ["nvim"]
        case .vim: return ["vim"]
        case .nano: return ["nano"]
        case .custom: return []
        }
    }

    /// How to get it, for the ones macOS does not ship. Vim and Nano come with
    /// the system; the other two do not.
    var installHint: String? {
        switch self {
        case .helix: return "brew install helix"
        case .neovim: return "brew install neovim"
        default: return nil
        }
    }
}

enum EditorCommand {
    enum Problem: Error, Equatable {
        /// Nothing of that name on this Mac; the label is what was asked for.
        case notInstalled(label: String, hint: String?)
        /// The file's path cannot safely be typed: it is not absolute, or has a
        /// control character in it.
        case unusablePath
        case emptyCustom
        case unusableCustom

        /// A sentence for the person.
        var message: String {
            switch self {
            case .notInstalled(let label, let hint):
                let how = hint.map { " Install it with \($0)." } ?? ""
                return "\(label) isn't installed on this Mac.\(how) Or choose another editor under Settings → General."
            case .unusablePath:
                return "That file's name has a character in it that cannot be typed into a terminal safely."
            case .emptyCustom:
                return "No editor command is set. Write one under Settings → General → Editor."
            case .unusableCustom:
                return "The editor command has a character in it that cannot be typed into a terminal safely."
            }
        }
    }

    /// The line to type into a shell, ending with Return, that opens `path` in
    /// the chosen editor — or why not.
    ///
    /// `locate` finds a program by name and returns where it is, or nil; it is
    /// a parameter so the choice of editor can be checked without one being
    /// installed.
    ///
    /// The line is typed into a live shell, so nothing in it is left to chance:
    /// the path must be absolute (so it cannot start with a dash and be read as
    /// an option) and free of control characters (a newline in a file name
    /// would end the line early and run what follows), and is single-quoted;
    /// the program is quoted from the absolute path found for it. A custom
    /// command is the person's own and goes as written, but only on one line.
    static func line(
        choice: EditorChoice,
        custom: String,
        path: String,
        locate: (String) -> String?
    ) -> Result<String, Problem> {
        guard path.hasPrefix("/"), !hasControlCharacter(path) else { return .failure(.unusablePath) }
        let file = quote(path)

        if choice == .custom {
            let command = custom.trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { return .failure(.emptyCustom) }
            guard !hasControlCharacter(command) else { return .failure(.unusableCustom) }
            return .success("\(command) \(file)\r")
        }
        for name in choice.candidates {
            if let program = locate(name), program.hasPrefix("/"), !hasControlCharacter(program) {
                return .success("\(quote(program)) \(file)\r")
            }
        }
        return .failure(.notInstalled(label: choice.label, hint: choice.installHint))
    }

    /// Whether `text` has anything a terminal would act on rather than show.
    static func hasControlCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || ($0.value >= 0x80 && $0.value < 0xA0) }
    }

    /// `value` as one shell word: as it is when nothing in it is special,
    /// single-quoted when something is.
    static func quote(_ value: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%+=:,./_-")
        if !value.isEmpty, value.unicodeScalars.allSatisfy({ safe.contains($0) }) { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
