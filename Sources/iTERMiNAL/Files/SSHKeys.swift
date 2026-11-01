import Foundation

/// SSH keys as far as this app looks at them: the public half, and what the
/// agent says it holds. Foundation only, so the reading and the commands are
/// checked off a Mac.
///
/// Two rules shape everything here:
///
/// - **Private keys are never opened.** A key is listed from its `.pub` file;
///   its private file is looked at only to see whether it is there and whether
///   its permissions would make ssh refuse it.
/// - **Nothing here asks for a passphrase, or runs a command that would.**
///   Adding a key to the agent and making a new one are commands this file
///   writes and the app *types into a tab*, where `ssh-add` and `ssh-keygen`
///   ask for the passphrase themselves, and where Return is the person's.
enum SSHKeys {
    // MARK: Fingerprints

    /// One key as `ssh-keygen -l` and `ssh-add -l` print it:
    /// `256 SHA256:… me@laptop (ED25519)`.
    struct Fingerprint: Equatable {
        var bits: Int
        /// `SHA256:` and the 43 characters after it.
        var hash: String
        /// Empty for a key with none.
        var comment: String
        /// `ED25519`, `RSA`, `ECDSA`, `ED25519-SK`…
        var type: String
    }

    /// A line longer than this is not one an ssh tool wrote.
    static let maxLineLength = 1024

    /// Reads one line of `ssh-keygen -l` or `ssh-add -l`, or nil if it is not
    /// one. Strict about the parts that are structure — the bit count is one to
    /// five digits, the hash is `SHA256:` and exactly 43 base64 characters, the
    /// type is a short upper-case word in the last pair of brackets — and
    /// forgiving only about the comment, which is whatever the key's owner
    /// wrote, brackets and spaces included (`work laptop (2023) (RSA)`).
    static func parseFingerprint(_ text: String) -> Fingerprint? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, line.utf8.count <= maxLineLength else { return nil }
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3 else { return nil }

        guard parts[0].utf8.count <= 5, parts[0].utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              let bits = Int(parts[0]), bits >= 1 else { return nil }

        let hash = String(parts[1])
        let prefix = "SHA256:"
        guard hash.hasPrefix(prefix) else { return nil }
        let encoded = hash.dropFirst(prefix.count)
        guard encoded.utf8.count == 43, encoded.utf8.allSatisfy(isBase64Byte) else { return nil }

        let rest = String(parts[2])
        guard rest.hasSuffix(")"), let open = rest.lastIndex(of: "(") else { return nil }
        let type = String(rest[rest.index(after: open)..<rest.index(before: rest.endIndex)])
        guard (1...24).contains(type.utf8.count),
              type.utf8.allSatisfy({ ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D })
        else { return nil }

