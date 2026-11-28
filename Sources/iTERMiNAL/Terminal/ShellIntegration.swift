import Foundation

// MARK: - The zsh script
//
// Kept at column 0 and as a raw string on purpose: what is here is exactly what
// lands on disk, with nothing for the Swift compiler to rewrite, and a script in
// `scripts/shell-integration-check` can lift the same text out to run it.
//
// iTERMiNAL starts zsh with ZDOTDIR pointing at a folder holding this one file,
// which zsh therefore reads first. It adds two prompt hooks, then puts ZDOTDIR
// back at once and loads the person's own .zshenv, so zsh reads every other
// startup file from where it really is, as if this folder had never been
// involved — which matters, because the system's own files (/etc/zshrc, for
// one) may use ZDOTDIR to decide where the history file goes, and must not be
// sent to this folder. Nothing in the home folder is changed.

private let zshEnvScript = #"""
# iTERMiNAL shell integration (zsh). Written by iTERMiNAL; edits here are overwritten.
#
# iTERMiNAL started this shell with ZDOTDIR pointing at this folder, so zsh reads this file
# first. It adds two prompt hooks, puts ZDOTDIR back exactly as you had it, and loads your own
# .zshenv. zsh then reads every other startup file of yours from where it really is, as if this
# folder had never been involved. Nothing in your home folder is changed.

