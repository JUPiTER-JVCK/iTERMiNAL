import Foundation

/// A sign-in the file browser can share with a terminal tab.
///
/// The file browser runs `sftp` with no keyboard, so a host that wants a
/// password — or a code from a phone — can never be signed in to from it, and
/// iTERMiNAL does not take passwords to get round that. What OpenSSH offers
/// instead is a *control socket*: the first `ssh` to a host signs in, in a real
/// terminal where a password can be typed, and listens on a socket; any other
/// `ssh` or `sftp` told about that socket rides on the connection that is
/// already open, with nothing to ask and nothing to send. The password goes to
/// `ssh` in the tab and nowhere else.
///
/// The socket lives in a folder of its own in this account's temporary folder,
/// named for the host, the port and the user, so a connection is only ever
/// shared with the destination it was made to. Two things are checked every
/// time it is used, because a socket someone else put there would be handed
/// every file that went through it: the folder must be a real folder, owned by
/// this account and closed to everyone else, and the socket in it must be one
/// this account made.
///
/// Foundation only, and no process is started, so the checks run on Linux.
enum SSHControlSocket {
    /// What can be bound is limited by the length of a Unix socket's path
    /// (103 characters on macOS) less the 17 that `ssh` adds while it makes the
    /// socket under a temporary name and moves it into place.
    static let maxPathLength = 86

    /// Short on purpose: the temporary folder's own path is already about half
    /// of what a socket's path may be.
    static let directoryName = "it-ssh"

    enum Preparation: Equatable {
        /// Nothing is open: start `ssh` here as the connection others share.
        case master(String)
        /// A connection is already open here and can be used as it is.
        case open(String)
        /// Sharing can't be set up, and why, in a clause.
        case unavailable(String)
    }

    // MARK: Where

    /// The folder the sockets live in, under `base` (the temporary folder).
    static func directory(under base: String) -> String {
        base.hasSuffix("/") ? base + directoryName : base + "/" + directoryName
    }

    /// What names one destination. A hash, so the host and the user never
    /// appear in a path, and so the name has a fixed length. Not a secret and
    /// not a defence — the folder's permissions are what keep others out — only
    /// a way for a connection to land on the socket of its own destination.
    static func name(for connection: SSHConnection) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let identity = "\(connection.username)@\(connection.host.lowercased()):\(connection.port)"
        for byte in identity.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// The socket for `connection`, or nil when the path would not do: too
    /// long to bind, or holding a character `ssh` reads as something else in a
    /// `ControlPath` (`%` and `$` expand, a leading `~` is the home folder).
    static func path(for connection: SSHConnection, base: String) -> String? {
        let candidate = directory(under: base) + "/" + name(for: connection)
        guard isPlain(candidate), candidate.utf8.count <= maxPathLength else { return nil }
        return candidate
    }

    private static func isPlain(_ path: String) -> Bool {
        path.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39)       // 0-9
                || (scalar.value >= 0x41 && scalar.value <= 0x5A) // A-Z
                || (scalar.value >= 0x61 && scalar.value <= 0x7A) // a-z
                || "/._-+".unicodeScalars.contains(scalar)
        }
    }

    // MARK: How `ssh` is told

    /// For the `ssh` that signs in: listen on `path`, so others can join.
    static func masterArguments(path: String) -> [String] {
        ["-o", "ControlMaster=yes", "-o", "ControlPath=\(path)"]
    }

    /// For an `sftp` that joins an open connection. `no` makes it use the one
    /// at `path` and fall back to an ordinary sign-in when there is none.
    static func clientArguments(path: String) -> [String] {
        ["-o", "ControlMaster=no", "-o", "ControlPath=\(path)"]
    }

    // MARK: Getting ready, and finding what is open

    /// Makes the folder if it is not there, and says what a sign-in tab should
    /// do. Starting over is safe: a socket left behind by an `ssh` that was
    /// killed is removed, since `ControlMaster=yes` would otherwise refuse to
    /// listen on top of it and quietly not share.
    static func prepare(for connection: SSHConnection, base: String) -> Preparation {
        guard let socketPath = path(for: connection, base: base) else {
            return .unavailable("the temporary folder's path can't be used for a socket")
        }
        guard makeDirectory(directory(under: base)) else {
            return .unavailable("a private folder for it couldn't be made in the temporary folder")
        }
        if isLive(socketPath) { return .open(socketPath) }
        removeStale(socketPath)
        guard !exists(socketPath) else {
            return .unavailable("something that isn't a connection is in the way")
        }
        return .master(socketPath)
    }

    /// The socket of a connection that is open for `connection` right now.
    static func liveSocket(for connection: SSHConnection, base: String) -> String? {
        guard let socketPath = path(for: connection, base: base),
              isPrivateDirectory(directory(under: base)),
              isLive(socketPath) else { return nil }
        return socketPath
    }

    /// Whether something is listening on the socket at `path`. A socket file
    /// whose `ssh` is gone is still a file, and `connect` is what tells it
    /// apart; `ssh` would otherwise print an error about it before carrying on
    /// without it.
    static func isLive(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFSOCK,
              info.st_uid == getuid() else { return false }
        let descriptor = socket(AF_UNIX, streamType, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return withAddress(of: path) { address, length in
            connect(descriptor, address, length) == 0
        } ?? false
    }

    /// Removes the socket at `path` if nothing is listening on it.
    static func removeStale(_ path: String) {
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFSOCK,
              info.st_uid == getuid(),
              !isLive(path) else { return }
        unlink(path)
    }

    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    // MARK: The folder

    /// Makes `path` a folder only this account can enter, or leaves it alone
    /// and says no. One that exists already is fine if it is this account's own
    /// and, should it be open to others, can be closed.
    static func makeDirectory(_ path: String) -> Bool {
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT else { return false }
            // Another process may have made it a moment ago; the check below
            // decides whether that is acceptable.
            if mkdir(path, 0o700) != 0 && errno != EEXIST { return false }
        }
        return isPrivateDirectory(path, repair: true)
    }

    /// A real folder (not a link to one), owned by this account, with nothing
    /// open to its group or to others.
    static func isPrivateDirectory(_ path: String, repair: Bool = false) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid() else { return false }
        if info.st_mode & 0o077 != 0 {
            guard repair, chmod(path, 0o700) == 0 else { return false }
        }
        return true
    }

    // MARK: Unix sockets

    #if os(Linux)
    private static let streamType = Int32(SOCK_STREAM.rawValue)
    #else
    private static let streamType = SOCK_STREAM
    #endif

    /// Calls `body` with `path` as the address of a Unix socket. Nil when the
    /// path doesn't fit one.
    static func withAddress<Value>(
        of path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> Value
    ) -> Value? {
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count < capacity else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
            buffer[bytes.count] = 0
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        #if !os(Linux)
        address.sun_len = UInt8(truncatingIfNeeded: length)
        #endif
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, length) }
        }
    }
}
