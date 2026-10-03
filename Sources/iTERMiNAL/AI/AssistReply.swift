import Foundation

/// A model's reply, split into the prose around it and the code blocks in it,
/// so a command can be offered as something to put in the input — and a
/// snippet in another language can be offered as something to copy, and not
/// as something to run.
enum AssistReply {
    enum Segment: Equatable {
        case prose(String)
        /// `language` is the fence's tag, lower-cased; nil when it had none.
        case code(language: String?, text: String)
    }

    /// Fenced blocks. A block still open at the end — a reply cut off in the
    /// middle of one — runs to the end.
    static func segments(of reply: String) -> [Segment] {
        var segments: [Segment] = []
        var prose: [String] = []
        var code: [String] = []
        var language: String?
        var inCode = false

        func flushProse() {
            let text = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { segments.append(.prose(text)) }
            prose = []
        }
        func flushCode() {
            let text = commands(in: code.joined(separator: "\n")).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { segments.append(.code(language: language, text: text)) }
            code = []
            language = nil
        }

        for line in reply.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    flushCode()
                    inCode = false
                } else if trimmed.count > 6, trimmed.hasSuffix("```") {
                    // A block opened and closed on one line.
                    flushProse()
                    code = [String(trimmed.dropFirst(3).dropLast(3))]
                    flushCode()
                } else {
                    flushProse()
                    inCode = true
                    let tag = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    language = tag.split(separator: " ").first.map { $0.lowercased() }
                }
                continue
            }
            if inCode { code.append(line) } else { prose.append(line) }
        }
        if inCode { flushCode() } else { flushProse() }
        return segments
    }

    /// Whether a block is something to put in a shell: tagged as one, or not
    /// tagged at all.
    static func isShell(language: String?) -> Bool {
        guard let language, !language.isEmpty else { return true }
        return ["sh", "bash", "zsh", "shell", "fish", "console", "terminal", "shell-session", "shellsession", "sh-session"]
            .contains(language)
    }

    /// The commands in a block that shows a session: when some lines start with
    /// a `$ ` prompt, those are the commands and the other lines are what they
    /// printed. A block with no prompts is all commands.
    static func commands(in block: String) -> String {
        let lines = block.components(separatedBy: "\n")
        let prompted = lines.filter { $0.hasPrefix("$ ") }
        guard !prompted.isEmpty else { return block }
        return prompted.map { String($0.dropFirst(2)) }.joined(separator: "\n")
    }
}