        var comment = String(rest[..<open]).trimmingCharacters(in: .whitespaces)
        // What ssh-keygen prints for a key that has none.
        if comment == "no comment" { comment = "" }
        return Fingerprint(bits: bits, hash: hash, comment: displayable(comment), type: type)
    }

    private static func isBase64Byte(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
            || byte == 0x2B || byte == 0x2F
    }

    /// Text from a file, fit to show: control characters become spaces and it
    /// is cut at 200 characters.
    private static func displayable(_ text: String) -> String {
        var cleaned = ""
        for scalar in text.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F {
                cleaned += " "
            } else {
                cleaned.unicodeScalars.append(scalar)
            }
        }
        return String(cleaned.prefix(200))
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
    }

    // MARK: The agent

    enum AgentState: Equatable {
        /// It holds these keys.
        case keys([Fingerprint])
        /// It is there and holds nothing.
        case empty
        /// There is no agent to ask, or the socket does not answer.
        case unreachable
        /// Anything else: a timeout, an exit status or an output not understood.
        case failed
    }

    /// What `ssh-add -l` said. Its exit status is the answer — 0 with keys
    /// listed, 1 with none, 2 when there is no agent — and the words are
    /// checked too, so a status 1 for some other reason is not read as an
    /// agent with nothing in it.
    static func agentState(status: Int32, output: String, errorOutput: String) -> AgentState {
        switch status {
        case 0:
            let keys = output.split(whereSeparator: \.isNewline).compactMap { parseFingerprint(String($0)) }
            return keys.isEmpty ? .failed : .keys(keys)
        case 1:
            return output.contains("no identities") || errorOutput.contains("no identities") ? .empty : .failed
        case 2:
            return .unreachable
        default:
            return .failed
        }
    }

    /// Whether the key with this fingerprint is held, or nil when the agent
    /// could not say.
    static func isLoaded(_ fingerprint: Fingerprint, in agent: AgentState) -> Bool? {
        switch agent {
        case .keys(let held): return held.contains { $0.hash == fingerprint.hash }
        case .empty: return false
        case .unreachable, .failed: return nil
        }
    }

    // MARK: Which keys there are

    /// What is known of the private file beside a `.pub`.
    enum PrivateKey: Equatable {
        case missing
        case ok
        /// Readable or writable by others, which ssh refuses ("UNPROTECTED
        /// PRIVATE KEY FILE"). `mode` is the permission bits, e.g. `0o644`.
        case tooOpen(mode: Int)
    }

    /// The private file's state from what `stat` said about it.
    static func privateKey(isFile: Bool, mode: Int) -> PrivateKey {
        guard isFile else { return .missing }
        return mode & 0o077 == 0 ? .ok : .tooOpen(mode: mode & 0o777)
    }

    struct Entry: Equatable {
        /// The file name without `.pub`: `id_ed25519`.
        var name: String
        var privateKey: PrivateKey
        var publicFile: String { name + ".pub" }
    }

    struct Listing: Equatable {
        var entries: [Entry]
        /// Keys past `maxEntries`, not listed.
        var omitted: Int
    }

    /// Each key is one `ssh-keygen` to read, so the number is bounded.
    static let maxEntries = 50

    /// The keys among the files of `~/.ssh`: every `.pub` except an OpenSSH
    /// certificate (`-cert.pub`), whose name has nothing odd in it, in name
    /// order with capitals not first.
    static func listing(fileNames: [String], keyState: (String) -> PrivateKey) -> Listing {
        var names: [String] = []
        for file in fileNames where file.hasSuffix(".pub") && !file.hasSuffix("-cert.pub") {
            let base = String(file.dropLast(4))
            if isPlainName(base) { names.append(base) }
        }
        names.sort { lhs, rhs in
            let (a, b) = (lhs.lowercased(), rhs.lowercased())
            return a == b ? lhs < rhs : a < b
        }
        return Listing(
            entries: names.prefix(maxEntries).map { Entry(name: $0, privateKey: keyState($0)) },
            omitted: max(0, names.count - maxEntries)
        )
    }

    /// A file name that is safe to put in a path: not empty, not a directory
    /// reference, no slash, no control character.
    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 200 && name != "." && name != ".."
            && !name.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || $0 == "/" }
    }

    // MARK: A public key, for copying

    static let publicKeyTypes: Set<String> = [
        "ssh-ed25519", "ssh-rsa", "ssh-dss",
        "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521",
        "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-nistp256@openssh.com",
    ]

    /// The most of a `.pub` file that is read: a key is a few hundred bytes.
    static let maxPublicFileBytes = 16_384

    /// The key line in the text of a `.pub` file — the first line that is not
    /// blank — if it reads as one: a known key type, the base64 of the key, and
    /// whatever comment follows. Nothing else is put on a clipboard as a key.
    static func publicKeyLine(from text: String) -> String? {
        guard text.utf8.count <= maxPublicFileBytes else { return nil }
        guard let line = text.components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty }) else { return nil }
        guard !line.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, publicKeyTypes.contains(String(parts[0])),
              (16...maxPublicFileBytes).contains(parts[1].utf8.count),
              parts[1].utf8.allSatisfy({ isBase64Byte($0) || $0 == 0x3D }) else { return nil }
        return line
    }

    // MARK: Commands, typed into a tab and never run from here

    /// `~/.ssh/<name>` as a word for a shell: `~/` is left for the shell to
    /// expand and the rest is quoted only if it needs it.
    static func shellPath(forKey name: String) -> String {
        "~/" + RemoteProblem.shellQuoted(".ssh/" + name)
    }

    /// Puts the key in the agent, and its passphrase in the keychain if the
    /// person gives one — asked by `ssh-add` in the tab.
    static func addToAgentCommand(keyName: String) -> String {
        "ssh-add --apple-use-keychain \(shellPath(forKey: keyName))"
    }

    /// For a private key ssh refuses because others can read it.
    static func fixPermissionsCommand(keyName: String) -> String {
        "chmod 600 \(shellPath(forKey: keyName))"
    }

    enum KeyKind: String, CaseIterable, Identifiable {
        case ed25519
        case rsa

        var id: String { rawValue }

        var label: String {
            switch self {
            case .ed25519: return "Ed25519 (recommended)"
            case .rsa: return "RSA, 4096 bits (for older servers)"
            }
        }

        var defaultName: String {
            switch self {
            case .ed25519: return "id_ed25519"
            case .rsa: return "id_rsa"
            }
        }

        /// The `ssh-keygen` options that choose it.
        var options: String {
            switch self {
            case .ed25519: return "-t ed25519"
            case .rsa: return "-t rsa -b 4096"
            }
        }
    }

    enum GenerateProblem: Error, Equatable {
        case emptyName
        case nameTooLong
        case nameCharacters
        case nameExists
        case commentTooLong
        case commentCharacters

        var message: String {
            switch self {
            case .emptyName: return "Give the key a file name."
            case .nameTooLong: return "That file name is too long."
            case .nameCharacters: return "Use letters, digits, dots, dashes and underscores, starting with a letter or digit, and not ending in .pub."
            case .nameExists: return "There is already a file of that name in ~/.ssh. Pick another, so nothing is overwritten."
            case .commentTooLong: return "That comment is too long."
            case .commentCharacters: return "The comment can't contain control characters."
            }
        }
    }

    static let maxNameLength = 64
    static let maxCommentLength = 200

    /// The `ssh-keygen` line that makes a key called `name` in `~/.ssh`.
    ///
    /// `existing` is every file name already in `~/.ssh`: a name that is taken,
    /// with or without `.pub`, is refused here, so the line never has to ask
    /// whether to overwrite. The comment is optional; without one ssh-keygen
    /// uses `user@host`. No passphrase appears anywhere: `ssh-keygen` asks for
    /// it itself, in the tab.
    static func generateCommand(
        kind: KeyKind,
        name rawName: String,
        comment rawComment: String,
        existing: Set<String>
    ) -> Result<String, GenerateProblem> {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return .failure(.emptyName) }
        if name.utf8.count > maxNameLength { return .failure(.nameTooLong) }
        let allowed = name.unicodeScalars.allSatisfy { isAlphanumeric($0) || $0 == "." || $0 == "-" || $0 == "_" }
        let startsPlain = name.unicodeScalars.first.map { isAlphanumeric($0) } ?? false
        guard allowed, startsPlain, !name.lowercased().hasSuffix(".pub") else { return .failure(.nameCharacters) }
        if existing.contains(name) || existing.contains(name + ".pub") { return .failure(.nameExists) }

        let comment = rawComment.trimmingCharacters(in: .whitespaces)
        if comment.count > maxCommentLength { return .failure(.commentTooLong) }
        if comment.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return .failure(.commentCharacters)
        }

        var line = "ssh-keygen \(kind.options) -f \(shellPath(forKey: name))"
        if !comment.isEmpty { line += " -C \(RemoteProblem.shellQuoted(comment))" }
        return .success(line)
    }

    /// `id_ed25519`, or `id_ed25519_2`, `_3`… when that is taken.
    static func suggestedName(for kind: KeyKind, existing: Set<String>) -> String {
        func free(_ name: String) -> Bool { !existing.contains(name) && !existing.contains(name + ".pub") }
        let base = kind.defaultName
        if free(base) { return base }
        var number = 2
        while !free("\(base)_\(number)"), number < 1000 { number += 1 }
        return "\(base)_\(number)"
    }

    /// `user@Computer-Name`, for the comment of a new key: letters, digits, dots,
    /// dashes and underscores kept, a space becoming a dash, everything else
    /// (an apostrophe in a computer's name, say) left out.
    static func defaultComment(user: String, computerName: String?) -> String {
        func clean(_ text: String) -> String {
            var out = ""
            for scalar in text.unicodeScalars {
                if isAlphanumeric(scalar) || scalar == "." || scalar == "-" || scalar == "_" {
                    out.unicodeScalars.append(scalar)
                } else if scalar == " ", !out.hasSuffix("-") {
                    out += "-"
                }
            }
            return out.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        }
        let who = clean(user)
        let host = clean(computerName ?? "")
        return (who.isEmpty ? "me" : who) + "@" + (host.isEmpty ? "mac" : host)
    }
}
