import Foundation

/// A saved command or snippet: a name, an optional note, and the text that goes
/// into the composer's input when it is chosen.
///
/// Choosing one only fills the input. It is never sent for you: Return in the
/// input is still the one thing that runs anything, so what will run is on the
/// screen, and the warnings about risky commands apply to it as to anything typed.
struct Skill: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    /// A line on what it is for, shown in lists.
    var note = ""
    /// What goes into the input. May be several lines.
    var text = ""

    init(id: UUID = UUID(), name: String, note: String = "", text: String = "") {
        self.id = id
        self.name = name
        self.note = note
        self.text = text
    }
}

extension Skill {
    /// The most that one skill can hold, in characters.
    static let maxTextLength = 4_000

    // MARK: The text

    /// The text as it will be put in the input: line breaks made `\n`, and no
    /// blank lines or spaces at either end.
    static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether `text` can be put in an input: no NUL, no escape, no other
    /// control character — a tab and a line break are the only two allowed.
    static func isUsableText(_ text: String) -> Bool {
        !text.unicodeScalars.contains { scalar in
            if scalar == "\n" || scalar == "\t" { return false }
            return scalar.value < 0x20 || scalar.value == 0x7F
        }
    }

    /// What is wrong with the text as written, for the editor.
    var problem: String? {
        let text = Self.normalized(self.text)
        if text.isEmpty { return "A skill needs some text." }
        if !Self.isUsableText(text) { return "The text has a control character in it, which cannot be typed." }
        if text.count > Self.maxTextLength { return "The text is at most \(Self.maxTextLength) characters." }
        return nil
    }

    /// The text to put in the input, or nil when there is none or it is not
    /// usable. Never anything with a control character in it.
    var inputText: String? {
        problem == nil ? Self.normalized(text) : nil
    }

    /// What the input holds after `snippet` is added to `draft`. An empty input
    /// takes it as it is. Anything already there stays, with the snippet after
    /// it — a space between on the same line, or straight after a line break —
    /// so nothing typed is lost and the whole of what will run is in view.
    static func insertion(_ snippet: String, into draft: String) -> String {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return snippet }
        guard let last = draft.last else { return snippet }
        return last.isWhitespace ? draft + snippet : draft + " " + snippet
    }

    // MARK: How it reads

    /// Its name, or when there is none the start of its text.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let first = Self.firstLine(of: Self.normalized(text), limit: 40)
        return first.isEmpty ? "Untitled skill" : first
    }

    /// One line for a list: the note, or the start of the text.
    var summary: String {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return Self.firstLine(of: Self.normalized(text), limit: 60)
    }

    private static func firstLine(of text: String, limit: Int) -> String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let clean = line.trimmingCharacters(in: .whitespaces)
        return clean.count > limit ? String(clean.prefix(limit - 1)) + "…" : clean
    }

    /// "Skill 1", "Skill 2"…: the first not already used.
    static func newName(avoiding existing: [String]) -> String {
        let used = Set(existing.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        var number = 1
        while used.contains("skill \(number)") { number += 1 }
        return "Skill \(number)"
    }
}
