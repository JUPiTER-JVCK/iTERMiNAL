import Foundation

/// Puts the zsh wrapper files where zsh will be pointed at them.
///
/// A shell runs whatever is in that folder, every time a tab opens, so it is
/// held to the standard of the folder an ssh control socket lives in: a real
/// directory (not a link to one), owned by this account, and closed to
/// everyone else. If it is not, nothing is written and the shell is started
/// the ordinary way.
enum ShellIntegrationFiles {
    enum InstallError: Error, Equatable {
        /// The folder is a link, belongs to someone else, or cannot be made private.
        case notPrivate(String)
        /// The folder or a file in it could not be written.
        case couldNotWrite(String)
    }

    /// `~/Library/Application Support/iTERMiNAL/ShellIntegration/zsh`
    static var zshDirectory: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("iTERMiNAL/ShellIntegration/zsh", isDirectory: true).path
    }

    /// The wrapper files, in the default folder. Returns the folder.
    static func installZsh() -> Result<String, InstallError> {
        install(into: zshDirectory)
    }

    /// Writes the wrapper files into `directory`, making it if need be, and
    /// returns it. Safe to call before every launch: a file that already holds
    /// the right text is left alone, and anything else is replaced whole, so a
    /// shell starting at that moment reads the old file or the new one, never
    /// half of either.
    static func install(into directory: String) -> Result<String, InstallError> {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directory) {
            do {
                try fileManager.createDirectory(
                    atPath: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                return .failure(.couldNotWrite(directory))
            }
        }
        guard isPrivateDirectory(directory) else { return .failure(.notPrivate(directory)) }

        for file in ShellIntegration.zshFiles {
            let path = (directory as NSString).appendingPathComponent(file.name)
            let data = Data(file.contents.utf8)
            if isRegularFile(path), (try? Data(contentsOf: URL(fileURLWithPath: path))) == data { continue }
            do {
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            } catch {
                return .failure(.couldNotWrite(path))
            }
        }
        return .success(directory)
    }

    /// A directory (not a symbolic link to one) owned by this user and closed to
    /// group and others; made so when it is only too open, as a folder this
    /// code created under a loose umask might be.
    static func isPrivateDirectory(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid() else { return false }
        if info.st_mode & 0o077 != 0 {
            guard chmod(path, 0o700) == 0 else { return false }
        }
        return true
    }

    /// A plain file, not a link: what is there is read as a file, not followed.
    private static func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }
}
