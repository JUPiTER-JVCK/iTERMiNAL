import Darwin
import Foundation

/// Which program has a terminal, from the kernel.
///
/// A terminal has one foreground process group: the job that reads what is
/// typed. The shell's own group is in front at a prompt; `vim notes.txt` puts
/// Vim's in front until it quits, and `git log` puts git's, with less in it.
/// The kernel keeps that group in every process on the terminal (`e_tpgid`,
/// what `ps -o tpgid` prints), so asking about the shell is enough. This is
/// how Terminal.app names its tabs, and it needs nothing from the shell.
///
/// Local sessions only: a remote session's child here is `ssh`, and what runs
/// on the far end is out of the kernel's sight. `ActiveProgram` covers that.
enum ForegroundProcess {
    /// The names of the processes in the foreground group of the terminal
    /// `shellPID` runs on, the group's leader first. Empty when the shell's own
    /// group is in front — a prompt. Nil when the kernel cannot say, as when
    /// the shell has exited.
    static func names(forShell shellPID: pid_t) -> [String]? {
        guard shellPID > 0, let shell = info(pid: shellPID) else { return nil }
        let foreground = shell.kp_eproc.e_tpgid
        guard foreground > 0 else { return nil }
        if foreground == shell.kp_eproc.e_pgid { return [] }
        let members = group(foreground)
        // The leader — the process the group is named for, and the one the
        // command line started — first; the rest in the order they started.
        let ordered = members.filter { $0 == foreground } + members.filter { $0 != foreground }.sorted()
        let names = ordered.compactMap(name(of:))
        return names.isEmpty ? nil : names
    }

    private static func info(pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0,
              // A process that has gone reports success and no bytes.
              size >= MemoryLayout<kinfo_proc>.stride else { return nil }
        return info
    }

    /// Every process in the group `pgid`.
    private static func group(_ pgid: pid_t) -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pgid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        // Room for a few more, in case the group grows between the two calls.
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 4)
        size = processes.count * stride
        guard sysctl(&mib, u_int(mib.count), &processes, &size, nil, 0) == 0 else { return [] }
        return processes.prefix(size / stride).map { $0.kp_proc.p_pid }
    }

    /// The process's name, as `ps -c` prints it.
    private static func name(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        let name = String(decoding: bytes, as: UTF8.self)
        return name.isEmpty ? nil : name
    }
}
