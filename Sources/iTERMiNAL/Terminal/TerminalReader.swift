import Darwin

/// What this Mac's kernel says about who is reading a terminal, for judging a
/// line as Return is pressed (see `EnteredLine`). Each is one call, made only
/// on a Return.
enum TerminalReader {
    /// Whether `shellPID`'s own process group is the terminal's foreground
    /// group: true at the shell's prompt, false while a job it started has the
    /// terminal. The kernel keeps the foreground group in every process on the
    /// terminal (`e_tpgid`, what `ps -o tpgid` prints), so asking about the
    /// shell is enough. Nil when it cannot say, as when the shell has exited.
    static func shellIsInFront(shellPID: pid_t) -> Bool? {
        guard shellPID > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, shellPID]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
              // A process that has gone reports success and no bytes.
              size >= MemoryLayout<kinfo_proc>.stride else { return nil }
        let foreground = info.kp_eproc.e_tpgid
        guard foreground > 0 else { return nil }
        return foreground == info.kp_eproc.e_pgid
    }

    /// Whether the terminal behind `pty`, the pseudo-terminal's master side, is
    /// taking a whole line without showing it: canonical input with echo off.
    /// The two sides share one set of terminal settings, so the master reads
    /// what the program on the other side set. False when they cannot be read.
    static func isReadingHiddenLine(pty: Int32) -> Bool {
        guard pty >= 0 else { return false }
        var settings = termios()
        guard tcgetattr(pty, &settings) == 0 else { return false }
        return settings.c_lflag & tcflag_t(ICANON) != 0 && settings.c_lflag & tcflag_t(ECHO) == 0
    }
}
