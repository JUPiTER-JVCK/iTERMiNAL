import Foundation

/// One entry in a directory listing, local or remote.
struct FileItem: Identifiable, Hashable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64?
    let modified: Date?

    var id: String { path }
}

/// A directory's canonical path plus its contents. The path comes back
/// resolved (".", "..", and "~" are expanded by the provider) so the UI can
/// display and navigate from something concrete.
struct DirectoryListing {
    let path: String
    let items: [FileItem]
}

enum FileProviderError: LocalizedError {
    case unusablePath(String)
    case commandFailed(String)
    case timedOut
    case notSupported(String)

    var errorDescription: String? {
        switch self {
        case .unusablePath(let path): return "Unusable path: \(path)"
        case .commandFailed(let message): return message
        case .timedOut: return "The remote server did not respond in time."
        case .notSupported(let what): return "\(what) isn't supported here."
        }
    }
}

/// Backing store for the file panel. `LocalFileSystemProvider` reads the Mac's
/// own disk; `SFTPFileSystemProvider` talks to a remote host. All callbacks
/// are delivered on the main queue.
protocol FileSystemProvider: AnyObject {
    var displayName: String { get }
    var isRemote: Bool { get }
    /// Stable identifier used in persisted pane snapshots ("local" or a
    /// connection UUID string).
    var identifier: String { get }

    func defaultPath() -> String
    func list(_ path: String, showHidden: Bool, completion: @escaping (Result<DirectoryListing, Error>) -> Void)
    func download(_ remotePath: String, to localURL: URL, completion: @escaping (Result<URL, Error>) -> Void)
    func upload(_ localURL: URL, toDirectory remoteDirectory: String, completion: @escaping (Result<String, Error>) -> Void)
    func delete(_ item: FileItem, completion: @escaping (Result<Void, Error>) -> Void)
    func makeDirectory(named name: String, in parent: String, completion: @escaping (Result<Void, Error>) -> Void)
}

extension FileSystemProvider {
    /// Joins a directory and a child name into a normalized path.
    func joinPath(_ directory: String, _ name: String) -> String {
        if directory == "/" { return "/" + name }
        return directory.hasSuffix("/") ? directory + name : directory + "/" + name
    }

    func parentPath(of path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        guard let index = trimmed.lastIndex(of: "/") else { return trimmed }
        if index == trimmed.startIndex { return "/" }
        return String(trimmed[trimmed.startIndex..<index])
    }
}
