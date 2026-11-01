import Foundation

/// What a code block in the assistant's reply becomes when it is saved to a
/// file: a name to offer, and the text to write. Foundation only, so the
/// choices are checked off a Mac.
///
/// Saving is the person's: a save panel asks where, and the file is written as
/// plain text and **not made executable** — `chmod +x` is a step to take after
/// reading it, not something a reply gets to do.
enum ScriptFile {
    /// The extension for a fence's language tag; `txt` for one not known, and
    /// `sh` for a block with no tag at all, which is shown as something for a shell.
    static func fileExtension(forLanguage language: String?) -> String {
        guard let language, !language.isEmpty else { return "sh" }
        switch language.lowercased() {
        case "sh", "bash", "shell", "console", "terminal", "shell-session", "shellsession", "sh-session": return "sh"
        case "zsh": return "zsh"
        case "fish": return "fish"
        case "python", "python3", "py": return "py"
        case "javascript", "js", "node": return "js"
        case "typescript", "ts": return "ts"
        case "ruby", "rb": return "rb"
        case "perl", "pl": return "pl"
        case "swift": return "swift"
        case "go", "golang": return "go"
        case "rust", "rs": return "rs"
        case "c": return "c"
        case "cpp", "c++": return "cpp"
        case "json": return "json"
        case "yaml", "yml": return "yml"
        case "toml": return "toml"
        case "sql": return "sql"
        case "html": return "html"
        case "css": return "css"
        case "xml": return "xml"
        case "markdown", "md": return "md"
        case "ini": return "ini"
        case "dockerfile": return "dockerfile"
        default: return "txt"
        }
    }

    /// `script.sh`, `script.py`…
    static func suggestedName(forLanguage language: String?) -> String {
        "script." + fileExtension(forLanguage: language)
    }

    /// The bytes to write: the block, with a newline at the end if it has none
    /// (a file that does not end in one is a small, common annoyance), and
    /// nothing else added — no shebang, no header.
    static func contents(of block: String) -> String {
        block.hasSuffix("\n") ? block : block + "\n"
    }
}
