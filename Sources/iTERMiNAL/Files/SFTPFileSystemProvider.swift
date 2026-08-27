import Foundation

/// A saved SSH target. Deliberately holds no secret: authentication is
/// delegated to the system ssh-agent and key files, so this app never stores,
/// prompts for, or transmits a password.
struct SSHConnection: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var identityFile: String?
    var initialPath: String?

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        identityFile: String? = nil,
        initialPath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.identityFile = identityFile
        self.initialPath = initialPath
    }

    var destination: String {
        username.isEmpty ? host : "\(username)@\(host)"
    }

    var subtitle: String {
        port == 22 ? destination : "\(destination):\(port)"
    }
}

/// Remote filesystem access over SFTP.
///
/// Rather than embedding an SSH stack, this drives the system `sftp` binary in
/// batch mode. That reuses the user's existing `~/.ssh/config`, known_hosts,
/// agent, and keys — which is both less code and a smaller attack surface than
/// handling credentials ourselves. `BatchMode=yes` guarantees sftp never waits
/// on an interactive password prompt (there is no TTY here), so key-based auth
/// is required.
final class SFTPFileSystemProvider: FileSystemProvider {
    let connection: SSHConnection

    var displayName: String { connection.name.isEmpty ? connection.destination : connection.name }
    var isRemote: Bool { true }
    var identifier: String { connection.id.uuidString }

    private let queue: DispatchQueue

    init(connection: SSHConnection) {
        self.connection = connection
        queue = DispatchQueue(
            label: "com.jupiterjvck.iterminal.files.sftp.\(connection.id.uuidString)",
            qos: .userInitiated
        )
    }

    func defaultPath() -> String {
        let configured = connection.initialPath?.trimmingCharacters(in: .whitespaces) ?? ""
        return configured.isEmpty ? "." : configured
    }

    // MARK: Operations

    func list(_ path: String, showHidden: Bool, completion: @escaping (Result<DirectoryListing, Error>) -> Void) {
        guard let quotedPath = Self.quote(path) else {
            completion(.failure(FileProviderError.unusablePath(path)))
            return
        }
        // `pwd` resolves ".", "..", and "~" to a concrete path for the UI.
        let script = ["cd \(quotedPath)", "pwd", showHidden ? "ls -la" : "ls -l"]
        run(script) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let output):
                let resolved = Self.parseWorkingDirectory(output) ?? path
                let items = Self.parseListing(output, directory: resolved, showHidden: showHidden, provider: self)
                completion(.success(DirectoryListing(path: resolved, items: LocalFileSystemProvider.sorted(items))))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func download(_ remotePath: String, to localURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        guard let quotedRemote = Self.quote(remotePath),
              let quotedLocal = Self.quote(localURL.path) else {
            completion(.failure(FileProviderError.unusablePath(remotePath)))
            return
        }
        run(["get \(quotedRemote) \(quotedLocal)"], timeout: 300) { result in
            completion(result.map { _ in localURL })
        }
    }

    func upload(_ localURL: URL, toDirectory remoteDirectory: String, completion: @escaping (Result<String, Error>) -> Void) {
        let destination = joinPath(remoteDirectory, localURL.lastPathComponent)
        guard let quotedLocal = Self.quote(localURL.path),
              let quotedRemote = Self.quote(destination) else {
            completion(.failure(FileProviderError.unusablePath(destination)))
            return
        }
        run(["put \(quotedLocal) \(quotedRemote)"], timeout: 300) { result in
            completion(result.map { _ in destination })
        }
    }

    func delete(_ item: FileItem, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let quoted = Self.quote(item.path) else {
            completion(.failure(FileProviderError.unusablePath(item.path)))
            return
        }
        run([item.isDirectory ? "rmdir \(quoted)" : "rm \(quoted)"]) { result in
            completion(result.map { _ in () })
        }
    }

    func makeDirectory(named name: String, in parent: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let quoted = Self.quote(joinPath(parent, name)) else {
            completion(.failure(FileProviderError.unusablePath(name)))
            return
        }
        run(["mkdir \(quoted)"]) { result in
            completion(result.map { _ in () })
        }
    }

    // MARK: Running sftp

