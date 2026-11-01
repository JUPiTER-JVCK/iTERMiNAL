import Foundation

/// One variable a profile adds to its shell's environment.
struct ProfileVariable: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var value: String
}

/// A named way to start a local shell: which shell, with what arguments and
/// environment, where, and optionally a command to type once it is up.
///
/// Profiles live on this Mac only. They are not in an exported workspace
/// archive: a shell path, a variable such as `ZDOTDIR` and a startup command
/// can each make a program run when a tab opens, and nothing that arrives by
/// import is to do that. A tab remembers its profile by id, and a tab whose
/// profile is not here (a deleted one, or one from another Mac) opens as an
/// ordinary tab.
struct TerminalProfile: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    /// Path of the shell. Empty means the one chosen in Settings → General.
    var shellPath = ""
    /// Arguments for the shell, written as they would be on a command line.
    var shellArguments = ""
    var variables: [ProfileVariable] = []
    /// Where the shell starts. Empty means the default folder.
    var startDirectory = ""
    /// One line typed into the tab when the person opens it — never when a
    /// workspace is restored, and never in a split.
    var startupCommand = ""

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

extension TerminalProfile {
    /// The longest startup command accepted, in characters.
    static let maxStartupLength = 500

    /// What the profile is called in a list: its name, or a stand-in.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled profile" : trimmed
    }

    // MARK: Environment

    /// A name a shell would accept for a variable: letters, digits and
    /// underscores, not starting with a digit.
    static func isValidVariableName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first else { return false }
        func letter(_ scalar: Unicode.Scalar) -> Bool {
            (scalar.value >= 0x41 && scalar.value <= 0x5A) || (scalar.value >= 0x61 && scalar.value <= 0x7A) || scalar == "_"
        }
        func digit(_ scalar: Unicode.Scalar) -> Bool { scalar.value >= 0x30 && scalar.value <= 0x39 }
        return letter(first) && name.unicodeScalars.allSatisfy { letter($0) || digit($0) }
    }

    /// Whether a variable's value can be put in an environment: no NUL (it ends
    /// the string) and no line break.
    static func isUsableValue(_ value: String) -> Bool {
        !value.unicodeScalars.contains { $0.value == 0 || $0 == "\n" || $0 == "\r" }
    }

    /// The variables to add, in order, as they will be set: names trimmed,
    /// anything that is not a valid name or value left out, and a name given
    /// twice taking its last value.
    var environment: [(name: String, value: String)] {
        var result: [(name: String, value: String)] = []
        for variable in variables {
            let name = variable.name.trimmingCharacters(in: .whitespaces)
            guard Self.isValidVariableName(name), Self.isUsableValue(variable.value) else { continue }
            if let existing = result.firstIndex(where: { $0.name == name }) {
                result.remove(at: existing)
            }
            result.append((name, variable.value))
        }
        return result
    }

    /// The variables the editor shows as unusable, by what is wrong with each.
    var variableProblems: [UUID: String] {
        var problems: [UUID: String] = [:]
        for variable in variables {
            let name = variable.name.trimmingCharacters(in: .whitespaces)
            if name.isEmpty && variable.value.isEmpty { continue }
            if !Self.isValidVariableName(name) {
                problems[variable.id] = "A name is letters, digits and underscores, and does not start with a digit."
            } else if !Self.isUsableValue(variable.value) {
                problems[variable.id] = "A value cannot contain a line break."
            }
        }
        return problems
    }

    // MARK: Startup command

    /// The line to type once the shell is up, ending with Return — or nil when
    /// there is none, or it is more than one plain line. Nothing with a control
    /// character in it is typed: that would be a second command, or a key press,
    /// the person never wrote.
    var startupLine: String? {
        let trimmed = startupCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, startupProblem == nil else { return nil }
        return trimmed + "\r"
    }

    /// What is wrong with the startup command as written, for the editor.
    var startupProblem: String? {
        let trimmed = startupCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return "A startup command is a single line."
        }
        if trimmed.count > Self.maxStartupLength {
            return "A startup command is at most \(Self.maxStartupLength) characters."
        }
        return nil
    }

    // MARK: Where and what

    /// The start folder if it is written and exists, with `~` expanded.
    func resolvedStartDirectory(exists isFolder: (String) -> Bool) -> String? {
        let trimmed = startDirectory.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return isFolder(expanded) ? expanded : nil
    }

    /// The shell to run in place of the default, if one is written.
    var shellOverride: String? {
        let trimmed = shellPath.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// One line on what the profile does, for a list: its shell, folder,
    /// variables, and whether it types a command.
    var summary: String {
        var parts: [String] = []
        if let shell = shellOverride { parts.append((shell as NSString).lastPathComponent) }
        let folder = startDirectory.trimmingCharacters(in: .whitespaces)
        if !folder.isEmpty { parts.append(folder) }
        let count = environment.count
        if count > 0 { parts.append(count == 1 ? "1 variable" : "\(count) variables") }
        if startupLine != nil { parts.append("runs a command") }
        return parts.isEmpty ? "Same as the default" : parts.joined(separator: " · ")
    }

    /// "Profile 1", "Profile 2"…: the first not already used.
    static func newName(avoiding existing: [String]) -> String {
        let used = Set(existing.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        var number = 1
        while used.contains("profile \(number)") { number += 1 }
        return "Profile \(number)"
    }
}
