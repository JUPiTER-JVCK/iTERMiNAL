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
/// The leader's parent comes too, for a program that hands the terminal to a
/// child in a group of its own: man on macOS does that with its pager, so the
/// group in front while a page is read is less alone, and it is the parent
/// that says it is man.
///
/// Local sessions only: a remote session's child here is `ssh`, and what runs
/// on the far end is out of the kernel's sight. `ActiveProgram` covers that.
enum ForegroundProcess {
    /// The foreground group of the terminal `shellPID` runs on. `.prompt` when
    /// the shell's own group is in front; nil when the kernel cannot say, as
    /// when the shell has exited.
    static func group(forShell shellPID: pid_t) -> ActiveProgram.ForegroundGroup? {
        guard shellPID > 0, let shell = info(pid: shellPID) else { return nil }
        let foreground = shell.kp_eproc.e_tpgid
        guard foreground > 0 else { return nil }
        if foreground == shell.kp_eproc.e_pgid { return .prompt }
        let members = processes(inGroup: foreground)
        let pids = members.map { $0.kp_proc.p_pid }
        // The leader — the process the group is named for — first; the rest
        // in the order they started.
        let ordered = pids.filter { $0 == foreground } + pids.filter { $0 != foreground }.sorted()
        let names = ordered.compactMap(name(of:))
        guard !names.isEmpty else { return nil }
        // Only a parent that is not the shell says anything: the shell starts
        // every job.
        let parentPID = members.first { $0.kp_proc.p_pid == foreground }?.kp_eproc.e_ppid ?? 0
        let parent = parentPID > 1 && parentPID != shellPID ? name(of: parentPID) : nil
        return ActiveProgram.ForegroundGroup(names: names, parent: parent)
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
    private static func processes(inGroup pgid: pid_t) -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, pgid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        // Room for a few more, in case the group grows between the two calls.
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 4)
        size = processes.count * stride
        guard sysctl(&mib, u_int(mib.count), &processes, &size, nil, 0) == 0 else { return [] }
        return Array(processes.prefix(size / stride))
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