# Tell iTERMiNAL when a command starts and what status it ended with (OSC 633: C, D;status),
# and when a prompt is about to be drawn (A). Added before anything of yours has run, so no
# option you set later can reach this code, and zsh keeps $? as it was for each hook, so a
# precmd of your own cannot change what is reported.
#
# Just before C, the first line of the command as you typed it (E), so a command brought back
# with the up arrow or finished with Tab is known exactly. It carries a code iTERMiNAL made
# for this shell alone, which is taken out of the environment below, so nothing this shell
# starts inherits it and nothing printed to the terminal can pass for it. Each byte outside
# plain ASCII is written as \xHH and a backslash as \\.
if [[ -o interactive ]]; then
  typeset -g __iterminal_ran= __iterminal_nonce=${ITERMINAL_NONCE-}
  __iterminal_preexec() {
    emulate -L zsh
    __iterminal_ran=1
    if [[ -n $__iterminal_nonce && -n $1 ]]; then
      setopt extended_glob
      local line=${${1%%$'\n'*}[1,1000]}
      local LC_ALL=C
      line=${line//\\/\\\\}
      line=${line//(#m)[^ -~]/\\x${(l:2::0:)$(( [##16] #MATCH ))}}
      print -rn -- $'\e]633;E;'$__iterminal_nonce';'$line$'\a'
    fi
    print -n -- $'\e]633;C\a'
  }
  __iterminal_precmd() {
    local ec=$?
    emulate -L zsh
    if [[ -n $__iterminal_ran ]]; then
      print -n -- $'\e]633;D;'$ec$'\a'
      __iterminal_ran=
    fi
    print -n -- $'\e]633;A\a'
  }
  precmd_functions=(__iterminal_precmd ${precmd_functions:#__iterminal_precmd})
  preexec_functions=(__iterminal_preexec ${preexec_functions:#__iterminal_preexec})
fi

# Hand ZDOTDIR back before anything else reads it, and keep the code to this shell.
unset ITERMINAL_NONCE
if [[ -n ${ITERMINAL_ZDOTDIR_ORIG+x} ]]; then
  export ZDOTDIR=$ITERMINAL_ZDOTDIR_ORIG
else
  unset ZDOTDIR
fi
unset ITERMINAL_ZDOTDIR_ORIG
[[ -r ${ZDOTDIR:-$HOME}/.zshenv ]] && builtin source "${ZDOTDIR:-$HOME}/.zshenv"
"""#

// MARK: - Shell integration

/// What a shell that reports its own commands tells iTERMiNAL, and how a zsh is
/// started so that it does. Foundation only, so the reading and the launch
/// arrangements are checked off a Mac; the script above is run in a real zsh by
/// `scripts/shell-integration-check`.
///
/// The marks are OSC 633, the code VS Code's shell integration uses. SwiftTerm
/// handles OSC 133 itself and keeps only the prompt's shape, not the exit
/// status — and a handler registered for 133 would replace the one it has, with
/// no way to pass on to it — so the status travels in a code SwiftTerm leaves
/// alone.
///
/// The command line is signed with a code made for each shell (`makeNonce`),
/// as VS Code's is: anything printed to the terminal — a file shown with `cat`,
/// a program on the far end of ssh — can look like a mark, and a line said to
/// be the command decides which keys the quick reference offers to type.
enum ShellIntegration {
    static let oscCode = 633

    /// One thing the shell said.
    enum Mark: Equatable {
        /// A prompt is about to be drawn: nothing is running.
        case promptStart
        /// A command is about to run.
        case commandStart
        /// The command ended; nil when the shell gave no usable status.
        case commandFinished(exitCode: Int?)
        /// The command about to run: its first line, exactly as typed, with
        /// any `!!` already expanded and its aliases not. Sent just before
        /// `commandStart`, only by a shell holding the code (`parse(_:nonce:)`).
        case commandLine(String)
    }

    /// Reads what follows `633;` in the sequence: `A`, `C`, `D`, `D;<status>`,
    /// or `E;<nonce>;<line>` from a shell given `nonce`.
    ///
    /// Strict, because anything a program prints can look like this: the status
    /// is one to three digits and no more than 255, and anything else — another
    /// letter, extra fields, trailing text — is nothing at all. A command line
    /// is believed only with this shell's own code (see `commandLine(in:nonce:)`).
    static func parse(_ data: ArraySlice<UInt8>, nonce: String? = nil) -> Mark? {
        let bytes = Array(data)
        guard let first = bytes.first else { return nil }
        switch first {
        case UInt8(ascii: "A"):
            return bytes.count == 1 ? .promptStart : nil
        case UInt8(ascii: "C"):
            return bytes.count == 1 ? .commandStart : nil
        case UInt8(ascii: "D"):
            if bytes.count == 1 { return .commandFinished(exitCode: nil) }
            guard bytes.count >= 3, bytes.count <= 5, bytes[1] == UInt8(ascii: ";") else { return nil }
            let digits = bytes[2...]
            guard digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                  let code = Int(String(decoding: digits, as: UTF8.self)), code <= 255 else { return nil }
            return .commandFinished(exitCode: code)
        case UInt8(ascii: "E"):
            return commandLine(in: bytes, nonce: nonce).map(Mark.commandLine)
        default:
            return nil
        }
    }

    /// The most a command line may take on the wire. The hook sends at most a
    /// thousand characters: at four bytes each, and four characters for each
    /// byte once written as `\xHH`, with the code and room to spare.
    static let maximumCommandLineBytes = 16_500

    /// The line in `E;<nonce>;<line>`, or nil. Nil unless `nonce` is given and
    /// is the one there; unless the line is plain ASCII throughout, with `\\`
    /// for a backslash and `\xHH` for any other byte, as the hook writes it —
    /// SwiftTerm ends a sequence at some bytes of UTF-8 (`Ü` has one), so the
    /// hook writes none raw; and unless those bytes are UTF-8 for a line with
    /// something in it and no control characters. A tab, which can only have
    /// been typed on purpose, is read as a space.
    static func commandLine(in bytes: [UInt8], nonce: String?) -> String? {
        guard let nonce, !nonce.isEmpty else { return nil }
        let head = Array("E;\(nonce);".utf8)
        guard bytes.count > head.count, bytes.count <= maximumCommandLineBytes,
              bytes.starts(with: head) else { return nil }
        var decoded: [UInt8] = []
        var index = head.count
        while index < bytes.count {
            let byte = bytes[index]
            guard byte >= 0x20, byte <= 0x7E else { return nil }
            guard byte == UInt8(ascii: "\\") else {
                decoded.append(byte)
                index += 1
                continue
            }
            guard index + 1 < bytes.count else { return nil }
            switch bytes[index + 1] {
            case UInt8(ascii: "\\"):
                decoded.append(byte)
                index += 2
            case UInt8(ascii: "x"):
                guard index + 3 < bytes.count,
                      let high = hexDigit(bytes[index + 2]), let low = hexDigit(bytes[index + 3]) else { return nil }
                decoded.append(high << 4 | low)
                index += 4
            default:
                return nil
            }
        }
        guard let text = String(bytes: decoded, encoding: .utf8) else { return nil }
        var line = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\t" {
                line.append(" ")
            } else if scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) {
                return nil
            } else {
                line.append(scalar)
            }
        }
        let result = String(line)
        return result.trimmingCharacters(in: .whitespaces).isEmpty ? nil : result
    }

    private static func hexDigit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    /// A code for one shell to sign its command lines with: 128 bits from the
    /// system's secure generator, as 32 lowercase hex digits. Made afresh each
    /// time a shell is started, and handed to it in its environment, which its
    /// first file takes it back out of.
    static func makeNonce() -> String {
        var generator = SystemRandomNumberGenerator()
        let digits = Array("0123456789abcdef")
        var text = ""
        for _ in 0..<16 {
            let byte = UInt8.random(in: .min ... .max, using: &generator)
            text.append(digits[Int(byte >> 4)])
            text.append(digits[Int(byte & 0x0F)])
        }
        return text
    }

    /// A command that has ended.
    struct Finished: Equatable {
        var exitCode: Int?
        /// How long it ran, when its start was seen.
        var seconds: Double?
    }

    /// Follows the marks of one shell: when a command began, and so how long it
    /// ran when it ended.
    struct CommandTracker {
        private(set) var runningSince: Date?

        /// A mark, at the time it arrived. Returns the command it ended, if it
        /// ended one.
        mutating func handle(_ mark: Mark, at now: Date) -> Finished? {
            switch mark {
            case .promptStart:
                // A prompt means nothing is running, however the last command
                // came to end without a status.
                runningSince = nil
                return nil
            case .commandStart:
                runningSince = now
                return nil
            case .commandFinished(let exitCode):
                defer { runningSince = nil }
                let seconds = runningSince.map { max(0, now.timeIntervalSince($0)) }
                return Finished(exitCode: exitCode, seconds: seconds)
            case .commandLine:
                // What the command is, not when: the start is the C after it.
                return nil
            }
        }
    }

    // MARK: Words

    /// `45s`, `2m 14s`, `1h 3m` — whole units, the larger first.
    static func durationText(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0s" }
        let total = max(0, Int(seconds.rounded(.down)))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }

    /// For a notification: "Finished after 2m 14s", or "Exited with status 1 after 2m 14s".
    static func summary(exitCode: Int?, seconds: Double?) -> String {
        let took = seconds.map { " after " + durationText($0) } ?? ""
        switch exitCode {
        case 0?: return "Finished" + took
        case let code?: return "Exited with status \(code)" + took
        case nil: return "Finished" + took
        }
    }

    // MARK: Starting zsh

    /// Whether `path` is zsh — the only shell the hooks are written for. bash
    /// and fish are left exactly as they are.
    static func isZsh(path: String) -> Bool {
        (path as NSString).lastPathComponent == "zsh"
    }

    /// Variables to set and to remove from a launch environment.
    struct EnvironmentChange: Equatable {
        var set: [String: String]
        var remove: [String]
    }

    /// What makes zsh read the files in `wrapperDirectory` first: ZDOTDIR points
    /// there, and the ZDOTDIR the person had — if they had one — is handed on as
    /// `ITERMINAL_ZDOTDIR_ORIG` so their own files are found where they are. With
    /// none set, a stale hand-over inherited from elsewhere is removed, so it
    /// cannot send the wrapper to a folder that was never theirs. `nonce`, the
    /// code the shell signs its command lines with, goes as `ITERMINAL_NONCE`.
    static func zshEnvironment(wrapperDirectory: String, inheriting env: [String: String], nonce: String) -> EnvironmentChange {
        var set = ["ZDOTDIR": wrapperDirectory, "ITERMINAL_NONCE": nonce]
        var remove: [String] = []
        if let original = env["ZDOTDIR"] {
            set["ITERMINAL_ZDOTDIR_ORIG"] = original
        } else {
            remove.append("ITERMINAL_ZDOTDIR_ORIG")
        }
        return EnvironmentChange(set: set, remove: remove)
    }

    /// The file zsh reads from the wrapper directory, with its contents.
    static var zshFiles: [(name: String, contents: String)] {
        [(".zshenv", zshEnvScript + "\n")]
    }
}
