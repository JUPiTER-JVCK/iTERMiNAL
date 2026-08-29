import Darwin
import Foundation

/// Reads a running process's working directory from the kernel.
///
/// The app used to learn where a shell was only from OSC 7, which zsh does not
/// emit unless the user adds a hook to their `~/.zshrc`. Without that hook
/// `currentDirectory` stayed frozen at whatever the session launched in, so the
/// Files pane's "go to the terminal's directory" button, the sidebar labels and
/// the task manager all confidently pointed at the wrong place.
///
/// Asking the kernel needs no cooperation from the shell, so it works in every
/// shell out of the box. OSC 7 is still honoured when a shell does emit it,
/// since that arrives the instant the directory changes rather than on a poll.
enum ProcessDirectory {
    /// The working directory of `pid`, or nil if it cannot be read.
    ///
    /// Returns nil rather than a stale guess when the process has exited or
    /// belongs to another user — the caller keeps whatever it already had.
    static func path(forPID pid: pid_t) -> String? {
        guard pid > 0 else { return nil }

        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        let read = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, pointer, Int32(size))
        }
        // proc_pidinfo returns the bytes written, and anything short of the
        // full struct means the fields below were not populated.
        guard read == Int32(size) else { return nil }

        var directory = info.pvi_cdir.vip_path
        let path = withUnsafeBytes(of: &directory) { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            return String(validatingUTF8: base.assumingMemoryBound(to: CChar.self))
        }
        guard let path, !path.isEmpty else { return nil }
        return path
    }
}
