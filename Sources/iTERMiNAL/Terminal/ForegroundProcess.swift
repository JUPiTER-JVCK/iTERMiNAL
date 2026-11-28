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
/// Two more things come with it, for programs the names alone would misread:
///
/// - The script a shell leading the group runs, from its arguments. macOS's
///   man is a shell script, so the kernel names the job sh — with mandoc and
///   less beside it — and only `/bin/sh /usr/bin/man ls` says it is man.
/// - The leader's parent, for a program that hands the terminal to a child in
///   a group of its own: a man built on mandoc does that with its pager.
///
/// Local sessions only: a remote session's child here is `ssh`, and what runs
/// on the far end is out of the kernel's sight. `ActiveProgram` covers that.
enum ForegroundProcess {
    /// The foreground group of the terminal `shellPID` runs on. `.prompt` when
    /// the shell's own group is in front; nil when the kernel cannot say, as
    /// when the shell has exited.
    ///
    /// `previous` is the last answer for this terminal. While the same group
    /// is in front, the script it found is kept rather than read again: the
    /// arguments come in a buffer the size of the system's argument limit.
    static func group(forShell shellPID: pid_t, reusing previous: ActiveProgram.ForegroundGroup?) -> ActiveProgram.ForegroundGroup? {
        guard shellPID > 0, let shell = info(pid: shellPID) else { return nil }
        let foreground = shell.kp_eproc.e_tpgid
        guard foreground > 0 else { return nil }
        if foreground == shell.kp_eproc.e_pgid { return .prompt }
        let members = processes(inGroup: foreground)
        let pids = members.map { $0.kp_proc.p_pid }
        // The leader — the process the group is named for — first; the rest
        // in the order they started.
        let leaderAlive = pids.contains(foreground)
        let ordered = pids.filter { $0 == foreground } + pids.filter { $0 != foreground }.sorted()
        let names = ordered.compactMap(name(of:))
        guard !names.isEmpty else { return nil }
        // Only a parent that is not the shell says anything: the shell starts
        // every job.
        let parentPID = members.first { $0.kp_proc.p_pid == foreground }?.kp_eproc.e_ppid ?? 0
        let parent = parentPID > 1 && parentPID != shellPID ? name(of: parentPID) : nil

        var script: String?
        if leaderAlive, let leader = names.first, ProgramKeyCatalog.section(forProgram: leader) == .shell {
            if let previous, previous.id == foreground, previous.names.first == leader {
                script = previous.script
            } else if let arguments = arguments(of: foreground) {
                script = ActiveProgram.script(inShellArguments: arguments)
            }
        }
        return ActiveProgram.ForegroundGroup(names: names, parent: parent, script: script, id: foreground)
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

    /// The size of the buffer `KERN_PROCARGS2` may need: the system's limit
    /// on a program's arguments and environment together.
    private static let argumentLimit: Int = {
        var limit: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, u_int(mib.count), &limit, &size, nil, 0) == 0, limit > 0 else { return 1 << 20 }
        return Int(limit)
    }()

    /// The arguments `pid` was started with, as `ps -o args` prints them. The
    /// bytes are read here; `ActiveProgram` takes them apart, where that can
    /// be checked off a Mac.
    private static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var buffer = [UInt8](repeating: 0, count: argumentLimit)
        var size = buffer.count
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return ActiveProgram.arguments(fromProcessArguments: Array(buffer.prefix(size)))
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
