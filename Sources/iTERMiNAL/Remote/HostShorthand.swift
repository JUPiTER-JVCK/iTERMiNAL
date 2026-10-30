import Foundation

/// Reads what a person types to connect somewhere — `user@host:2222`,
/// `ssh -p 2222 deploy@web`, or a pattern that names several hosts at once,
/// `web[1-3].example.com` or `db-{a,b}.lan` — into targets a saved connection
/// can be made from. Foundation only, so the rules are checked off a Mac.
///
/// What is accepted is deliberately narrow, and what is not is refused with a
/// sentence rather than guessed at: the text ends up as a host name in an `ssh`
/// command line, so every part passes the same alphabet checks a saved
/// connection's does.
enum HostShorthand {
    /// A pattern can name no more hosts than this: `[1-9999]` is a typo far
    /// more often than a request for ten thousand tabs.
    static let maxTargets = 32
    static let maxLength = 256

    struct Target: Equatable {
        var user: String?
        var host: String
        var port: Int?

        /// `user@host:port`, spelled the way it was typed.
        var display: String {
            let base = user.map { "\($0)@\(host)" } ?? host
            return port.map { "\(base):\($0)" } ?? base
        }
    }

    enum Outcome: Equatable {
        case targets([Target])
        /// A sentence for the person who typed it.
        case invalid(String)
    }

    static func parse(_ input: String) -> Outcome {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .invalid("Type a host, like user@host or web[1-3].example.com.") }
        guard text.count <= maxLength else { return .invalid("That is too long for a host.") }

        var tokens = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if tokens.first == "ssh" { tokens.removeFirst() }

        var port: Int?
        var user: String?
        var destination: String?
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            switch token {
            case "-p":
                guard index + 1 < tokens.count, let value = parsePort(tokens[index + 1]) else {
                    return .invalid("-p needs a port number, like -p 2222.")
                }
                port = value
                index += 2
            case "-l":
                guard index + 1 < tokens.count, isUserName(tokens[index + 1]) else {
                    return .invalid("-l needs a user name.")
                }
                user = tokens[index + 1]
                index += 2
            default:
                guard !token.hasPrefix("-") else {
                    return .invalid("“\(token)” is an ssh option this box doesn't take. Add it to the host's extra arguments instead.")
                }
                guard destination == nil else {
                    return .invalid("Only one host, or one pattern, at a time.")
                }
                destination = token
                index += 1
            }
        }
        guard let destination else { return .invalid("There is no host in that.") }

        var rest = destination
        var written: String?
        if let at = rest.firstIndex(of: "@") {
            written = String(rest[..<at])
            rest = String(rest[rest.index(after: at)...])
            guard let name = written, isUserName(name) else {
                return .invalid("“\(written ?? "")” isn't a user name ssh would accept.")
            }
        }
        // A port after the host. It is looked for only outside the pattern's
        // brackets and braces, so `web[1-3]:22` splits where it should.
        var hostPart = rest
        if let colon = lastTopLevelColon(in: rest) {
            guard let value = parsePort(String(rest[rest.index(after: colon)...])) else {
                return .invalid("“\(rest[rest.index(after: colon)...])” isn't a port.")
            }
            port = value
            hostPart = String(rest[..<colon])
        }
        guard !hostPart.isEmpty else { return .invalid("There is nothing before the port.") }

        let hosts: [String]
        switch expand(hostPart) {
        case .success(let list): hosts = list
        case .failure(let problem): return .invalid(problem.message)
        }
        for host in hosts {
            guard PortForward.isPlainHost(host) else {
                return .invalid("“\(host)” isn't a host name or address ssh would accept.")
            }
        }
        let chosenUser = written ?? user
        return .targets(hosts.map { Target(user: chosenUser, host: $0, port: port) })
    }

    // MARK: Patterns

    struct PatternProblem: Error {
        let message: String
    }

    /// Expands the first `[a-b]` or `{x,y}` in `text`, and then the rest of
    /// each result, so `r[1-2]c{a,b}` gives four. A bracket that is not a
    /// number range is left alone and fails the host check later.
    static func expand(_ text: String) -> Result<[String], PatternProblem> {
        var results = [text]
        var pass = 0
        while pass < 4 {
            var next: [String] = []
            var changed = false
            for item in results {
                switch expandOnce(item) {
                case .failure(let problem):
                    return .failure(problem)
                case .success(let parts):
                    if parts.count != 1 || parts[0] != item { changed = true }
                    next.append(contentsOf: parts)
                }
                if next.count > maxTargets {
                    return .failure(PatternProblem(message: "That names more than \(maxTargets) hosts."))
                }
            }
            results = next
            if !changed { break }
            pass += 1
        }
        return .success(results)
    }

    private static func expandOnce(_ text: String) -> Result<[String], PatternProblem> {
        let characters = Array(text)
        guard let open = characters.firstIndex(where: { $0 == "[" || $0 == "{" }) else {
            return .success([text])
        }
        let closer: Character = characters[open] == "[" ? "]" : "}"
        guard let close = characters[open...].firstIndex(of: closer) else {
            return .failure(PatternProblem(message: "“\(characters[open])” has no closing “\(closer)”."))
        }
        let prefix = String(characters[..<open])
        let inside = String(characters[(open + 1)..<close])
        let suffix = String(characters[(close + 1)...])

        var options: [String] = []
        if closer == "]" {
            let ends = inside.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            guard ends.count == 2,
                  !ends[0].isEmpty, !ends[1].isEmpty,
                  ends[0].allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  ends[1].allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  ends[0].count <= 4, ends[1].count <= 4,
                  let low = Int(ends[0]), let high = Int(ends[1]) else {
                return .failure(PatternProblem(message: "[\(inside)] isn't a number range like [1-3]."))
            }
            guard low <= high else {
                return .failure(PatternProblem(message: "[\(inside)] counts backwards."))
            }
            guard high - low < maxTargets else {
                return .failure(PatternProblem(message: "That names more than \(maxTargets) hosts."))
            }
            // A leading zero on the first number sets the width: [01-10].
            let width = ends[0].hasPrefix("0") ? ends[0].count : 0
            for value in low...high {
                let digits = String(value)
                options.append(String(repeating: "0", count: max(0, width - digits.count)) + digits)
            }
        } else {
            options = inside.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard options.count >= 2, !options.contains(where: \.isEmpty) else {
                return .failure(PatternProblem(message: "{\(inside)} needs two or more choices, like {a,b}."))
            }
            guard options.count <= maxTargets else {
                return .failure(PatternProblem(message: "That names more than \(maxTargets) hosts."))
            }
        }
        return .success(options.map { prefix + $0 + suffix })
    }

    // MARK: Pieces

    private static func lastTopLevelColon(in text: String) -> String.Index? {
        var depth = 0
        var found: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            switch text[index] {
            case "[", "{": depth += 1
            case "]", "}": depth = max(0, depth - 1)
            case ":": if depth == 0 { found = index }
            default: break
            }
            index = text.index(after: index)
        }
        return found
    }

    static func parsePort(_ text: String) -> Int? {
        guard !text.isEmpty, text.count <= 5, text.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              let value = Int(text), (1...65535).contains(value) else { return nil }
        return value
    }

    static func isUserName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64, !name.hasPrefix("-") else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39)
                || (scalar.value >= 0x41 && scalar.value <= 0x5A)
                || (scalar.value >= 0x61 && scalar.value <= 0x7A)
                || "._-".unicodeScalars.contains(scalar)
        }
    }
}
