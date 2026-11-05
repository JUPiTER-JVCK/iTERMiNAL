import Foundation

/// What an ssh terminal tab adds for the settings ssh would otherwise leave at
/// its built-in defaults, so that a host that cannot be reached is given up on
/// in seconds and a connection that has died is noticed: a connect timeout, a
/// second try at connecting, and a keep-alive.
///
/// Only what `~/.ssh/config`, and the host's own settings here, leave unset.
/// ssh takes an option given on the command line over the same option in the
/// config, so adding these unconditionally would cut a `ConnectTimeout 60` that
/// someone set for a slow link down to fifteen seconds. So what ssh would use is
/// read first, from `ssh -G`, which prints the settings it ends up with for a
/// destination and connects to nothing. An option it reports at ssh's own
/// default is filled in; anything else was chosen by someone, and is left.
///
/// Foundation only, so the rules are checked off a Mac; `SessionLaunch` adds
/// the arguments to a terminal tab's ssh.
enum SSHDefaults {
    /// Seconds between keep-alive messages. ssh gives up after three that go
    /// unanswered (`ServerAliveCountMax`, whose default is left alone), so a
    /// connection that has died — a change of network, a sleep, a router that
    /// forgot it — is noticed in about 45 seconds. Without one, a tab can sit
    /// on a dead connection until TCP itself gives up.
    static let keepAliveSeconds = 15
    /// How long one try at connecting may take: the TCP connection and ssh's
    /// handshake. Without it the wait is the system's TCP timeout, which can be
    /// well over a minute for a host that does not answer at all. Ten seconds
    /// is what the file browser and the port scan already allow.
    ///
    /// All the tries together (`connectionAttempts` of these, a second apart)
    /// have to end well inside `AutoReconnect`'s `minUptime`: a session that
    /// lasts that long counts as having been up, so a host that never answers
    /// would otherwise look like a connection that worked and then dropped.
    static let connectTimeoutSeconds = 10
    /// Tries at connecting, a second apart. A host that refuses or cannot be
    /// routed to fails at once, so the second try costs a second and catches a
    /// network that is not quite back yet after a wake or a change of Wi-Fi.
    /// Not added to an automatic reconnect, which is already one of a counted
    /// run of tries and has its own, longer, `ConnectTimeout`.
    static let connectionAttempts = 2
    /// How long `ssh -G` is given. It is normally done in milliseconds, but it
    /// runs the config's `Match exec` commands and, where the config asks for
    /// it, canonicalizes the host name, either of which can wait on the
    /// network. Past this, nothing is filled in and ssh runs as it always has.
    static let queryTimeout: TimeInterval = 2

    /// What `ssh -G` printed: each setting by its name, which ssh prints in
    /// lowercase, with the first value it gives. Some settings appear more than
    /// once (`identityfile`, `sendenv`), and none of those matter here.
    static func parse(_ output: String) -> [String: String] {
        var settings: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " ") else { continue }
            let key = trimmed[..<space].lowercased()
            let value = trimmed[trimmed.index(after: space)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, settings[key] == nil else { continue }
            settings[key] = value
        }
        return settings
    }

    /// The arguments for each of the three that `effective` reports at ssh's
    /// own default. Nil — `ssh -G` failed, timed out, or is not there — adds
    /// nothing, and so does a setting it does not mention: a value that cannot
    /// be read is never taken to be a default.
    ///
    /// `connecttimeout` is printed as `none` when unset; an older ssh printed
    /// `-1`, which is the same thing.
    ///
    /// `secondTry` is false for an automatic reconnect (see `connectionAttempts`).
    static func arguments(effective: [String: String]?, secondTry: Bool = true) -> [String] {
        guard let effective else { return [] }
        var args: [String] = []
        if effective["serveraliveinterval"] == "0" {
            args.append(contentsOf: ["-o", "ServerAliveInterval=\(keepAliveSeconds)"])
        }
        if let timeout = effective["connecttimeout"], timeout == "none" || timeout == "-1" {
            args.append(contentsOf: ["-o", "ConnectTimeout=\(connectTimeoutSeconds)"])
        }
        if secondTry, effective["connectionattempts"] == "1" {
            args.append(contentsOf: ["-o", "ConnectionAttempts=\(connectionAttempts)"])
        }
        return args
    }

    /// Asks `ssh` (the binary at `ssh`) what it would use to reach
    /// `destination` given `arguments` — the same ones the tab passes — or nil
    /// if it cannot say within `timeout`.
    ///
    /// Safe on the main thread: it waits on a semaphore, not with
    /// `Process.waitUntilExit`, which runs the run loop while it waits and so
    /// could run other work in the middle of a launch. Nothing is read from
    /// the keyboard, and what ssh writes to standard error is dropped.
    static func query(
        ssh: String,
        arguments: [String],
        destination: String,
        timeout: TimeInterval = queryTimeout
    ) -> [String: String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ssh)
        process.arguments = ["-G"] + arguments + [destination]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }

        // Read while it runs, so a large configuration cannot fill the pipe
        // and leave ssh waiting on a reader that is waiting on it.
        let collected = Collected()
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            collected.data = output.fileHandleForReading.readDataToEndOfFile()
            reading.leave()
        }

        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        // The pipe closes when ssh exits, so this is over in a moment.
        guard reading.wait(timeout: .now() + 1) == .success,
              process.terminationStatus == 0 else { return nil }
        return parse(String(decoding: collected.data, as: UTF8.self))
    }

    /// Where the reading thread leaves what it read.
    private final class Collected: @unchecked Sendable {
        var data = Data()
    }
}
