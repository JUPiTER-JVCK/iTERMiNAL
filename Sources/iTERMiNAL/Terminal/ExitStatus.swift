import Foundation

/// What a process's end is called to a person: the exit code, as a shell would
/// show it in `$?`.
///
/// SwiftTerm reports the end of a process as the raw status `waitpid` gave —
/// not the exit code — so a command that exits 1 arrives as 256, one that exits
/// 255 as 65280, and one killed by SIGKILL as 9. Foundation only, so the
/// decoding is checked off a Mac.
enum ExitStatus {
    /// The exit code for a raw wait status: the code itself for a normal exit,
    /// `128 + signal` for a process a signal ended (the shell's own convention,
    /// so 137 for SIGKILL), and nil for no status or one that is not an end.
    static func code(fromWaitStatus status: Int32?) -> Int32? {
        guard let status, status >= 0 else { return nil }
        let signal = status & 0x7F
        if signal == 0 { return (status >> 8) & 0xFF }
        // 0x7F in the low bits is "stopped", not ended.
        if signal == 0x7F { return nil }
        return 128 + signal
    }
}
