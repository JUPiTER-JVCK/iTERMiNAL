import Foundation

/// What went wrong running one of the app's own non-interactive `ssh` commands,
/// in words for the person, and whether a sign-in in a terminal would fix it.
struct PortToolError: LocalizedError {
    let message: String
    let needsSignIn: Bool

    init(_ message: String, needsSignIn: Bool = false) {
        self.message = message
        self.needsSignIn = needsSignIn
    }

    var errorDescription: String? { message }
}

/// A finished child process.
struct ProcessResult {
    var status: Int32
    var output: String
    var errorOutput: String
    var timedOut: Bool
}

/// Runs a program to completion with no keyboard, bounded in time and in what
/// it may say. Nil only when the program could not be started at all.
enum ProcessRunner {
    /// More than a scan or a forward ever says; what a host sends past it is
    /// read and dropped, so a talkative one cannot make this grow.
    static let maxBytes = 2_000_000

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> ProcessResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = output
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return nil
        }

        // Both pipes are read at once: reading one to its end while the other
        // fills would stall the child for good.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                if outData.count < maxBytes { outData.append(chunk) }
            }
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                let chunk = errorPipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                if errData.count < maxBytes { errData.append(chunk) }
            }
            group.leave()
        }

        var timedOut = false
        let watchdog = DispatchWorkItem {
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        process.waitUntilExit()
        group.wait()
        watchdog.cancel()

        return ProcessResult(
            status: process.terminationStatus,
            output: String(decoding: outData, as: UTF8.self),
            errorOutput: String(decoding: errData, as: UTF8.self),
            timedOut: timedOut
        )
    }
}

/// Finds the TCP ports a machine is listening on: this Mac's own, or a saved
/// host's, read over a non-interactive `ssh` that signs in with a key, the
/// agent, or a terminal tab's open connection — never a typed password.
enum PortScanner {
    enum Target {
        case thisMac
        case host(SSHConnection)
    }

    /// Runs off the main thread; `completion` arrives on it.
    static func scan(
        _ target: Target,
        completion: @escaping (Result<[ListeningPort], PortToolError>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = perform(target)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func perform(_ target: Target) -> Result<[ListeningPort], PortToolError> {
        switch target {
        case .thisMac:
            return scanThisMac()
        case .host(let connection):
            return scanHost(connection)
        }
    }

    /// `netstat` sees every listener and `lsof` knows whose they are, but only
    /// for this account's own processes — so both are read and joined.
    private static func scanThisMac() -> Result<[ListeningPort], PortToolError> {
        var entries: [ListeningPort] = []
        var ran = false
        if let result = ProcessRunner.run("/usr/sbin/netstat", ListeningPorts.localNetstatArguments, timeout: 10),
           !result.timedOut {
            entries.append(contentsOf: ListeningPorts.parse(result.output))
            ran = true
        }
        if let result = ProcessRunner.run("/usr/sbin/lsof", ListeningPorts.localLsofArguments, timeout: 10),
           !result.timedOut {
            entries.append(contentsOf: ListeningPorts.parse(result.output))
            ran = true
        }
        guard ran else {
            return .failure(PortToolError("Couldn't run netstat or lsof on this Mac."))
        }
        return .success(ListeningPorts.merge(entries))
    }

    private static func scanHost(_ connection: SSHConnection) -> Result<[ListeningPort], PortToolError> {
        // Refused, not connected to directly: see `JumpHosts`.
        if let problem = connection.jumpHostsProblem {
            return .failure(PortToolError(JumpHosts.refusal(problem)))
        }
        guard connection.transport != .custom else {
            return .failure(PortToolError("This host connects with a custom command, so there is no ssh to scan it with."))
        }
        guard !connection.host.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .failure(PortToolError("This host has no address yet."))
        }
        guard let ssh = SessionLaunch.resolveExecutable("ssh") else {
            return .failure(PortToolError("Couldn't find ssh on this Mac."))
        }
        let shared = SSHControlSocket.liveSocket(for: connection, base: NSTemporaryDirectory())
        let arguments = TunnelPlan.scanArguments(
            for: connection,
            sharedSocket: shared,
            command: ListeningPorts.remoteCommand
        )
        guard let result = ProcessRunner.run(ssh, arguments, timeout: 25) else {
            return .failure(PortToolError("Couldn't start ssh."))
        }
        if result.timedOut {
            return .failure(PortToolError("\(connection.host) didn't answer in time."))
        }
        // 255 is ssh itself failing; anything else is the command, and it
        // writes nothing to stderr (the command line silences it) when none of
        // `ss`, `netstat` and `lsof` exist.
        if result.status == 255 || (result.status != 0 && result.output.isEmpty && !result.errorOutput.isEmpty) {
            let needsSignIn = TunnelPlan.isSignInFailure(result.errorOutput)
            let reason = TunnelPlan.summarise(result.errorOutput)
            return .failure(PortToolError(
                needsSignIn ? "\(reason)\n\(TunnelPlan.signInAdvice)" : reason,
                needsSignIn: needsSignIn
            ))
        }
        if result.status != 0 && result.output.isEmpty {
            return .failure(PortToolError("\(connection.host) has none of ss, netstat or lsof to list its ports with."))
        }
        return .success(ListeningPorts.parse(result.output))
    }
}
