import Foundation

/// Recognises output that says, in plain words, that something went wrong.
///
/// Strong markers only, each anchored to where such a message really appears —
/// the start or end of a line, behind a `tool:` prefix — because the text being
/// read can just as well be a file someone `cat`ted. A miss costs nothing: the
/// manual Explain and Fix actions work without any detection. A false alarm is
/// a chip the person can dismiss, so what it says must not claim a failure.
enum FailureSignature {
    struct Match: Equatable {
        /// A few words naming what was spotted, for a tooltip.
        let reason: String
        let line: String
    }

    /// The first line that carries a marker. `command` is the text that was
    /// typed: the shell echoes it before anything it prints, so the first line
    /// that contains it is that echo — not output, and a command that merely
    /// mentions "permission denied" has not hit it. Only that one line is set
    /// aside. Later lines that contain the command are the shell talking about
    /// it, and `zsh: command not found: nosuch` is exactly that.
    static func firstMatch(in lines: [String], excludingCommand command: String? = nil) -> Match? {
        let typed = command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var echoSkipped = typed.isEmpty
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if !echoSkipped, line.contains(typed) {
                echoSkipped = true
                continue
            }
            if let reason = reason(for: line) { return Match(reason: reason, line: line) }
        }
        return nil
    }

    private static func reason(for line: String) -> String? {
        let lower = line.lowercased()

        // Shells: "zsh: command not found: x", "bash: x: command not found".
        if lower.contains(": command not found") { return "command not found" }
        // "x: Permission denied", "zsh: permission denied: ./x", ssh's
        // "user@host: Permission denied (publickey)."
        if lower.hasSuffix(": permission denied") || lower.contains(": permission denied:")
            || lower.contains(": permission denied (") { return "permission denied" }
        if lower.hasSuffix(": no such file or directory") || lower.contains(": no such file or directory:")
            || lower.hasPrefix("zsh: no such file or directory") { return "no such file or directory" }

        if lower.hasPrefix("fatal:") || lower.hasPrefix("fatal error:") { return "a fatal error" }
        if line.hasPrefix("Traceback (most recent call last)") { return "a Python traceback" }
        if line.hasPrefix("npm ERR!") { return "an npm error" }
        if line.hasPrefix("panic:") || (line.hasPrefix("thread '") && line.contains("' panicked at")) {
            return "a panic"
        }
        if lower.contains("segmentation fault") { return "a crash" }
        if isMakeError(line) { return "a failed make" }
        if line.contains("BUILD FAILED") { return "a failed build" }
        return nil
    }

    /// `make: *** …` and `make[2]: *** …`.
    private static func isMakeError(_ line: String) -> Bool {
        guard line.hasPrefix("make") else { return false }
        var rest = line.dropFirst(4)
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            let digits = rest[rest.index(after: rest.startIndex)..<close]
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return false }
            rest = rest[rest.index(after: close)...]
        }
        return rest.hasPrefix(": ***")
    }
}

/// What a command printed, as opposed to what was already on screen.
enum OutputDiff {
    /// The lines of `current` that `baseline` does not account for, in order,
    /// blank lines left out.
    ///
    /// Counted rather than compared as sets: an error already on screen from
    /// before is not this command's, but the same error printed again is — it
    /// shows up one more time than it did, and the later copy is the new one.
    static func newLines(baseline: String, current: String) -> [String] {
        var remaining: [String: Int] = [:]
        for line in lines(of: baseline) { remaining[line, default: 0] += 1 }
        var fresh: [String] = []
        for line in lines(of: current) {
            if let count = remaining[line], count > 0 {
                remaining[line] = count - 1
            } else {
                fresh.append(line)
            }
        }
        return fresh
    }

    private static func lines(of text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            .filter { !$0.isEmpty }
    }
}