    private func arguments() -> [String] {
        var args = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
            "-b", "-",
        ]
        if connection.port != 22 {
            args.append(contentsOf: ["-P", String(connection.port)])
        }
        if let identity = connection.identityFile?.trimmingCharacters(in: .whitespaces), !identity.isEmpty {
            args.append(contentsOf: ["-i", (identity as NSString).expandingTildeInPath])
        }
        args.append(connection.destination)
        return args
    }

    private func run(
        _ commands: [String],
        timeout: TimeInterval = 30,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let args = arguments()
        let script = (commands + ["bye"]).joined(separator: "\n") + "\n"

        queue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
            process.arguments = args

            let input = Pipe()
            let output = Pipe()
            let errorPipe = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errorPipe

            func finish(_ result: Result<String, Error>) {
                DispatchQueue.main.async { completion(result) }
            }

            do {
                try process.run()
            } catch {
                finish(.failure(error))
                return
            }

            input.fileHandleForWriting.write(Data(script.utf8))
            input.fileHandleForWriting.closeFile()

            // Drain both pipes concurrently; reading one to EOF while the
            // other fills its buffer would deadlock the child.
            var stdoutData = Data()
            var stderrData = Data()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                stdoutData = output.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }

            let watchdog = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

            process.waitUntilExit()
            group.wait()
            watchdog.cancel()

            let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderrText = String(data: stderrData, encoding: .utf8) ?? ""

            if process.terminationStatus == 0 {
                finish(.success(stdoutText))
            } else if process.terminationReason == .uncaughtSignal {
                finish(.failure(FileProviderError.timedOut))
            } else {
                let message = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                finish(.failure(FileProviderError.commandFailed(
                    message.isEmpty ? "sftp exited with status \(process.terminationStatus)" : message
                )))
            }
        }
    }

    // MARK: Parsing

    /// Wraps a path in double quotes for sftp's batch parser. Paths carrying
    /// a quote or newline are rejected outright: the batch protocol is
    /// line-oriented, so those characters could inject extra commands.
    static func quote(_ path: String) -> String? {
        guard !path.contains("\""), !path.contains("\n"), !path.contains("\r"), !path.contains("\\") else {
            return nil
        }
        return "\"\(path)\""
    }

    static func parseWorkingDirectory(_ output: String) -> String? {
        for line in output.split(separator: "\n") {
            guard let range = line.range(of: "Remote working directory: ") else { continue }
            return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Parses `ls -l` output. Lines look like:
    /// `drwxr-xr-x  5 user group 4096 Aug 27 05:00 name with spaces`
    static func parseListing(
        _ output: String,
        directory: String,
        showHidden: Bool,
        provider: FileSystemProvider
    ) -> [FileItem] {
        var items: [FileItem] = []

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("sftp>") || line.hasPrefix("total ")
                || line.hasPrefix("Remote working directory:") || line.hasPrefix("Connected to") {
                continue
            }

            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 9, fields[0].count >= 10 else { continue }

            let permissions = fields[0]
            let isDirectory = permissions.hasPrefix("d")
            let isSymlink = permissions.hasPrefix("l")

            // Re-slice the original line to keep spaces inside the filename.
            guard var name = suffix(of: line, afterFields: 8) else { continue }
            if isSymlink, let arrow = name.range(of: " -> ") {
                name = String(name[name.startIndex..<arrow.lowerBound])
            }
            if name == "." || name == ".." { continue }
            if !showHidden && name.hasPrefix(".") { continue }

            items.append(FileItem(
                name: name,
                path: provider.joinPath(directory, name),
                isDirectory: isDirectory,
                size: Int64(fields[4]),
                modified: parseDate(month: fields[5], day: fields[6], timeOrYear: fields[7])
            ))
        }
        return items
    }

    /// Everything after the first `count` whitespace-separated fields.
    private static func suffix(of line: String, afterFields count: Int) -> String? {
        var remaining = Substring(line)
        for _ in 0..<count {
            remaining = remaining.drop(while: { $0 == " " })
            guard let space = remaining.firstIndex(of: " ") else { return nil }
            remaining = remaining[space...]
        }
        let name = remaining.drop(while: { $0 == " " })
        return name.isEmpty ? nil : String(name)
    }

    private static let monthDayTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d HH:mm yyyy"
        return formatter
    }()

    private static let monthDayYear: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d yyyy"
        return formatter
    }()

    static func parseDate(month: String, day: String, timeOrYear: String) -> Date? {
        if timeOrYear.contains(":") {
            let year = Calendar.current.component(.year, from: Date())
            return monthDayTime.date(from: "\(month) \(day) \(timeOrYear) \(year)")
        }
        return monthDayYear.date(from: "\(month) \(day) \(timeOrYear)")
    }
}
